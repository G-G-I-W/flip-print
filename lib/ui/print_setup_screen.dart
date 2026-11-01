import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/store.dart';
import '../duplex_plan.dart';
import '../pdf_service.dart';
import '../print/discovery.dart';
import '../print/print_engine.dart';
import 'calibration_screen.dart';
import 'printers_tab.dart';
import 'progress_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class PrintSetupScreen extends StatefulWidget {
  const PrintSetupScreen({
    super.key,
    required this.fileName,
    required this.bytes,
    required this.pageCount,
    this.kind = HistoryKind.print,
  });

  /// Print, or Copy when the document came straight from the scanner.
  final HistoryKind kind;
  final String fileName;
  final Uint8List bytes;
  final int pageCount;

  @override
  State<PrintSetupScreen> createState() => _PrintSetupScreenState();
}

class _PrintSetupScreenState extends State<PrintSetupScreen> {
  final _store = AppStore.instance;
  final _range = TextEditingController();
  // Own controller so a new screen doesn't restore an older one's scroll.
  final _scroll = ScrollController(keepScrollOffset: false);

  late String _fileName = widget.fileName;
  late Uint8List _bytes = widget.bytes;
  late int _pageCount = widget.pageCount;
  late SavedPrinter _printer = _store.defaultPrinter;
  late Paper _paper = _store.settings.paper;
  int _copies = 1;
  bool _duplex = true;
  PageOrientation _orientation = PageOrientation.auto;
  late DuplexBinding _binding = _store.settings.binding;
  PrinterStatus _status = PrinterStatus.checking;
  int _docVersion = 0; // bumps when the file changes, to reset thumbnails

  @override
  void initState() {
    super.initState();
    _remember();
    _checkPrinter();
  }

  @override
  void dispose() {
    _range.dispose();
    _scroll.dispose();
    super.dispose();
  }

  late Future<RecentDoc> _saved;

  void _remember() {
    _saved = _store.addRecent(_fileName, _bytes, _pageCount);
    unawaited(_saved.then((_) {}, onError: (_) {}));
  }

  Future<void> _checkPrinter() async {
    setState(() => _status = PrinterStatus.checking);
    final printer = _printer;
    final status = await checkPrinter(printer);
    if (mounted && printer == _printer) setState(() => _status = status);
  }

  (List<int>?, String?) get _pages {
    try {
      return (parsePageRange(_range.text, _pageCount), null);
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  void _togglePage(int page) {
    final current = (_pages.$1 ?? []).toSet();
    if (!current.remove(page)) current.add(page);
    if (current.isEmpty) return; // keep at least one page
    setState(() => _range.text = formatPageRange(current, _pageCount));
  }

  Future<void> _changeFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (files.isEmpty) return;
    final bytes = await files.first.xFile.readAsBytes();
    final count = await PdfService(bytes).pageCount();
    setState(() {
      _fileName = files.first.name;
      _bytes = bytes;
      _pageCount = count;
      _docVersion++;
      _range.clear();
    });
    _remember();
  }

  Future<void> _start() async {
    final pages = _pages.$1;
    if (pages == null) return;
    String? docPath;
    try {
      docPath = (await _saved).path;
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProgressScreen(
          request: PrintRequest(
            fileName: _fileName,
            pdf: _bytes,
            pages: pages,
            copies: _copies,
            duplex: _duplex,
            printer: _printer,
            paper: _paper,
            orientation: _orientation,
            binding: _binding,
            kind: widget.kind,
            docPath: docPath,
          ),
        ),
      ),
    );
    if (mounted) _checkPrinter();
  }

