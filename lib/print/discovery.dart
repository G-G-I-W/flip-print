import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../data/store.dart';
import '../ipp/ipp.dart';

class FoundPrinter {
  const FoundPrinter({
    required this.name,
    required this.serviceName,
    required this.host,
    required this.port,
    required this.path,
  });

  final String name;
  final String serviceName;
  final String host;
  final int port;
  final String path;
}

/// Finds IPP printers on the Wi-Fi network via mDNS / DNS-SD.
class PrinterDiscovery extends ChangeNotifier {
  final Map<String, FoundPrinter> _found = {};
  nsd.Discovery? _discovery;
  bool scanning = false;
  String? error;

  List<FoundPrinter> get printers => _found.values.toList();

  Future<void> start() async {
    if (scanning) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      _discovery = await nsd.startDiscovery(
        '_ipp._tcp',
        ipLookupType: nsd.IpLookupType.v4,
      );
      _discovery!.addServiceListener((service, status) {
        if (status != nsd.ServiceStatus.found) return;
        final ip = service.addresses?.firstOrNull?.address ?? service.host;
        if (ip == null || service.name == null) return;
        String? txt(String k) {
          final v = service.txt?[k];
          return v == null ? null : utf8.decode(v, allowMalformed: true);
        }

        _found[service.name!] = FoundPrinter(
          name: txt('ty') ?? service.name!,
          serviceName: service.name!,
          host: ip,
          port: service.port ?? 631,
          path: txt('rp') ?? 'ipp/print',
        );
        notifyListeners();
      });
    } catch (e) {
      error = 'Network scan failed: $e';
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    scanning = false;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Scans for [timeout] and returns what was found.
  static Future<List<FoundPrinter>> scanOnce({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final d = PrinterDiscovery();
    await d.start();
    await Future<void>.delayed(timeout);
    await d.stop();
    return d.printers;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// Checks a printer address answers IPP and accepts PWG raster.
/// Returns the printer's model name.
Future<String> probePrinter(
  String host, {
  int port = 631,
  String path = 'ipp/print',
}) async {
  if (InternetAddress.tryParse(host) == null && !host.contains('.')) {
    throw IppException('Enter an IP address like 192.168.1.12');
  }
  final attrs = await IppClient(host: host, port: port, path: path)
      .getPrinterAttributes([
        'printer-make-and-model',
        'document-format-supported',
      ]);
  final formats = attrs['document-format-supported'] ?? const [];
  if (!formats.contains('image/pwg-raster')) {
    throw IppException(
      'This printer does not accept PWG raster. Use "Other printer" instead.',
    );
  }
  return (attrs['printer-make-and-model']?.first as String?) ?? 'IPP printer';
}

/// Turns IPP printer-state-reasons into a message for the user, or null when
/// nothing needs attention.
String? describePrinterReasons(List<String> reasons) {
  for (final r in reasons) {
    if (r.startsWith('media-empty') || r.startsWith('media-needed')) {
      return 'Out of paper — add paper to continue';
    }
    if (r.startsWith('media-jam')) return 'Paper jam — clear it to continue';
    if (r.startsWith('marker-supply-empty')) return 'Ink is empty';
    if (r.startsWith('door-open') || r.startsWith('cover-open')) {
      return 'Printer cover is open';
    }
  }
  return null;
}

enum PrinterHealth { checking, ready, busy, attention, offline, system }

class PrinterStatus {
  const PrinterStatus(this.health, this.label);
  final PrinterHealth health;
  final String label;

  static const checking = PrinterStatus(PrinterHealth.checking, 'Checking…');
}

/// Asks a saved printer how it is doing. If it can't be reached but was found
/// by mDNS before, looks for it again in case its IP address changed.
Future<PrinterStatus> checkPrinter(SavedPrinter p) async {
  if (p.isSystem) {
    return const PrinterStatus(
      PrinterHealth.system,
      'Uses Android print dialog',
    );
  }
  Future<PrinterStatus> ask() async {
    final attrs = await IppClient(host: p.host!, port: p.port, path: p.path)
        .getPrinterAttributes([
          'printer-state',
          'printer-state-reasons',
        ], const Duration(seconds: 4));
    final reasons = attrs['printer-state-reasons']?.cast<String>() ?? const [];
    final problem = describePrinterReasons(reasons);
    if (problem != null) return PrinterStatus(PrinterHealth.attention, problem);
    return switch (attrs['printer-state']?.firstOrNull) {
      4 => const PrinterStatus(PrinterHealth.busy, 'Printing'),
      5 => const PrinterStatus(PrinterHealth.attention, 'Stopped'),
      _ => const PrinterStatus(PrinterHealth.ready, 'Ready'),
    };
  }

  try {
    return await ask();
  } catch (_) {
    if (p.serviceName != null) {
      final found = await PrinterDiscovery.scanOnce();
      final match = found
          .where((f) => f.serviceName == p.serviceName)
          .firstOrNull;
      if (match != null && match.host != p.host) {
        AppStore.instance.upsertNetworkPrinter(
          name: p.name,
          host: match.host,
          port: match.port,
          path: match.path,
          serviceName: match.serviceName,
        );
        try {
          return await ask();
        } catch (_) {}
      }
    }
    return const PrinterStatus(
      PrinterHealth.offline,
      'Offline — check it is on and on the same Wi-Fi',
    );
  }
}
