import 'dart:math';
import 'dart:typed_data';

import 'package:duplex_printer/ipp/ipp.dart';
import 'package:duplex_printer/ipp/pwg_raster.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PWG raster', () {
    PwgPage page(int w, int h, {bool color = true}) => PwgPage(
      width: w,
      height: h,
      dpi: 360,
      pageSizePoints: (595, 842),
      mediaName: 'iso_a4_210x297mm',
      color: color,
    );

    test('header is 1796 bytes with key fields', () {
      final h = ByteData.sublistView(page(100, 50).header());
      expect(h.lengthInBytes, 1796);
      expect(h.getUint32(372), 100);
      expect(h.getUint32(376), 50);
      expect(h.getUint32(392), 300);
      expect(h.getUint32(400), 19);
    });

    for (final color in [true, false]) {
      test('round-trips random and repeated content (color: $color)', () {
        const w = 301, h = 40;
        final rnd = Random(1);
        final rgba = Uint8List(w * h * 4);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            // Mix of noise rows, solid rows and short runs.
            final v = y < 10
                ? rnd.nextInt(256)
                : y < 30
                ? 255
                : (x ~/ 3) % 2 * 200;
            rgba[i] = v;
            rgba[i + 1] = color ? (v * 3) & 0xff : v;
            rgba[i + 2] = color ? (v * 7) & 0xff : v;
            rgba[i + 3] = 255;
          }
        }
        final p = page(w, h, color: color);
        final encoded = encodePwgPage(p, rgba);
        final decoded = decodePwgBody(encoded, 1796, p);

        final bpp = p.bytesPerPixel;
        for (var px = 0; px < w * h; px++) {
          if (color) {
            for (var c = 0; c < 3; c++) {
              expect(decoded[px * 3 + c], rgba[px * 4 + c]);
            }
          } else {
            final s = px * 4;
            final g =
                (rgba[s] * 77 + rgba[s + 1] * 150 + rgba[s + 2] * 29) >> 8;
            expect(decoded[px * bpp], g);
          }
        }
      });
    }

    test('blank page compresses to almost nothing', () {
      final encoded = encodeBlankPwgPage(page(2976, 4209));
      expect(encoded.length, lessThan(1796 + 2000));
    });
  });

  group('IPP', () {
    test('request encodes header and attributes', () {
      final req = IppRequest(
        opGetJobAttributes,
        'ipp://p/ipp/print',
        requestId: 7,
      )..operationAttributes.add(IppAttribute.integer('job-id', 42));
      final b = req.encode();
      expect(b.sublist(0, 8), [2, 0, 0, 9, 0, 0, 0, 7]);
      expect(b.last, tagEnd);
    });

    test('response decodes groups, multi-values and skips collections', () {
      final b = BytesBuilder()
        ..add([2, 0, 0, 0, 0, 0, 0, 1])
        ..addByte(tagOperation)
        ..add(_attr(tagCharset, 'attributes-charset', 'utf-8'))
        ..addByte(tagJob)
        ..add(_intAttr(tagInteger, 'job-id', 12))
        ..add(_intAttr(tagEnum, 'job-state', 5))
        ..add(_attr(tagKeyword, 'job-state-reasons', 'job-printing'))
        ..add(_attr(tagKeyword, '', 'job-incoming'))
        ..add(_attr(tagBegCollection, 'media-col', ''))
        ..add(_attr(tagMemberName, '', 'media-size'))
        ..add(_attr(tagBegCollection, '', ''))
        ..add(_attr(tagEndCollection, '', ''))
        ..add(_attr(tagEndCollection, '', ''))
        ..add(_intAttr(tagInteger, 'job-impressions-completed', 3))
        ..addByte(tagEnd);
      final res = IppResponse.decode(b.toBytes());
      expect(res.ok, isTrue);
      expect(res.job['job-id'], [12]);
      expect(res.job['job-state'], [5]);
      expect(res.job['job-state-reasons'], ['job-printing', 'job-incoming']);
      expect(res.job['job-impressions-completed'], [3]);
      expect(res.job.containsKey('media-col'), isFalse);
    });
  });
}

List<int> _attr(int tag, String name, String value) => [
  tag,
  0,
  name.length,
  ...name.codeUnits,
  0,
  value.length,
  ...value.codeUnits,
];

List<int> _intAttr(int tag, String name, int v) => [
  tag,
  0,
  name.length,
  ...name.codeUnits,
  0,
  4,
  v >> 24 & 0xff,
  v >> 16 & 0xff,
  v >> 8 & 0xff,
  v & 0xff,
];
