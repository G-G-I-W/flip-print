/// Minimal WS-Scan (WSD) client — the network scan protocol the Epson L3250
/// offers (it has no eSCL/AirScan). Flow: CreateScanJob → RetrieveImage,
/// which answers with a multipart/related (MTOM) body holding a JPEG.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _ns = 'http://schemas.microsoft.com/windows/2006/08/wdp/scan';

enum ScanColor {
  color('RGB24', 'Colour'),
  gray('Grayscale8', 'Greyscale');

  const ScanColor(this.wsd, this.label);
  final String wsd;
  final String label;
}

/// Scan area in 1/1000 inch, as WS-Scan expects.
enum ScanArea {
  a4('A4', 8268, 11693),
  letter('Letter', 8500, 11000),
  full('Whole glass', 8500, 11700);

  const ScanArea(this.label, this.width, this.height);
  final String label;
  final int width;
  final int height;
}

class ScanException implements Exception {
  ScanException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WsdScanner {
  WsdScanner({required this.host, this.port = 80, this.path = 'WDP/SCAN'});

  final String host;
  final int port;
  final String path;

  String get _url => 'http://$host:$port/$path';

  /// "Idle", "Processing" or "Stopped", plus any active conditions.
  Future<(String, List<String>)> status() async {
    final xml = utf8.decode(
      (await _post(
        'GetScannerElements',
        '<sca:GetScannerElementsRequest><sca:RequestedElements>'
            '<sca:Name>sca:ScannerStatus</sca:Name>'
            '</sca:RequestedElements></sca:GetScannerElementsRequest>',
        timeout: const Duration(seconds: 5),
      )).body,
      allowMalformed: true,
    );
    final state = _tag(xml, 'ScannerState') ?? 'Unknown';
    final conditions = RegExp(r'<\w+:Name>([^<]+)</\w+:Name>')
        .allMatches(xml.split('ActiveConditions').elementAtOrNull(1) ?? '')
        .map((m) => m.group(1)!)
        .toList();
    return (state, conditions);
  }

  /// Scans one page from the glass and returns JPEG bytes.
  Future<Uint8List> scan({
    int dpi = 300,
    ScanColor color = ScanColor.color,
    ScanArea area = ScanArea.a4,
  }) async {
    final ticket =
        '<sca:CreateScanJobRequest><sca:ScanTicket>'
        '<sca:JobDescription>'
        '<sca:JobName>FlipPrint scan</sca:JobName>'
        '<sca:JobOriginatingUserName>FlipPrint</sca:JobOriginatingUserName>'
        '<sca:JobInformation>FlipPrint</sca:JobInformation>'
        '</sca:JobDescription>'
        '<sca:DocumentParameters>'
        '<sca:Format>exif</sca:Format>'
        '<sca:ImagesToTransfer>1</sca:ImagesToTransfer>'
        '<sca:InputSize><sca:InputMediaSize>'
        '<sca:Width>${area.width}</sca:Width>'
        '<sca:Height>${area.height}</sca:Height>'
        '</sca:InputMediaSize></sca:InputSize>'
        '<sca:InputSource>Platen</sca:InputSource>'
        '<sca:MediaSides><sca:MediaFront>'
        '<sca:ColorProcessing>${color.wsd}</sca:ColorProcessing>'
        '<sca:Resolution><sca:Width>$dpi</sca:Width>'
        '<sca:Height>$dpi</sca:Height></sca:Resolution>'
        '<sca:ScanRegion>'
        '<sca:ScanRegionXOffset>0</sca:ScanRegionXOffset>'
        '<sca:ScanRegionYOffset>0</sca:ScanRegionYOffset>'
        '<sca:ScanRegionWidth>${area.width}</sca:ScanRegionWidth>'
        '<sca:ScanRegionHeight>${area.height}</sca:ScanRegionHeight>'
        '</sca:ScanRegion>'
        '</sca:MediaFront></sca:MediaSides>'
        '</sca:DocumentParameters>'
        '</sca:ScanTicket></sca:CreateScanJobRequest>';
    final job = utf8.decode((await _post('CreateScanJob', ticket)).body);
    final jobId = _tag(job, 'JobId');
    final token = _tag(job, 'JobToken');
    if (jobId == null || token == null) {
      throw ScanException('The scanner did not start the scan');
    }

    // The reply only arrives once the scan head has finished (~20-60 s).
    final res = await _post(
      'RetrieveImage',
      '<sca:RetrieveImageRequest>'
          '<sca:DocumentDescription><sca:DocumentName>IMAGE000.JPG'
          '</sca:DocumentName></sca:DocumentDescription>'
          '<sca:JobId>$jobId</sca:JobId>'
          '<sca:JobToken>$token</sca:JobToken>'
          '</sca:RetrieveImageRequest>',
      timeout: const Duration(minutes: 3),
    );
    final boundary = RegExp(r'boundary="?([^";]+)"?')
        .firstMatch(res.contentType)
        ?.group(1);
    if (boundary == null) throw ScanException('Unexpected reply from scanner');
    final image = extractMultipartBinary(res.body, boundary);
    if (image == null) throw ScanException('The scan had no image');
    return image;
  }

  Future<({Uint8List body, String contentType})> _post(
    String action,
    String body, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:sca="$_ns">'
        '<soap:Header>'
        '<wsa:MessageID>urn:uuid:${_uuid()}</wsa:MessageID>'
        '<wsa:To>$_url</wsa:To>'
        '<wsa:ReplyTo><wsa:Address>'
        'http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous'
        '</wsa:Address></wsa:ReplyTo>'
        '<wsa:Action>$_ns/$action</wsa:Action>'
        '</soap:Header>'
        '<soap:Body>$body</soap:Body>'
        '</soap:Envelope>';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'WSDAPI';
    try {
      final bytes = utf8.encode(envelope);
      final req = await client.postUrl(Uri.parse(_url));
      req.headers.contentType = ContentType(
        'application',
        'soap+xml',
        charset: 'utf-8',
      );
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final data = await res
          .fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c))
          .timeout(timeout);
      final out = data.toBytes();
      if (res.statusCode != 200) {
        final text = utf8.decode(out, allowMalformed: true);
        final reason = _tag(text, 'Text') ?? _tag(text, 'Value');
        throw ScanException(_friendlyFault(reason, res.statusCode));
      }
      return (body: out, contentType: res.headers.value('content-type') ?? '');
    } on SocketException {
      throw ScanException(
        'Can\'t reach the scanner at $host. Check it is on and on the same Wi-Fi.',
      );
    } on TimeoutException {
      throw ScanException('The scanner stopped responding');
    } finally {
      client.close(force: true);
    }
  }

  static String _friendlyFault(String? reason, int status) {
    final r = reason?.toLowerCase() ?? '';
    if (r.contains('busy') || r.contains('processing')) {
      return 'The scanner is busy. Wait a moment and try again.';
    }
    if (r.contains('cover') || r.contains('lid')) {
      return 'Close the scanner lid and try again.';
    }
    return 'Scanner error${reason != null ? ': $reason' : ' (HTTP $status)'}';
  }

  static String? _tag(String xml, String name) =>
      RegExp('<(?:\\w+:)?$name(?:\\s[^>]*)?>([^<]*)</(?:\\w+:)?$name>')
          .firstMatch(xml)
          ?.group(1)
          ?.trim();

  static String _uuid() {
    final r = Random.secure();
    String hex(int n) => List.generate(
      n,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
  }
}

/// Returns the first non-XML part of a multipart/related body.
Uint8List? extractMultipartBinary(Uint8List body, String boundary) {
  final marker = ascii.encode('--$boundary');
  final starts = <int>[];
  for (var i = _indexOf(body, marker, 0); i >= 0;) {
    starts.add(i);
    i = _indexOf(body, marker, i + marker.length);
  }
  for (var k = 0; k + 1 < starts.length; k++) {
    final partStart = starts[k] + marker.length;
    final headerEnd = _indexOf(body, ascii.encode('\r\n\r\n'), partStart);
    if (headerEnd < 0 || headerEnd > starts[k + 1]) continue;
    final headers = ascii
        .decode(body.sublist(partStart, headerEnd), allowInvalid: true)
        .toLowerCase();
    if (headers.contains('xml')) continue;
    var end = starts[k + 1];
    if (end >= 2 && body[end - 2] == 13 && body[end - 1] == 10) end -= 2;
    return Uint8List.sublistView(body, headerEnd + 4, end);
  }
  return null;
}

int _indexOf(Uint8List data, List<int> pattern, int from) {
  outer:
  for (var i = from; i <= data.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}
