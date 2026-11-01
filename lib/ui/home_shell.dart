import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/store.dart';
import '../pdf_service.dart';
import '../print/discovery.dart';
import 'calibration_screen.dart';
import 'history_tab.dart';
import 'photo_crop_screen.dart';
import 'print_setup_screen.dart';
import 'printers_tab.dart';
import 'scan_screen.dart';
import 'settings_tab.dart';
import 'theme.dart';
import 'widgets.dart';

/// Receives PDFs opened or shared from other apps (Android).
const _filesChannel = MethodChannel('flipprint/files');

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;
  bool _opening = false;
  PrinterStatus _status = PrinterStatus.checking;
  String? _statusFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppStore.instance.addListener(_onStore);
    _autoFindPrinter().then((_) => _refreshStatus());
    _listenForSharedFiles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppStore.instance.removeListener(_onStore);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  /// Re-check when the default printer changes.
  void _onStore() {
    if (AppStore.instance.defaultPrinter.id != _statusFor) _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final printer = AppStore.instance.defaultPrinter;
    _statusFor = printer.id;
    if (mounted) setState(() => _status = PrinterStatus.checking);
    final status = await checkPrinter(printer);
    if (mounted && _statusFor == printer.id) {
      setState(() => _status = status);
    }
  }

  /// First run: look for a network printer and add it automatically.
  Future<void> _autoFindPrinter() async {
    final store = AppStore.instance;
    if (store.printers.any((p) => !p.isSystem)) return;
    final found = await PrinterDiscovery.scanOnce(
      timeout: const Duration(seconds: 5),
    );
    for (final f in found) {
      try {
        final model = await probePrinter(f.host, port: f.port, path: f.path);
        store.upsertNetworkPrinter(
          name: model,
          host: f.host,
          port: f.port,
          path: f.path,
          serviceName: f.serviceName,
        );
        _snack('Found $model on your Wi-Fi');
        break;
      } catch (_) {}
    }
  }

  Future<void> _listenForSharedFiles() async {
    _filesChannel.setMethodCallHandler((call) async {
      if (call.method == 'openFile') _openShared(call.arguments);
    });
    try {
      final initial = await _filesChannel.invokeMethod('getInitialFile');
      if (initial != null) _openShared(initial);
    } on MissingPluginException {
      // Not on Android.
    }
  }

  Future<void> _openShared(Object? args) async {
    if (args is! Map) return;
    final path = args['path'] as String?;
    if (path == null) return;
    final bytes = await File(path).readAsBytes();
    await _openDocument((args['name'] as String?) ?? 'Document.pdf', bytes);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _selectPdf() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (files.isEmpty || !mounted) return;
    setState(() => _opening = true);
    try {
      final file = files.first;
      await _openDocument(file.name, await file.xFile.readAsBytes());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openRecent(RecentDoc doc) async {
    setState(() => _opening = true);
    try {
      await _openDocument(doc.name, await doc.read());
    } catch (_) {
      await AppStore.instance.removeRecent(doc);
      _snack('That file is no longer available');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openDocument(String name, Uint8List bytes) async {
    try {
      final pages = await PdfService(bytes).pageCount();
      if (pages == 0) throw const FormatException('The PDF has no pages');
      if (!mounted) return;
      setState(() => _tab = 0);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              PrintSetupScreen(fileName: name, bytes: bytes, pageCount: pages),
        ),
      );
      _refreshStatus();
    } catch (e) {
      _snack('Could not open the PDF. Is it a valid, unlocked PDF file?');
    }
  }

  void _openScan() =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ScanScreen()));

  void _openPhotoScan() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ScanScreen(camera: true)));

  /// Photo Print: pick a photo (gallery or camera), then crop and place it.
  Future<void> _openPhotoPrint() async {
    final mobile = Platform.isAndroid || Platform.isIOS;
    final source = !mobile
        ? ImageSource.gallery
        : await showModalBottomSheet<ImageSource>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_library_rounded),
                    title: const Text('Choose from gallery'),
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_camera_rounded),
                    title: const Text('Take a photo'),
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
    if (source == null) return;
    final file = await ImagePicker().pickImage(
      source: source,
      preferredCameraDevice: CameraDevice.front,
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PhotoCropScreen(bytes: bytes)));
  }

  void _openCalibration() =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CalibrationScreen()))
          .then((_) => _refreshStatus());

  @override
  Widget build(BuildContext context) {
    const titles = ['FlipPrint', 'History', 'Printer Profiles', 'Settings'];
    return Scaffold(
      appBar: AppBar(
        title: _tab == 0 ? const Wordmark(size: 22) : Text(titles[_tab]),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded, color: Brand.blue),
              onPressed: () => setState(() => _tab = 3),
            ),
        ],
      ),
      drawer: _drawer(),
      body: IndexedStack(
        index: _tab,
        children: [
          _HomeTab(
            opening: _opening,
            status: _status,
            onRefresh: _refreshStatus,
            onSelectPdf: _selectPdf,
            onOpenRecent: _openRecent,
            onTab: (i) => setState(() => _tab = i),
            onCalibrate: _openCalibration,
            onScan: _openScan,
            onPhotoScan: _openPhotoScan,
            onPhotoPrint: _openPhotoPrint,
          ),
          const HistoryTab(),
          const PrintersTab(),
          const SettingsTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.print_outlined),
            selectedIcon: Icon(Icons.print_rounded),
            label: 'Profiles',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _drawer() {
    Widget item(IconData icon, String label, VoidCallback onTap) => ListTile(
      leading: Icon(icon, color: Brand.blue),
      title: Text(label),
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
    );
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(gradient: Brand.gradient),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FlipLogo(size: 48),
                SizedBox(height: 8),
                Wordmark(size: 26, color: Colors.white),
              ],
            ),
          ),
          item(Icons.picture_as_pdf_rounded, 'Select PDF', _selectPdf),
          item(Icons.document_scanner_rounded, 'Scan', _openScan),
          item(Icons.portrait_rounded, 'Photo Print', _openPhotoPrint),
          if (Platform.isAndroid)
            item(Icons.photo_camera_rounded, 'Photo Scan', _openPhotoScan),
          item(
            Icons.print_rounded,
            'Printer Profiles',
            () => setState(() => _tab = 2),
          ),
          item(Icons.tune_rounded, 'Calibration', _openCalibration),
          item(
            Icons.history_rounded,
            'History',
            () => setState(() => _tab = 1),
          ),
          item(
            Icons.settings_rounded,
            'Settings',
            () => setState(() => _tab = 3),
          ),
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.opening,
    required this.status,
    required this.onRefresh,
    required this.onSelectPdf,
    required this.onOpenRecent,
    required this.onTab,
    required this.onCalibrate,
    required this.onScan,
    required this.onPhotoScan,
    required this.onPhotoPrint,
  });

  final bool opening;
  final PrinterStatus status;
  final Future<void> Function() onRefresh;
  final VoidCallback onSelectPdf;
  final ValueChanged<RecentDoc> onOpenRecent;
  final ValueChanged<int> onTab;
  final VoidCallback onCalibrate;
  final VoidCallback onScan;
  final VoidCallback onPhotoScan;
  final VoidCallback onPhotoPrint;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final printer = store.defaultPrinter;
        final latest = store.recent.firstOrNull;
        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              const Text(
                'Automated Duplex\nPrinting Made Easy',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Print odd pages, reinsert paper,\nand let FlipPrint handle the rest.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Brand.grey, height: 1.4),
              ),
              const SizedBox(height: 8),
              Center(
                child: PrinterIllustration(
                  height: 140,
                  label: printer.isSystem
                      ? 'Printer'
                      : printer.name.split(' ').first,
                ),
              ),
              const SizedBox(height: 8),
              _PrinterStatusCard(
                printer: printer,
                status: status,
                onTap: () => onTab(2),
                onRefresh: onRefresh,
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: opening ? null : onSelectPdf,
                icon: opening
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open_rounded),
                label: Text(opening ? 'Opening…' : 'Select PDF'),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: ActionTile(
                      icon: Icons.document_scanner_rounded,
                      label: 'Scan\n',
                      onTap: onScan,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ActionTile(
                      icon: Icons.portrait_rounded,
                      label: 'Photo\nPrint',
                      onTap: onPhotoPrint,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ActionTile(
                      icon: Icons.tune_rounded,
                      label: 'Calibration\n',
                      onTap: onCalibrate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // The camera scanner is Android-only; elsewhere keep Settings.
                    child: Platform.isAndroid
                        ? ActionTile(
                            icon: Icons.photo_camera_rounded,
                            label: 'Photo\nScan',
                            onTap: onPhotoScan,
                          )
                        : ActionTile(
                            icon: Icons.settings_rounded,
                            label: 'Settings\n',
                            onTap: () => onTab(3),
                          ),
                  ),
                ],
              ),
              if (!printer.isSystem && !printer.calibrated) ...[
                const SizedBox(height: 14),
                InfoBox(
                  icon: Icons.lightbulb_rounded,
                  color: Brand.warning,
                  background: const Color(0xFFFFF6E0),
                  child: GestureDetector(
                    onTap: onCalibrate,
                    child: const Text.rich(
                      TextSpan(
                        text: 'First time? ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                        children: [
                          TextSpan(
                            text:
                                'Calibrate once (2 sheets) so back sides always '
                                'come out right. ',
                            style: TextStyle(fontWeight: FontWeight.w400),
                          ),
                          TextSpan(
                            text: 'Calibrate now',
                            style: TextStyle(color: Brand.blue),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (latest != null) ...[
                Row(
                  children: [
                    const Expanded(child: SectionLabel('Latest document')),
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextButton(
                        onPressed: () => onTab(1),
                        child: const Text('See all in History'),
                      ),
                    ),
                  ],
                ),
                _RecentTile(
                  doc: latest,
                  enabled: !opening,
                  onOpen: () => onOpenRecent(latest),
                  onRemove: () => store.removeRecent(latest),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PrinterStatusCard extends StatelessWidget {
  const _PrinterStatusCard({
    required this.printer,
    required this.status,
    required this.onTap,
    required this.onRefresh,
  });

  final SavedPrinter printer;
  final PrinterStatus status;
  final VoidCallback onTap;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (status.health) {
      PrinterHealth.ready => (Brand.success, Icons.check_circle_rounded),
      PrinterHealth.busy => (Brand.blue, Icons.print_rounded),
      PrinterHealth.attention => (Brand.warning, Icons.warning_rounded),
      PrinterHealth.offline => (
        Theme.of(context).colorScheme.error,
        Icons.wifi_off_rounded,
      ),
      _ => (Brand.grey, Icons.print_outlined),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: status.health == PrinterHealth.checking
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      printer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status.label,
                      maxLines: 2,
                      style: TextStyle(
                        color: status.health == PrinterHealth.ready
                            ? Brand.success
                            : status.health == PrinterHealth.checking ||
                                  status.health == PrinterHealth.system
                            ? Brand.grey
                            : color,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (printer.calibrated)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Brand.tint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Calibrated',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Brand.blue,
                    ),
                  ),
                ),
              if (status.health == PrinterHealth.offline)
                IconButton(
                  tooltip: 'Check again',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                )
              else
                const Icon(Icons.chevron_right_rounded, color: Brand.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({
    required this.doc,
    required this.enabled,
    required this.onOpen,
    required this.onRemove,
  });

  final RecentDoc doc;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final d = doc.lastUsed;
    final now = DateTime.now();
    final when = now.difference(d).inDays == 0
        ? 'Today ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : '${d.day}/${d.month}/${d.year}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey(doc.path),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onRemove(),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.delete_outline_rounded),
        ),
        child: Card(
          child: ListTile(
            enabled: enabled,
            onTap: onOpen,
            leading: const Icon(
              Icons.picture_as_pdf_rounded,
              color: Color(0xFFE5483B),
              size: 30,
            ),
            title: Text(
              doc.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${doc.pages} page${doc.pages == 1 ? '' : 's'} • $when',
            ),
            trailing: const Icon(Icons.print_rounded, color: Brand.blue),
          ),
        ),
      ),
    );
  }
}