  @override
  Widget build(BuildContext context) {
    final (pages, rangeError) = _pages;
    final selected = pages?.toSet() ?? const <int>{};
    final sheets = pages == null
        ? null
        : _duplex
        ? DuplexPlan.build(pages: pages, copies: _copies).sheetCount
        : pages.length * _copies;
    final totalPages = pages == null ? 0 : pages.length * _copies;
    final size = _bytes.length < 1024 * 1024
        ? '${(_bytes.length / 1024).ceil()} KB'
        : '${(_bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB';
    final offline = _status.health == PrinterHealth.offline;

    return Scaffold(
      appBar: AppBar(title: const Text('Print Settings')),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _FileHeader(
            name: _fileName,
            detail: '$_pageCount page${_pageCount == 1 ? '' : 's'} • $size',
            onChange: _changeFile,
          ),

          // ---------------------------------------------------------- pages
          const SectionLabel('Pages'),
          _PageStrip(
            key: ValueKey(_docVersion),
            pdf: _bytes,
            pageCount: _pageCount,
            selected: selected,
            onToggle: _togglePage,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _range,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.filter_list_rounded),
                    hintText: 'All pages — or type e.g. 1-4, 7',
                    errorText: rangeError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (_range.text.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(_range.clear),
                  child: const Text('All'),
                ),
              ],
            ],
          ),

          // ------------------------------------------------------- printer
          const SectionLabel('Printer'),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              leading: _StatusDot(status: _status),
              title: Text(
                _printer.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                _printer.isSystem
                    ? _status.label
                    : '${_status.label}'
                          '${_printer.calibrated ? ' • Calibrated' : ' • Not calibrated'}',
                style: TextStyle(
                  color: switch (_status.health) {
                    PrinterHealth.offline || PrinterHealth.attention =>
                      Theme.of(context).colorScheme.error,
                    _ => Brand.grey,
                  },
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (offline)
                    IconButton(
                      tooltip: 'Check again',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: _checkPrinter,
                    ),
                  const Icon(Icons.expand_more_rounded),
                ],
              ),
              onTap: () async {
                final p = await showPrinterPicker(context, _printer);
                if (p != null && p != _printer) {
                  setState(() => _printer = p);
                  _checkPrinter();
                }
              },
            ),
          ),

          // ------------------------------------------------------- options
          const SectionLabel('Options'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _OptionRow(
                    icon: Icons.copy_all_rounded,
                    label: 'Copies',
                    child: _Stepper(
                      value: _copies,
                      onChanged: (v) => setState(() => _copies = v),
                    ),
                  ),
                  const Divider(height: 20),
                  _OptionRow(
                    icon: Icons.description_outlined,
                    label: 'Paper size',
                    child: DropdownButton<Paper>(
                      value: _paper,
                      underline: const SizedBox(),
                      borderRadius: BorderRadius.circular(12),
                      items: [
                        for (final p in Paper.values)
                          DropdownMenuItem(value: p, child: Text(p.label)),
                      ],
                      onChanged: (p) => setState(() => _paper = p!),
                    ),
                  ),
                  const Divider(height: 20),
                  const _OptionRow(
                    icon: Icons.screen_rotation_alt_rounded,
                    label: 'Orientation',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<PageOrientation>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: Brand.blue,
                        selectedForegroundColor: Colors.white,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: PageOrientation.auto,
                          label: Text('Auto'),
                        ),
                        ButtonSegment(
                          value: PageOrientation.portrait,
                          label: Text('Portrait'),
                        ),
                        ButtonSegment(
                          value: PageOrientation.landscape,
                          label: Text('Landscape'),
                        ),
                      ],
                      selected: {_orientation},
                      onSelectionChanged: (s) =>
                          setState(() => _orientation = s.first),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // -------------------------------------------------------- duplex
          const SectionLabel('Double-sided'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text(
                    'Duplex Mode',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Manual duplex — you flip the paper'),
                  value: _duplex,
                  onChanged: (v) => setState(() => _duplex = v),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 250),
                  crossFadeState: _duplex
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  firstChild: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Flip style',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        _BindingPicker(
                          value: _binding,
                          onChanged: (b) {
                            setState(() => _binding = b);
                            _store.settings.binding = b;
                            _store.save();
                          },
                        ),
                        const SizedBox(height: 12),
                        const _DuplexSteps(),
                      ],
                    ),
                  ),
                  secondChild: const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
          if (_duplex && !_printer.isSystem && !_printer.calibrated) ...[
            const SizedBox(height: 10),
            InfoBox(
              icon: Icons.warning_amber_rounded,
              color: Brand.warning,
              background: const Color(0xFFFFF6E0),
              child: GestureDetector(
                onTap: () => Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => const CalibrationScreen(),
                      ),
                    )
                    .then((_) => setState(() {})),
                child: const Text(
                  'This printer isn\'t calibrated, so back sides may come out '
                  'in the wrong order. Tap to calibrate (2 sheets).',
                ),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: _BottomBar(
        summary: pages == null
            ? 'Fix the page range to continue'
            : '$totalPages page${totalPages == 1 ? '' : 's'} on '
                  '$sheets sheet${sheets == 1 ? '' : 's'}',
        saving: _duplex && pages != null ? totalPages - sheets! : 0,
        enabled: pages != null,
        onStart: _start,
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({
    required this.name,
    required this.detail,
    required this.onChange,
  });

  final String name;
  final String detail;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: Brand.tint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(color: Color(0x14000000), blurRadius: 6),
              ],
            ),
            child: const Icon(
              Icons.picture_as_pdf_rounded,
              color: Color(0xFFE5483B),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(color: Brand.grey)),
              ],
            ),
          ),
          TextButton(onPressed: onChange, child: const Text('Change')),
        ],
      ),
    );
  }
}

