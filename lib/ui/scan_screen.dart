import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../scan/wsd_scanner.dart';
import 'print_setup_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class _Page {
  _Page(this.jpeg, this.format, {this.fill = true});
  final Uint8List jpeg;
  final PdfPageFormat format;

  /// Flatbed scans fill their page; camera photos are fitted onto paper.
  final bool fill;
}

/// Scans pages into a PDF that can be saved, shared, or printed
/// (double-sided) right away — from the printer's flatbed, or with [camera]
/// from the phone camera (edge detection, crop and clean-up by ML Kit).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.camera = false});

  final bool camera;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _pages = <_Page>[];
  SavedPrinter? _device;
  ScanColor _color = ScanColor.color;
  int _dpi = 300;
  ScanArea _area = ScanArea.a4;

  String? _status; // null while checking
  bool _ready = false;
  bool _scanning = false;
  int _elapsed = 0;
  Timer? _ticker;
  bool _busy = false; // building / sharing the PDF

  @override
  void initState() {
    super.initState();
    final store = AppStore.instance;
    final d = store.defaultPrinter;
    _device = d.isSystem
        ? store.printers.where((p) => !p.isSystem).firstOrNull
        : d;
    if (widget.camera) {
      // Go straight to the camera, like a scanner app.
      WidgetsBinding.instance.addPostFrameCallback((_) => _cameraScan());
    } else {
      _checkScanner();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  WsdScanner? get _scanner =>
      _device?.host == null ? null : WsdScanner(host: _device!.host!);

  Future<void> _checkScanner() async {
    final scanner = _scanner;
    if (scanner == null) {
      setState(() {
        _status = 'Add your Wi-Fi printer in Profiles to scan';
        _ready = false;
      });
      return;
    }
    setState(() => _status = null);
    try {
      final (state, conditions) = await scanner.status();
      if (!mounted) return;
      setState(() {
        _ready = state != 'Stopped';
        _status = switch (state) {
          'Idle' => 'Ready',
          'Processing' => 'Busy — another scan is running',
          _ => conditions.isNotEmpty ? conditions.first : state,
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _status = 'Scanner not reachable — is the printer on?';
      });
    }
  }

  Future<void> _scan() async {
    final scanner = _scanner;
    if (scanner == null) return;
    setState(() {
      _scanning = true;
      _elapsed = 0;
    });
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _elapsed++),
    );
    try {
      final jpeg = await scanner.scan(dpi: _dpi, color: _color, area: _area);
      if (!mounted) return;
      final format = PdfPageFormat(
        _area.width / 1000 * PdfPageFormat.inch,
        _area.height / 1000 * PdfPageFormat.inch,
      );
      setState(() => _pages.add(_Page(jpeg, format)));
      HapticFeedback.mediumImpact();
    } catch (e) {
      _snack('$e');
    } finally {
      _ticker?.cancel();
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Opens Google's document scanner (Android). It finds the page edges,
  /// straightens and cleans the photo; each page comes back as a JPEG.
  Future<void> _cameraScan() async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        mode: ScannerMode.full,
        pageLimit: 50,
        isGalleryImport: true,
      ),
    );
    setState(() => _scanning = true);
    try {
      final result = await scanner.scanDocument();
      final paper = AppStore.instance.settings.paper;
      final (w, h) = paper.points;
      final format = PdfPageFormat(w.toDouble(), h.toDouble());
      final added = [
        for (final path in result.images ?? const <String>[])
          _Page(await File(path).readAsBytes(), format, fill: false),
      ];
      if (!mounted) return;
      setState(() => _pages.addAll(added));
      if (added.isNotEmpty) HapticFeedback.mediumImpact();
    } on PlatformException catch (e) {
      if (!(e.message ?? '').toLowerCase().contains('cancel')) {
        _snack('Camera scanner unavailable: ${e.message}');
      }
    } catch (e) {
      _snack('$e');
    } finally {
      scanner.close();
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String get _fileName {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan_${d.year}${two(d.month)}${two(d.day)}_'
        '${two(d.hour)}${two(d.minute)}.pdf';
  }

  Future<Uint8List> _buildPdf() async {
    final doc = pw.Document(title: 'FlipPrint scan');
    for (final p in _pages) {
      final image = pw.MemoryImage(p.jpeg);
      doc.addPage(
        pw.Page(
          pageFormat: p.format,
          margin: p.fill ? pw.EdgeInsets.zero : const pw.EdgeInsets.all(18),
          build: (_) => p.fill
              ? pw.SizedBox.expand(child: pw.Image(image, fit: pw.BoxFit.fill))
              : pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ),
      );
    }
    return doc.save();
  }

  // The PDF built for the current pages, reused until the pages change.
  List<_Page>? _builtFor;
  late Uint8List _builtPdf;
  late String _builtName;
  late RecentDoc _builtDoc;
  bool _scanRecorded = false;

  Future<void> _withPdf(
    Future<void> Function(Uint8List pdf, String name, RecentDoc doc) fn, {
    bool recordScan = true,
  }) async {
    setState(() => _busy = true);
    try {
      if (_builtFor == null || !listEquals(_builtFor, _pages)) {
        _builtPdf = await _buildPdf();
        _builtName = _fileName;
        _builtDoc = await AppStore.instance.addRecent(
          _builtName,
          _builtPdf,
          _pages.length,
        );
        _builtFor = List.of(_pages);
        _scanRecorded = false;
      }
      if (recordScan && !_scanRecorded) {
        _scanRecorded = true;
        AppStore.instance.addHistory(
          HistoryEntry(
            kind: HistoryKind.scan,
            docPath: _builtDoc.path,
            fileName: _builtName,
            pages: _pages.length,
            copies: 1,
            sheets: 0,
            printerName: _device?.name ?? 'Scanner',
            duplex: false,
          ),
        );
      }
      await fn(_builtPdf, _builtName, _builtDoc);
    } catch (e) {
      _snack('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _withPdf((pdf, name, _) async {
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: pdf,
      mimeType: 'application/pdf',
      dialogTitle: 'Save scan',
    );
    if (uri != null) _snack('Saved $name');
  });

  Future<void> _share() => _withPdf((pdf, name, _) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(pdf);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/pdf')],
        subject: name,
      ),
    );
  });

  Future<void> _print() => _withPdf(recordScan: false, (pdf, name, _) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrintSetupScreen(
          fileName: name,
          bytes: pdf,
          pageCount: _pages.length,
          kind: HistoryKind.copy,
        ),
      ),
    );
  });

  /// Pages already saved to History (by Share, Save or Print) aren't lost.
  bool get _unsaved =>
      _pages.isNotEmpty &&
      !(_builtFor != null && listEquals(_builtFor, _pages));

  Future<bool> _confirmDiscard() async {
    if (!_unsaved) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard scanned pages?'),
        content: Text(
          '${_pages.length} page${_pages.length == 1 ? '' : 's'} will be lost '
          'unless you save or share them first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _viewPage(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(
              'Page ${index + 1}',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          body: InteractiveViewer(
            maxScale: 6,
            child: Center(child: Image.memory(_pages[index].jpeg)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_unsaved && !_scanning,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _scanning) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.camera ? 'Photo Scan' : 'Scan'),
          actions: [
            if (_pages.isNotEmpty && !_scanning)
              IconButton(
                tooltip: 'Start over',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  if (await _confirmDiscard()) setState(_pages.clear);
                },
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (!widget.camera) ...[_scannerCard(), const SizedBox(height: 12)],
            if (_pages.isEmpty) _emptyState() else _pageStrip(),
            if (!widget.camera) ...[
              const SectionLabel('Scan settings'),
              _settingsCard(),
            ],
          ],
        ),
        bottomNavigationBar: _bottomBar(),
      ),
    );
  }

  Widget _scannerCard() {
    final checking = _status == null;
    final color = checking
        ? Brand.grey
        : _ready
        ? Brand.success
        : Theme.of(context).colorScheme.error;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: checking
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.document_scanner_rounded, color: color),
        ),
        title: Text(
          _device?.name ?? 'No scanner',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          _status ?? 'Checking scanner…',
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        trailing: checking || _ready
            ? null
            : IconButton(
                tooltip: 'Check again',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _checkScanner,
              ),
      ),
    );
  }

  Widget _emptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: const BoxDecoration(
                color: Brand.tint,
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.camera
                    ? Icons.photo_camera_rounded
                    : Icons.document_scanner_rounded,
                size: 56,
                color: Brand.blue,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Ready to scan',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              widget.camera
                  ? 'Lay the page on a flat, contrasting surface with good light '
                        'and hold the phone above it. The edges are found and '
                        'straightened for you.'
                  : 'Lift the scanner lid, place your page face down in the '
                        'corner marked with the arrow, and close the lid.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Brand.grey, height: 1.45),
            ),
            const SizedBox(height: 14),
            const InfoBox(
              icon: Icons.layers_rounded,
              child: Text(
                'Scan several pages one after another — they become one PDF '
                'you can save, share or print double-sided.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageStrip() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text(
            '${_pages.length} page${_pages.length == 1 ? '' : 's'} scanned'
            '${_pages.length > 1 ? ' — hold and drag to reorder' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 230,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _pages.length,
            proxyDecorator: (child, _, _) =>
                Material(color: Colors.transparent, elevation: 6, child: child),
            onReorderItem: (from, to) =>
                setState(() => _pages.insert(to, _pages.removeAt(from))),
            itemBuilder: (context, i) => Padding(
              key: ObjectKey(_pages[i]),
              padding: const EdgeInsets.only(right: 12),
              child: _PageCard(
                index: i,
                page: _pages[i],
                onView: () => _viewPage(i),
                onDelete: () => setState(() => _pages.removeAt(i)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Colour', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ScanColor>(
                showSelectedIcon: false,
                style: _segStyle,
                segments: [
                  for (final c in ScanColor.values)
                    ButtonSegment(value: c, label: Text(c.label)),
                ],
                selected: {_color},
                onSelectionChanged: _scanning
                    ? null
                    : (s) => setState(() => _color = s.first),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Quality',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                style: _segStyle,
                segments: const [
                  ButtonSegment(value: 100, label: Text('Draft · fast')),
                  ButtonSegment(value: 300, label: Text('Best · 300 dpi')),
                ],
                selected: {_dpi},
                onSelectionChanged: _scanning
                    ? null
                    : (s) => setState(() => _dpi = s.first),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Page size',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                DropdownButton<ScanArea>(
                  value: _area,
                  underline: const SizedBox(),
                  borderRadius: BorderRadius.circular(12),
                  items: [
                    for (final a in ScanArea.values)
                      DropdownMenuItem(value: a, child: Text(a.label)),
                  ],
                  onChanged: _scanning
                      ? null
                      : (a) => setState(() => _area = a!),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle get _segStyle => SegmentedButton.styleFrom(
    selectedBackgroundColor: Brand.blue,
    selectedForegroundColor: Colors.white,
  );

  Widget _bottomBar() {
    final hasPages = _pages.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_scanning && !widget.camera) ...[
                Row(
                  children: [
                    const Icon(
                      Icons.document_scanner_rounded,
                      color: Brand.blue,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Scanning page ${_pages.length + 1}… keep the lid closed',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${_elapsed}s',
                      style: const TextStyle(color: Brand.grey),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    backgroundColor: Brand.tint,
                  ),
                ),
              ] else ...[
                if (widget.camera)
                  FilledButton.icon(
                    onPressed: _busy || _scanning ? null : _cameraScan,
                    icon: Icon(
                      hasPages ? Icons.add_rounded : Icons.photo_camera_rounded,
                    ),
                    label: Text(
                      hasPages ? 'Add more pages' : 'Scan with camera',
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: _ready && !_busy ? _scan : null,
                    icon: Icon(
                      hasPages
                          ? Icons.add_rounded
                          : Icons.document_scanner_rounded,
                    ),
                    label: Text(hasPages ? 'Scan next page' : 'Scan page'),
                  ),
                if (hasPages) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _action(Icons.print_rounded, 'Print copies', _print),
                      const SizedBox(width: 8),
                      _action(Icons.ios_share_rounded, 'Share', _share),
                      const SizedBox(width: 8),
                      _action(Icons.save_alt_rounded, 'Save PDF', _save),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => Expanded(
    child: OutlinedButton(
      onPressed: _busy ? null : onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.index,
    required this.page,
    required this.onView,
    required this.onDelete,
  });

  final int index;
  final _Page page;
  final VoidCallback onView;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onView,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFD5DDEC)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x14000000), blurRadius: 6),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Image.memory(
                        page.jpeg,
                        fit: page.fill ? BoxFit.cover : BoxFit.contain,
                        cacheWidth: 300,
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onDelete,
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Page ${index + 1}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
