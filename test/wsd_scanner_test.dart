import 'dart:io';

import 'package:duplex_printer/scan/wsd_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts the JPEG from a real L3250 RetrieveImage reply', () {
    final body = File('test/fixtures/wsd_retrieve_image.bin').readAsBytesSync();
    final jpeg = extractMultipartBinary(
      body,
      '13814049-1deb-11b2-8049-d4808b1615d3',
    );
    expect(jpeg, isNotNull);
    expect(jpeg!.length, 16987);
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]); // JPEG start
    expect(jpeg.sublist(jpeg.length - 2), [0xFF, 0xD9]); // JPEG end
  });
}