/// Horizontal strip of page thumbnails; tap to include or skip a page.
class _PageStrip extends StatefulWidget {
  const _PageStrip({
    super.key,
    required this.pdf,
    required this.pageCount,
    required this.selected,
    required this.onToggle,
  });

  final Uint8List pdf;
  final int pageCount;
  final Set<int> selected;
  final ValueChanged<int> onToggle;

  @override
  State<_PageStrip> createState() => _PageStripState();
}

class _PageStripState extends State<_PageStrip> {
  final _thumbs = <int, Future<Uint8List>>{};
  Future<void> _queue = Future.value();

  /// Renders thumbnails one at a time so scrolling stays smooth.
  Future<Uint8List> _thumb(int page) => _thumbs[page] ??= () {
    final c = Completer<Uint8List>();
    _queue = _queue.then((_) async {
      try {
        final raster = await Printing.raster(
          widget.pdf,
          pages: [page - 1],
          dpi: 28,
        ).first;
        c.complete(await raster.toPng());
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.pageCount,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final page = i + 1;
          final on = widget.selected.contains(page);
          return GestureDetector(
            onTap: () => widget.onToggle(page),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: on ? 1 : 0.4,
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 88,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: on ? Brand.blue : const Color(0xFFD5DDEC),
                        width: on ? 2 : 1,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Color(0x10000000), blurRadius: 4),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: FutureBuilder<Uint8List>(
                            future: _thumb(page),
                            builder: (context, snap) => snap.hasData
                                ? Image.memory(snap.data!, fit: BoxFit.contain)
                                : const Center(
                                    child: SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Icon(
                            on
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: on ? Brand.blue : Brand.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$page',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: on ? Brand.navy : Brand.grey,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "1 → flip → 2" mini diagram explaining manual duplex.
/// Book (turn sideways) or Calendar (flip up), with a mini picture of each.
class _BindingPicker extends StatelessWidget {
  const _BindingPicker({required this.value, required this.onChanged});
  final DuplexBinding value;
  final ValueChanged<DuplexBinding> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(DuplexBinding b, String title, String sub) {
      final on = value == b;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(b),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
            decoration: BoxDecoration(
              color: on ? Brand.tint : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: on ? Brand.blue : const Color(0xFFD5DDEC),
                width: on ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 74,
                  child: Center(child: _BindingDiagram(binding: b)),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      on
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      size: 18,
                      color: on ? Brand.blue : Brand.grey,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: on ? Brand.blue : Brand.navy,
                      ),
                    ),
                  ],
                ),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Brand.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        option(DuplexBinding.book, 'Book', 'Turn pages sideways'),
        const SizedBox(width: 10),
        option(DuplexBinding.calendar, 'Calendar', 'Flip pages up'),
      ],
    );
  }
}

/// Two open pages: side by side (book) or one above the other (calendar).
class _BindingDiagram extends StatelessWidget {
  const _BindingDiagram({required this.binding});
  final DuplexBinding binding;

  @override
  Widget build(BuildContext context) {
    final book = binding == DuplexBinding.book;
    Widget page(String n, {required bool back}) => Container(
      width: book ? 30 : 40,
      height: book ? 40 : 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: back ? const Color(0xFFF4F7FD) : Colors.white,
        border: Border.all(color: Brand.blue, width: 1.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        n,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: Brand.blue,
          fontSize: 13,
        ),
      ),
    );
    final hinge = Container(
      width: book ? 3 : 40,
      height: book ? 40 : 3,
      color: Brand.navy,
    );
    // The back of page 1 (page 2) sits opposite page 1 across the hinge.
    return book
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [page('2', back: true), hinge, page('1', back: false)],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [page('2', back: true), hinge, page('1', back: false)],
          );
  }
}

class _DuplexSteps extends StatelessWidget {
  const _DuplexSteps();

