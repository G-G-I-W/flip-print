/// Minimal IPP/2.0 client (RFC 8010/8011) — just enough to discover printer
/// capabilities, create a job, stream a document and follow its progress.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Operation ids.
const opPrintJob = 0x0002;
const opCreateJob = 0x0005;
const opSendDocument = 0x0006;
const opCancelJob = 0x0008;
const opGetJobAttributes = 0x0009;
const opGetPrinterAttributes = 0x000B;

// Delimiter tags.
const tagOperation = 0x01;
const tagJob = 0x02;
const tagEnd = 0x03;
const tagPrinter = 0x04;

// Value tags.
const tagInteger = 0x21;
const tagBoolean = 0x22;
const tagEnum = 0x23;
const tagOctetString = 0x30;
const tagBegCollection = 0x34;
const tagEndCollection = 0x37;
const tagText = 0x41;
const tagName = 0x42;
const tagKeyword = 0x44;
const tagUri = 0x45;
const tagCharset = 0x47;
const tagLanguage = 0x48;
const tagMimeType = 0x49;
const tagMemberName = 0x4A;

/// Job states (RFC 8011 §5.3.7).
const jobStatePending = 3;
const jobStateProcessing = 5;
const jobStateCanceled = 7;
const jobStateAborted = 8;
const jobStateCompleted = 9;

class IppAttribute {
  const IppAttribute(this.tag, this.name, this.values);
  IppAttribute.keyword(String name, String value)
    : this(tagKeyword, name, [value]);
  IppAttribute.integer(String name, int value)
    : this(tagInteger, name, [value]);
  IppAttribute.enumValue(String name, int value) : this(tagEnum, name, [value]);
  IppAttribute.boolean(String name, bool value)
    : this(tagBoolean, name, [value]);
  IppAttribute.name(String name, String value) : this(tagName, name, [value]);
  IppAttribute.uri(String name, String value) : this(tagUri, name, [value]);
  IppAttribute.mimeType(String name, String value)
    : this(tagMimeType, name, [value]);

  final int tag;
  final String name;
  final List<Object> values;
}

class IppRequest {
  IppRequest(this.operation, this.printerUri, {int? requestId})
    : requestId = requestId ?? _nextId++;

  static int _nextId = 1;

  final int operation;
  final String printerUri;
  final int requestId;
  final List<IppAttribute> operationAttributes = [];
  final List<IppAttribute> jobAttributes = [];

  Uint8List encode() {
    final b = BytesBuilder();
    b.add([2, 0]); // IPP/2.0
    _u16(b, operation);
    _u32(b, requestId);

    b.addByte(tagOperation);
    _attr(b, IppAttribute(tagCharset, 'attributes-charset', ['utf-8']));
    _attr(b, IppAttribute(tagLanguage, 'attributes-natural-language', ['en']));
    _attr(b, IppAttribute.uri('printer-uri', printerUri));
    for (final a in operationAttributes) {
      _attr(b, a);
    }
    if (jobAttributes.isNotEmpty) {
      b.addByte(tagJob);
      for (final a in jobAttributes) {
        _attr(b, a);
      }
    }
    b.addByte(tagEnd);
    return b.toBytes();
  }

  static void _attr(BytesBuilder b, IppAttribute a) {
    for (var i = 0; i < a.values.length; i++) {
      b.addByte(a.tag);
      final name = i == 0 ? utf8.encode(a.name) : const <int>[];
      _u16(b, name.length);
      b.add(name);
      final v = a.values[i];
      switch (a.tag) {
        case tagInteger || tagEnum:
          _u16(b, 4);
          _u32(b, v as int);
        case tagBoolean:
          _u16(b, 1);
          b.addByte((v as bool) ? 1 : 0);
        default:
          final bytes = v is List<int> ? v : utf8.encode(v as String);
          _u16(b, bytes.length);
          b.add(bytes);
      }
    }
  }

  static void _u16(BytesBuilder b, int v) => b.add([v >> 8 & 0xff, v & 0xff]);
  static void _u32(BytesBuilder b, int v) =>
      b.add([v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]);
}

class IppResponse {
  IppResponse(this.status, this.groups);

  /// Parses an IPP response. Collections are skipped.
  factory IppResponse.decode(Uint8List data) {
    final r = ByteData.sublistView(data);
    if (data.length < 9) throw const FormatException('Short IPP response');
    final status = r.getUint16(2);
    final groups = <(int, Map<String, List<Object>>)>[];
    Map<String, List<Object>>? group;
    String? lastName;
    var depth = 0;
    var i = 8;
    while (i < data.length) {
      final tag = data[i++];
      if (tag == tagEnd) break;
      if (tag < 0x10) {
        group = {};
        groups.add((tag, group));
        continue;
      }
      final nameLen = r.getUint16(i);
      i += 2;
      final name = utf8.decode(data.sublist(i, i + nameLen));
      i += nameLen;
      final valueLen = r.getUint16(i);
      i += 2;
      final raw = data.sublist(i, i + valueLen);
      i += valueLen;

      if (tag == tagBegCollection) {
        depth++;
        if (depth == 1 && name.isNotEmpty) lastName = name;
        continue;
      }
      if (tag == tagEndCollection) {
        depth--;
        continue;
      }
      if (depth > 0 || group == null) continue;

      final Object value = switch (tag) {
        tagInteger || tagEnum => ByteData.sublistView(raw).getInt32(0),
        tagBoolean => raw[0] != 0,
        >= 0x40 && <= 0x4f => utf8.decode(raw, allowMalformed: true),
        tagOctetString => utf8.decode(raw, allowMalformed: true),
        _ => raw,
      };
      if (name.isNotEmpty) lastName = name;
      if (lastName == null) continue;
      (group[lastName] ??= []).add(value);
    }
    return IppResponse(status, groups);
  }

