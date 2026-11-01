// ignore_for_file: avoid_print
// Usage: dart run tool/sample_pdf.dart <out.pdf> [pages]
// Writes a numbered sample document for trying FlipPrint.
import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<void> main(List<String> args) async {
  final pages = args.length > 1 ? int.parse(args[1]) : 5;
  final doc = pw.Document();
  for (var i = 1; i <= pages; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Sample report', style: const pw.TextStyle(fontSize: 28)),
            pw.SizedBox(height: 12),
            for (var l = 0; l < 18; l++)
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Text(
                  'Line ${l + 1} of page $i. Double-sided printing test text.',
                ),
              ),
            pw.Spacer(),
            pw.Center(
              child: pw.Text(
                'Page $i',
                style: const pw.TextStyle(fontSize: 40),
              ),
            ),
          ],
        ),
      ),
    );
  }
  await File(args.first).writeAsBytes(await doc.save());
  print('wrote ${args.first}');
}