  @override
  Widget build(BuildContext context) {
    Widget step(Widget icon, String label) => Expanded(
      child: Column(
        children: [
          icon,
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Brand.grey),
          ),
        ],
      ),
    );
    Widget sheet(String n) => Container(
      width: 30,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Brand.blue, width: 1.5),
      ),
      child: Text(
        n,
        style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.blue),
      ),
    );
    const arrow = Padding(
      padding: EdgeInsets.only(bottom: 20),
      child: Icon(Icons.arrow_forward_rounded, color: Brand.sky, size: 18),
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          step(sheet('1'), 'Odd pages\nprint'),
          arrow,
          step(
            const SizedBox(
              height: 40,
              child: Icon(Icons.flip_rounded, color: Brand.blue, size: 30),
            ),
            'You flip\nthe stack',
          ),
          arrow,
          step(sheet('2'), 'Even pages\nprint'),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final PrinterStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.health) {
      PrinterHealth.ready => Brand.success,
      PrinterHealth.busy => Brand.blue,
      PrinterHealth.attention => Brand.warning,
      PrinterHealth.offline => Theme.of(context).colorScheme.error,
      _ => Brand.grey,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const CircleAvatar(
          backgroundColor: Brand.tint,
          child: Icon(Icons.print_rounded, color: Brand.blue),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: status.health == PrinterHealth.checking
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.icon, required this.label, this.child});
  final IconData icon;
  final String label;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: Brand.blue, size: 22),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      ?child,
    ],
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, VoidCallback? onTap) => SizedBox.square(
      dimension: 38,
      child: IconButton.filledTonal(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        style: IconButton.styleFrom(
          backgroundColor: Brand.tint,
          foregroundColor: Brand.blue,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
    return Row(
      children: [
        btn(
          Icons.remove_rounded,
          value > 1 ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 44,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        btn(Icons.add_rounded, value < 99 ? () => onChanged(value + 1) : null),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.summary,
    required this.saving,
    required this.enabled,
    required this.onStart,
  });

  final String summary;
  final int saving;
  final bool enabled;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
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
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (saving > 0)
                      Text(
                        'Saves $saving sheet${saving == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Brand.success,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 170,
                child: FilledButton.icon(
                  onPressed: enabled ? onStart : null,
                  icon: const Icon(Icons.print_rounded),
                  label: const Text('Start Printing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
