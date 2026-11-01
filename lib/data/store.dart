import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../duplex_plan.dart';
import '../photo/photo_layout.dart';

enum PrinterKind { ipp, system }

/// A printer the app can print to, with its manual-duplex calibration.
class SavedPrinter {
  SavedPrinter({
    required this.id,
    required this.name,
    required this.kind,
    this.host,
    this.port = 631,
    this.path = 'ipp/print',
    this.serviceName,
    this.reverseBack = true,
    this.rotateBack = false,
    this.calibrated = false,
  });

  /// Sends through Android's print dialog (Mopria, Epson plug-in, etc.).
  factory SavedPrinter.system() => SavedPrinter(
    id: 'system',
    name: 'Other printer (system dialog)',
    kind: PrinterKind.system,
  );

  factory SavedPrinter.fromJson(Map<String, dynamic> j) => SavedPrinter(
    id: j['id'],
    name: j['name'],
    kind: PrinterKind.values.byName(j['kind']),
    host: j['host'],
    port: j['port'] ?? 631,
    path: j['path'] ?? 'ipp/print',
    serviceName: j['serviceName'],
    reverseBack: j['reverseBack'] ?? true,
    rotateBack: j['rotateBack'] ?? false,
    calibrated: j['calibrated'] ?? false,
  );

  final String id;
  String name;
  final PrinterKind kind;
  String? host;
  int port;
  String path;

  /// mDNS service name, used to find the printer again if its IP changes.
  String? serviceName;
  bool reverseBack;
  bool rotateBack;
  bool calibrated;

  bool get isSystem => kind == PrinterKind.system;
  PrinterProfile get profile =>
      PrinterProfile(reverseBack: reverseBack, rotateBack: rotateBack);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'host': host,
    'port': port,
    'path': path,
    'serviceName': serviceName,
    'reverseBack': reverseBack,
    'rotateBack': rotateBack,
    'calibrated': calibrated,
  };
}

enum Paper {
  a4('A4', 'iso_a4_210x297mm', 210, 297),
  letter('Letter', 'na_letter_8.5x11in', 215.9, 279.4),
  legal('Legal', 'na_legal_8.5x14in', 215.9, 355.6),
  a5('A5', 'iso_a5_148x210mm', 148, 210);

  const Paper(this.label, this.media, this.widthMm, this.heightMm);
  final String label;
  final String media;
  final double widthMm;
  final double heightMm;

  int pixelsWide(int dpi) => (widthMm / 25.4 * dpi).floor();
  int pixelsHigh(int dpi) => (heightMm / 25.4 * dpi).floor();
  (int, int) get points =>
      ((widthMm / 25.4 * 72).round(), (heightMm / 25.4 * 72).round());
}

class AppSettings {
  bool highQuality = false;
  bool color = true;
  bool markBlanks = true;
  Paper paper = Paper.a4;
  DuplexBinding binding = DuplexBinding.book;
  String defaultPrinterId = 'system';

  Map<String, dynamic> toJson() => {
    'highQuality': highQuality,
    'color': color,
    'markBlanks': markBlanks,
    'paper': paper.name,
    'binding': binding.name,
    'defaultPrinterId': defaultPrinterId,
  };

  void apply(Map<String, dynamic> j) {
    highQuality = j['highQuality'] ?? highQuality;
    color = j['color'] ?? color;
    markBlanks = j['markBlanks'] ?? markBlanks;
    paper = Paper.values.asNameMap()[j['paper']] ?? paper;
    binding = DuplexBinding.values.asNameMap()[j['binding']] ?? binding;
    defaultPrinterId = j['defaultPrinterId'] ?? defaultPrinterId;
  }
}

enum HistoryKind {
  print('Print'),
  scan('Scan'),
  copy('Copy');

  const HistoryKind(this.label);
  final String label;
}

class HistoryEntry {
  HistoryEntry({
    this.kind = HistoryKind.print,
    this.docPath,
    required this.fileName,
    required this.pages,
    required this.copies,
    required this.sheets,
    required this.printerName,
    required this.duplex,
    this.status = 'completed',
    DateTime? date,
  }) : date = date ?? DateTime.now();

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    kind: HistoryKind.values.asNameMap()[j['kind']] ?? HistoryKind.print,
    docPath: j['docPath'],
    fileName: j['fileName'],
    pages: j['pages'],
    copies: j['copies'],
    sheets: j['sheets'],
    printerName: j['printerName'],
    duplex: j['duplex'],
    status: j['status'],
    date: DateTime.parse(j['date']),
  );

  final HistoryKind kind;

  /// Saved copy of the PDF, so it can be printed or shared again.
  final String? docPath;
  final String fileName;
  final int pages;
  final int copies;
  final int sheets;
  final String printerName;
  final bool duplex;
  final String status; // completed | cancelled | failed
  final DateTime date;

  bool get hasDoc => docPath != null && File(docPath!).existsSync();

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'docPath': docPath,
    'fileName': fileName,
    'pages': pages,
    'copies': copies,
    'sheets': sheets,
    'printerName': printerName,
    'duplex': duplex,
    'status': status,
    'date': date.toIso8601String(),
  };
}

/// A PDF kept on the device so it can be printed again with one tap.
class RecentDoc {
  RecentDoc({
    required this.name,
    required this.path,
    required this.pages,
    required this.size,
    DateTime? lastUsed,
  }) : lastUsed = lastUsed ?? DateTime.now();

  factory RecentDoc.fromJson(Map<String, dynamic> j) => RecentDoc(
    name: j['name'],
    path: j['path'],
    pages: j['pages'],
    size: j['size'],
    lastUsed: DateTime.parse(j['lastUsed']),
  );

  final String name;
  final String path;
  final int pages;
  final int size;
  DateTime lastUsed;

