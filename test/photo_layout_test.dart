import 'package:duplex_printer/photo/photo_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Passport photos on A4.
  final l = PhotoSheetLayout(paperW: 210, paperH: 297, photoW: 35, photoH: 45);

  test('fits a 5 × 6 grid of passport photos on A4', () {
    expect(l.maxCols, 5);
    expect(l.maxRows, 6);
    expect(l.maxCount, 30);
  });

  test('lays out copies row by row from the block corner', () {
    final p = l.positions(10, 20, 4, 3);
    expect(p, [(10.0, 20.0), (47.0, 20.0), (84.0, 20.0), (10.0, 67.0)]);
    expect(l.blockW(4, 3), 109);
    expect(l.blockH(4, 3), 92);
  });

  test('keeps the block inside the printable area', () {
    expect(l.clamp(-50, 500, 4, 2), (4.0, 297 - 4 - 92.0));
    expect(l.align(1, -1, 2, 2), (210 - 4 - 72.0, 4.0));
    expect(l.align(0, 0, 1, 1), ((210 - 35) / 2, (297 - 45) / 2));
  });

  test('needs more columns when rows run out', () {
    expect(l.minColsFor(6), 1);
    expect(l.minColsFor(7), 2);
    expect(l.minColsFor(30), 5);
  });
}
