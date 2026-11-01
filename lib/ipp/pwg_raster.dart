/// PWG Raster (PWG 5102.4) encoder — the image format the Epson L3250 and
/// other IPP Everywhere printers accept directly.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Bytes that start every PWG raster stream.
final pwgSyncWord = Uint8List.fromList(ascii.encode('RaS2'));

const _headerSize = 1796;

class PwgPage {
  const PwgPage({
    required this.width,
    required this.height,
    required this.dpi,
    required this.pageSizePoints,
    required this.mediaName,
    this.color = true,
    this.highQuality = false,
    this.totalPages = 0,
  });

  final int width;
  final int height;
  final int dpi;
  final (int, int) pageSizePoints;
  final String mediaName;
  final bool color;
  final bool highQuality;
  final int totalPages;

  int get bytesPerPixel => color ? 3 : 1;
  int get bytesPerLine => width * bytesPerPixel;

  Uint8List header() {
    final h = ByteData(_headerSize);
    void str(int offset, String s) {
      final bytes = ascii.encode(s);
      for (var i = 0; i < bytes.length && i < 63; i++) {
        h.setUint8(offset + i, bytes[i]);
      }
    }

    str(0, 'PwgRaster');
    str(64, 'white'); // MediaColor
    str(128, 'stationery'); // MediaType
    h.setUint32(276, dpi); // HWResolution x
    h.setUint32(280, dpi); // HWResolution y
    h.setUint32(340, 1); // NumCopies
    h.setUint32(352, pageSizePoints.$1);
    h.setUint32(356, pageSizePoints.$2);
    h.setUint32(372, width);
    h.setUint32(376, height);
    h.setUint32(384, 8); // BitsPerColor
    h.setUint32(388, 8 * bytesPerPixel); // BitsPerPixel
    h.setUint32(392, bytesPerLine);
    h.setUint32(396, 0); // ColorOrder: chunky
    h.setUint32(400, color ? 19 : 18); // ColorSpace: sRGB / sGray
    h.setUint32(420, bytesPerPixel); // NumColors
    h.setUint32(452, totalPages);
    h.setInt32(456, 1); // CrossFeedTransform
    h.setInt32(460, 1); // FeedTransform
    h.setUint32(472, width); // ImageBoxRight
    h.setUint32(476, height); // ImageBoxBottom
    h.setUint32(480, 0x00ffffff); // AlternatePrimary
    h.setUint32(484, highQuality ? 5 : 4); // PrintQuality
    str(1732, mediaName); // PageSizeName
    return h.buffer.asUint8List();
  }
}

/// Encodes one page from RGBA pixels (as from `ui.Image.toByteData(rawRgba)`)
/// into a PWG page: header followed by compressed rows.
Uint8List encodePwgPage(PwgPage page, Uint8List rgba) {
  assert(rgba.length == page.width * page.height * 4);
  final out = BytesBuilder()..add(page.header());

  final bpp = page.bytesPerPixel;
  final lineLen = page.bytesPerLine;
  var prev = Uint8List(lineLen);
  var cur = Uint8List(lineLen);
  var repeat = -1; // number of extra copies of `prev` pending

  void convertRow(int y, Uint8List dst) {
    var s = y * page.width * 4;
    if (bpp == 3) {
      for (var d = 0; d < lineLen; d += 3, s += 4) {
        dst[d] = rgba[s];
        dst[d + 1] = rgba[s + 1];
        dst[d + 2] = rgba[s + 2];
      }
    } else {
      for (var d = 0; d < lineLen; d++, s += 4) {
        dst[d] = (rgba[s] * 77 + rgba[s + 1] * 150 + rgba[s + 2] * 29) >> 8;
      }
    }
  }

  for (var y = 0; y < page.height; y++) {
    convertRow(y, cur);
    if (repeat >= 0 && repeat < 255 && _sameBytes(prev, cur)) {
      repeat++;
      continue;
    }
    if (repeat >= 0) _writeLine(out, repeat, prev, bpp);
    final t = prev;
    prev = cur;
    cur = t;
    repeat = 0;
  }
  if (repeat >= 0) _writeLine(out, repeat, prev, bpp);
  return out.toBytes();
}

/// A fully white page (for the blank back of an odd-length copy). [mark]
/// adds a tiny light-grey dot near the bottom-right corner so the printer
/// doesn't decide the page is empty and skip it.
Uint8List encodeBlankPwgPage(PwgPage page, {bool mark = true}) {
  final rgba = Uint8List(page.width * page.height * 4)
    ..fillRange(0, page.width * page.height * 4, 255);
  if (mark) {
    final margin = page.dpi ~/ 4; // ~6 mm in from the edge
    for (var y = page.height - margin; y < page.height - margin + 2; y++) {
      for (var x = page.width - margin; x < page.width - margin + 2; x++) {
        final i = (y * page.width + x) * 4;
        rgba[i] = rgba[i + 1] = rgba[i + 2] = 200;
      }
    }
  }
  return encodePwgPage(page, rgba);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Writes a line-repeat byte then PackBits-style pixel runs:
/// 0..127 = next pixel repeated n+1 times, 129..255 = 257-n literal pixels.
void _writeLine(BytesBuilder out, int repeat, Uint8List line, int bpp) {
  out.addByte(repeat);
  final pixels = line.length ~/ bpp;
  var p = 0;

  bool same(int a, int b) {
    for (var k = 0; k < bpp; k++) {
      if (line[a * bpp + k] != line[b * bpp + k]) return false;
    }
    return true;
  }

  while (p < pixels) {
    if (p + 1 < pixels && same(p, p + 1)) {
      var count = 2;
      while (p + count < pixels && count < 128 && same(p, p + count)) {
        count++;
      }
      out.addByte(count - 1);
      out.add(Uint8List.sublistView(line, p * bpp, p * bpp + bpp));
      p += count;
    } else {
      var count = 1;
      while (p + count < pixels &&
          count < 128 &&
          !(p + count + 1 < pixels && same(p + count, p + count + 1))) {
        count++;
      }
      out.addByte((257 - count) & 0xff);
      out.add(Uint8List.sublistView(line, p * bpp, (p + count) * bpp));
      p += count;
    }
  }
}

/// Decodes one compressed PWG page body (used by tests).
Uint8List decodePwgBody(Uint8List data, int offset, PwgPage page) {
  final bpp = page.bytesPerPixel;
  final lineLen = page.bytesPerLine;
  final out = Uint8List(lineLen * page.height);
  var i = offset;
  var y = 0;
  while (y < page.height) {
    final repeat = data[i++] + 1;
    final line = Uint8List(lineLen);
    var x = 0;
    while (x < lineLen) {
      final n = data[i++];
      if (n < 128) {
        for (var r = 0; r <= n; r++) {
          line.setRange(x, x + bpp, data, i);
          x += bpp;
        }
        i += bpp;
      } else {
        final count = (257 - n) * bpp;
        line.setRange(x, x + count, data, i);
        x += count;
        i += count;
      }
    }
    for (var r = 0; r < repeat; r++) {
      out.setRange(y * lineLen, (y + 1) * lineLen, line);
      y++;
    }
  }
  return out;
}