  Future<Uint8List> read() => File(path).readAsBytes();

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'pages': pages,
    'size': size,
    'lastUsed': lastUsed.toIso8601String(),
  };
}

/// App-wide state, persisted in shared preferences.
class AppStore extends ChangeNotifier {
  AppStore._();
  static final instance = AppStore._();

  final settings = AppSettings();
  final List<SavedPrinter> printers = [SavedPrinter.system()];
  final List<HistoryEntry> history = [];
  final List<RecentDoc> recent = [];
  final List<PhotoPreset> photoPresets = [];
  static const _maxRecent = 40;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('settings');
    if (s != null) settings.apply(jsonDecode(s));
    final p = prefs.getString('printers');
    if (p != null) {
      printers
        ..clear()
        ..addAll([
          for (final j in jsonDecode(p) as List) SavedPrinter.fromJson(j),
        ]);
      if (!printers.any((e) => e.isSystem)) printers.add(SavedPrinter.system());
    }
    final h = prefs.getString('history');
    if (h != null) {
      history.addAll([
        for (final j in jsonDecode(h) as List) HistoryEntry.fromJson(j),
      ]);
    }
    final r = prefs.getString('recent');
    if (r != null) {
      recent.addAll([
        for (final j in jsonDecode(r) as List) RecentDoc.fromJson(j),
      ]);
      recent.removeWhere((d) => !File(d.path).existsSync());
    }
    final ph = prefs.getString('photoPresets');
    if (ph != null) {
      photoPresets.addAll([
        for (final j in jsonDecode(ph) as List) PhotoPreset.fromJson(j),
      ]);
    }
    notifyListeners();
  }

  Future<void> save() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings', jsonEncode(settings.toJson()));
    await prefs.setString(
      'printers',
      jsonEncode([for (final p in printers) p.toJson()]),
    );
    await prefs.setString(
      'history',
      jsonEncode([for (final h in history) h.toJson()]),
    );
    await prefs.setString(
      'recent',
      jsonEncode([for (final d in recent) d.toJson()]),
    );
    await prefs.setString(
      'photoPresets',
      jsonEncode([for (final p in photoPresets) p.toJson()]),
    );
  }

  Future<void> addPhotoPreset(PhotoPreset preset) {
    photoPresets.add(preset);
    return save();
  }

  Future<void> removePhotoPreset(PhotoPreset preset) {
    photoPresets.remove(preset);
    return save();
  }

  /// Keeps a copy of [bytes] so it shows up under recent documents.
  Future<RecentDoc> addRecent(String name, Uint8List bytes, int pages) async {
    final existing = recent
        .where((d) => d.name == name && d.size == bytes.length)
        .firstOrNull;
    if (existing != null) {
      existing.lastUsed = DateTime.now();
      recent
        ..remove(existing)
        ..insert(0, existing);
      await save();
      return existing;
    }
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/recent',
    );
    await dir.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    final file = File(
      '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe',
    );
    await file.writeAsBytes(bytes);
    final doc = RecentDoc(
      name: name,
      path: file.path,
      pages: pages,
      size: bytes.length,
    );
    recent.insert(0, doc);
    while (recent.length > _maxRecent) {
      await _deleteIfUnused(recent.removeLast().path);
    }
    await save();
    return doc;
  }

  Future<void> removeRecent(RecentDoc doc) async {
    recent.remove(doc);
    await _deleteIfUnused(doc.path);
    await save();
  }

  SavedPrinter get defaultPrinter => printers.firstWhere(
    (p) => p.id == settings.defaultPrinterId,
    orElse: () => printers.first,
  );

  SavedPrinter? printerById(String id) =>
      printers.where((p) => p.id == id).firstOrNull;

  /// Adds or updates a network printer; the first one becomes the default.
  SavedPrinter upsertNetworkPrinter({
    required String name,
    required String host,
    int port = 631,
    String path = 'ipp/print',
    String? serviceName,
  }) {
    var printer = printers
        .where(
          (p) =>
              !p.isSystem &&
              ((serviceName != null && p.serviceName == serviceName) ||
                  p.host == host),
        )
        .firstOrNull;
    if (printer == null) {
      printer = SavedPrinter(
        id: 'ipp-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        kind: PrinterKind.ipp,
        host: host,
        port: port,
        path: path,
        serviceName: serviceName,
      );
      printers.insert(0, printer);
      if (settings.defaultPrinterId == 'system') {
        settings.defaultPrinterId = printer.id;
      }
    } else {
      printer
        ..host = host
        ..port = port
        ..path = path
        ..serviceName = serviceName ?? printer.serviceName;
    }
    save();
    return printer;
  }

  void removePrinter(SavedPrinter p) {
    if (p.isSystem) return;
    printers.remove(p);
    if (settings.defaultPrinterId == p.id) {
      settings.defaultPrinterId = printers.first.id;
    }
    save();
  }

  void addHistory(HistoryEntry e) {
    history.insert(0, e);
    while (history.length > 200) {
      final old = history.removeLast();
      if (old.docPath != null) _deleteIfUnused(old.docPath!);
    }
    save();
  }

  void removeHistory(HistoryEntry e) {
    history.remove(e);
    if (e.docPath != null) _deleteIfUnused(e.docPath!);
    save();
  }

  void clearHistory() {
    final paths = [for (final h in history) ?h.docPath];
    history.clear();
    for (final p in paths) {
      _deleteIfUnused(p);
    }
    save();
  }

  /// Saved PDFs are shared by recent documents and history entries; delete
  /// one only when nothing points at it any more.
  Future<void> _deleteIfUnused(String path) async {
    final used =
        recent.any((d) => d.path == path) ||
        history.any((h) => h.docPath == path);
    if (used) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
