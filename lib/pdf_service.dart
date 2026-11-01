import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Builds the PDFs for each print pass by rendering the source pages to
/// images and placing them in a new document in the required order.
class PdfService {
  PdfService(this.source);

  final Uint8List source;
  final _cache = <String, pw.MemoryImage>{};
  final _sizes = <int, PdfPageFormat>{};

  /// Number of pages in [source], rendered at a tiny resolution.
  Future<int> pageCount() => Printing.raster(source, dpi: 2).length;

  /// Creates a PDF for one pass. `null` entries become blank pages.
  ///
  /// [markBlanks] puts a tiny grey mark on blank pages so printer drivers
  /// don't silently skip them (which would break the sheet alignment).
  Future<Uint8List> buildPass(
    List<int?> sequence, {
    required double dpi,
    bool rotate = false,
    bool markBlanks = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final wanted = sequence.whereType<int>().toSet().toList()..sort();
    final missing = wanted
        .where((p) => !_cache.containsKey('$p@$dpi'))
        .toList();

    var done = wanted.length - missing.length;
    onProgress?.call(done, wanted.length);
    if (missing.isNotEmpty) {
      var i = 0;
      await for (final raster in Printing.raster(
        source,
        pages: [for (final p in missing) p - 1],
        dpi: dpi,
      )) {
        final page = missing[i++];
        _cache['$page@$dpi'] = pw.MemoryImage(await raster.toPng());
        _sizes[page] = PdfPageFormat(
          raster.width * PdfPageFormat.inch / dpi,
          raster.height * PdfPageFormat.inch / dpi,
        );
        onProgress?.call(++done, wanted.length);
      }
    }

    final doc = pw.Document();
    final blankFormat = wanted.isEmpty
        ? PdfPageFormat.a4
        : _sizes[wanted.first]!;
    for (final page in sequence) {
      if (page == null) {
        doc.addPage(
          pw.Page(
            pageFormat: blankFormat,
            margin: pw.EdgeInsets.zero,
            build: (_) => markBlanks
                ? pw.Align(
                    alignment: pw.Alignment.bottomRight,
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.all(12),
                      child: pw.Text(
                        '.',
                        style: const pw.TextStyle(
                          fontSize: 4,
                          color: PdfColors.grey300,
                        ),
                      ),
                    ),
                  )
                : pw.SizedBox(),
          ),
        );
        continue;
      }
      final image = pw.Image(_cache['$page@$dpi']!, fit: pw.BoxFit.fill);
      doc.addPage(
        pw.Page(
          pageFormat: _sizes[page]!,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.SizedBox.expand(
            child: rotate
                ? pw.Transform.rotate(angle: math.pi, child: image)
                : image,
          ),
        ),
      );
    }
    return doc.save();
  }

  /// A 4-page document with large page numbers, used to work out the
  /// right settings for a printer.
  static Future<Uint8List> testDocument() {
    final doc = pw.Document();
    for (var i = 1; i <= 4; i++) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) => pw.Column(
            children: [
              pw.Text(
                'TOP',
                style: pw.TextStyle(
                  fontSize: 40,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Spacer(),
              pw.Text(
                'Page $i',
                style: pw.TextStyle(
                  fontSize: 120,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Text(
                i.isOdd
                    ? 'Front of sheet ${(i + 1) ~/ 2}'
                    : 'Back of sheet ${i ~/ 2}',
                style: const pw.TextStyle(fontSize: 28),
              ),
              pw.Spacer(),
              pw.Text(
                'Duplex Printer test page',
                style: const pw.TextStyle(
                  fontSize: 14,
                  color: PdfColors.grey600,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return doc.save();
  }
}
