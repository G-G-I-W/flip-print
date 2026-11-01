/// Photo sizes and how copies of one photo are laid out on a sheet. All
/// measurements are in millimetres.
library;

import 'dart:math' as math;

class PhotoPreset {
  const PhotoPreset(
    this.name,
    this.widthMm,
    this.heightMm, {
    this.custom = false,
  });

  final String name;
  final double widthMm;
  final double heightMm;

  /// Added by the user (can be deleted).
  final bool custom;

  /// ID photos get a face guide in the crop frame.
  bool get isId => widthMm <= 55 && heightMm <= 55;

  String get sizeLabel => '${_mm(widthMm)} × ${_mm(heightMm)} mm';

  static String _mm(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  Map<String, dynamic> toJson() => {'name': name, 'w': widthMm, 'h': heightMm};

  factory PhotoPreset.fromJson(Map<String, dynamic> j) => PhotoPreset(
    j['name'] as String,
    (j['w'] as num).toDouble(),
    (j['h'] as num).toDouble(),
    custom: true,
  );

  /// Sri Lankan ID photos are 3.5 × 4.5 cm.
  static const builtIn = [
    PhotoPreset('Passport', 35, 45),
    PhotoPreset('NIC', 35, 45),
    PhotoPreset('Driving Licence', 35, 45),
    PhotoPreset('Visa 2×2"', 51, 51),
    PhotoPreset('Stamp', 25, 30),
    PhotoPreset('Postcard 4×6"', 102, 152),
  ];
}

/// Copies of one photo arranged as a grid block somewhere on the sheet.
class PhotoSheetLayout {
  PhotoSheetLayout({
    required this.paperW,
    required this.paperH,
    required this.photoW,
    required this.photoH,
    this.gap = 2,
    this.margin = 4,
  });

  final double paperW, paperH, photoW, photoH;

  /// Space between photos, for cutting.
  final double gap;

  /// Edge the printer can't print on.
  final double margin;

  int get maxCols =>
      math.max(1, ((paperW - 2 * margin + gap) / (photoW + gap)).floor());
  int get maxRows =>
      math.max(1, ((paperH - 2 * margin + gap) / (photoH + gap)).floor());
  int get maxCount => maxCols * maxRows;

  /// Columns used for [count] photos when the user asked for [cols].
  int colsFor(int count, int cols) => cols.clamp(1, math.min(count, maxCols));
  int rowsFor(int count, int cols) => (count / colsFor(count, cols)).ceil();

  /// Fewest columns that still fit [count] photos on the sheet.
  int minColsFor(int count) =>
      math.min(maxCols, math.max(1, (count / maxRows).ceil()));

  double blockW(int count, int cols) {
    final c = colsFor(count, cols);
    return c * photoW + (c - 1) * gap;
  }

  double blockH(int count, int cols) {
    final r = rowsFor(count, cols);
    return r * photoH + (r - 1) * gap;
  }

  /// Keeps a block's top-left corner inside the printable area.
  (double, double) clamp(double x, double y, int count, int cols) => (
    x.clamp(margin, math.max(margin, paperW - margin - blockW(count, cols))),
    y.clamp(margin, math.max(margin, paperH - margin - blockH(count, cols))),
  );

  /// Top-left corner for an alignment (-1 start, 0 centre, 1 end per axis).
  (double, double) align(int ax, int ay, int count, int cols) {
    double pos(int a, double paper, double block) => switch (a) {
      < 0 => margin,
      0 => (paper - block) / 2,
      _ => paper - margin - block,
    };
    return clamp(
      pos(ax, paperW, blockW(count, cols)),
      pos(ay, paperH, blockH(count, cols)),
      count,
      cols,
    );
  }

  /// Top-left corner of every photo, row by row.
  List<(double, double)> positions(double x, double y, int count, int cols) {
    final c = colsFor(count, cols);
    return [
      for (var i = 0; i < count; i++)
        (x + (i % c) * (photoW + gap), y + (i ~/ c) * (photoH + gap)),
    ];
  }
}
