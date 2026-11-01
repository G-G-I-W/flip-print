// ignore_for_file: avoid_print
// Usage: dart run tool/ipp_probe.dart <printer-ip>
// Checks the printer answers IPP; creates and immediately cancels a job.
import 'package:duplex_printer/ipp/ipp.dart';

Future<void> main(List<String> args) async {
  final client = IppClient(host: args.first);
  final attrs = await client.getPrinterAttributes([
    'printer-make-and-model',
    'printer-state',
    'document-format-supported',
    'marker-names',
    'marker-levels',
  ]);
  attrs.forEach((k, v) => print('$k: $v'));
  final id = await client.createJob(
    jobName: 'probe',
    media: 'iso_a4_210x297mm',
  );
  print('created job $id');
  await client.cancelJob(id);
  print(
    'cancelled; state: ${(await client.getJobAttributes(id))['job-state']}',
  );
}
