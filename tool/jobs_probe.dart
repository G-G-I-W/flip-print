// ignore_for_file: avoid_print
// Usage: dart run tool/jobs_probe.dart <printer-ip> <job-id>...
import 'package:duplex_printer/ipp/ipp.dart';

Future<void> main(List<String> args) async {
  final client = IppClient(host: args.first);
  for (final id in args.skip(1)) {
    print('job $id: ${await client.getJobAttributes(int.parse(id))}');
  }
}