  final int status;
  final List<(int, Map<String, List<Object>>)> groups;

  bool get ok => status < 0x0100;

  Map<String, List<Object>> group(int tag) => {
    for (final (t, g) in groups)
      if (t == tag) ...g,
  };

  Map<String, List<Object>> get printer => group(tagPrinter);
  Map<String, List<Object>> get job => group(tagJob);
}

class IppException implements Exception {
  IppException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to one printer at `http://host:port/path`.
class IppClient {
  IppClient({required this.host, this.port = 631, this.path = 'ipp/print'});

  final String host;
  final int port;
  final String path;

  // The L3250 (like most current Epsons) answers plain HTTP with
  // "426 Upgrade Required", so always use IPPS (TLS on the same port).
  String get printerUri => 'ipps://$host:$port/$path';
  Uri get _httpUri => Uri.parse('https://$host:$port/$path');

  Future<IppResponse> send(
    IppRequest request, {
    Stream<List<int>>? document,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      // Printers use self-signed certificates; trust only this printer.
      ..badCertificateCallback = (cert, h, p) => h == host && p == port;
    try {
      final req = await client.postUrl(_httpUri);
      req.headers.contentType = ContentType('application', 'ipp');
      final head = request.encode();
      // Chunked when a document is streamed, a fixed length otherwise.
      req.contentLength = document == null ? head.length : -1;
      req.add(head);
      if (document != null) await req.addStream(document);
      final res = await req.close();
      final body = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      if (res.statusCode != 200) {
        throw IppException('Printer replied HTTP ${res.statusCode}');
      }
      final ipp = IppResponse.decode(body.toBytes());
      if (!ipp.ok) {
        final msg = ipp.group(tagOperation)['status-message']?.first;
        throw IppException(
          'Printer error 0x${ipp.status.toRadixString(16)}${msg != null ? ': $msg' : ''}',
        );
      }
      return ipp;
    } on SocketException catch (e) {
      throw IppException('Cannot reach printer at $host: ${e.message}');
    } on TimeoutException {
      throw IppException('Printer at $host did not answer');
    } finally {
      client.close(force: document == null);
    }
  }

  Future<Map<String, List<Object>>> getPrinterAttributes([
    List<String> names = const ['all'],
    Duration timeout = const Duration(seconds: 15),
  ]) async {
    final req = IppRequest(opGetPrinterAttributes, printerUri)
      ..operationAttributes.add(
        IppAttribute(tagKeyword, 'requested-attributes', names),
      );
    return (await send(req, timeout: timeout)).printer;
  }

  Future<int> createJob({
    required String jobName,
    required String media,
    bool color = true,
    bool highQuality = false,
  }) async {
    final req = IppRequest(opCreateJob, printerUri)
      ..operationAttributes.addAll([
        IppAttribute.name('requesting-user-name', 'FlipPrint'),
        IppAttribute.name('job-name', jobName),
      ])
      ..jobAttributes.addAll([
        IppAttribute.keyword('media', media),
        IppAttribute.keyword('sides', 'one-sided'),
        IppAttribute.keyword(
          'print-color-mode',
          color ? 'color' : 'monochrome',
        ),
        IppAttribute.enumValue('print-quality', highQuality ? 5 : 4),
      ]);
    final res = await send(req);
    final id = res.job['job-id']?.first;
    if (id is! int) throw IppException('Printer did not return a job id');
    return id;
  }

  Future<void> sendDocument(
    int jobId,
    Stream<List<int>> document, {
    String format = 'image/pwg-raster',
  }) async {
    final req = IppRequest(opSendDocument, printerUri)
      ..operationAttributes.addAll([
        IppAttribute.integer('job-id', jobId),
        IppAttribute.name('requesting-user-name', 'FlipPrint'),
        IppAttribute.mimeType('document-format', format),
        IppAttribute.boolean('last-document', true),
      ]);
    await send(req, document: document, timeout: const Duration(seconds: 30));
  }

  Future<Map<String, List<Object>>> getJobAttributes(int jobId) async {
    final req = IppRequest(opGetJobAttributes, printerUri)
      ..operationAttributes.addAll([
        IppAttribute.integer('job-id', jobId),
        IppAttribute(tagKeyword, 'requested-attributes', [
          'job-state',
          'job-state-reasons',
          'job-impressions-completed',
          'job-media-sheets-completed',
        ]),
      ]);
    return (await send(req, timeout: const Duration(seconds: 5))).job;
  }

  Future<void> cancelJob(int jobId) async {
    final req = IppRequest(opCancelJob, printerUri)
      ..operationAttributes.addAll([
        IppAttribute.integer('job-id', jobId),
        IppAttribute.name('requesting-user-name', 'FlipPrint'),
      ]);
    await send(req, timeout: const Duration(seconds: 5));
  }
}
