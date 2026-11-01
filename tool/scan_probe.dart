// ignore_for_file: avoid_print
// Usage: dart run tool/scan_probe.dart <scanner-ip> [out.jpg]
// Prints scanner status; with an output path, also scans at 100 dpi.
import 'dart:io';

import 'package:duplex_printer/scan/wsd_scanner.dart';

Future<void> main(List<String> args) async {
  final scanner = WsdScanner(host: args.first);
  print('status: ${await scanner.status()}');
  if (args.length > 1) {
    final sw = Stopwatch()..start();
    final jpeg = await scanner.scan(dpi: 100, color: ScanColor.gray);
    await File(args[1]).writeAsBytes(jpeg);
    print('scanned ${jpeg.length} bytes in ${sw.elapsed.inSeconds}s');
  }
}
