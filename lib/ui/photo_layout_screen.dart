import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../photo/photo_layout.dart';
import '../print/print_engine.dart';
import 'printers_tab.dart';
import 'progress_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Step 2 of Photo Print: choose how many copies, and drag them to the part
/// of the sheet to print on — handy for reusing a half-used photo sheet.
class PhotoLayoutScreen extends StatefulWidget {
  const PhotoLayoutScreen({
    super.key,
    required this.photo,
    required this.preset,
  });

  /// The cropped photo, rendered at its real size.
  final Uint8List photo;
  final PhotoPreset preset;

  @override
  State<PhotoLayoutScreen> createState() => _PhotoLayoutScreenState();
}

class _PhotoLayoutScreenState extends State<PhotoLayoutScreen> {
  final _store = AppStore.instance;
  late Paper _paper = _store.settings.paper;
  late SavedPrinter _printer = _store.defaultPrinter;
  late int _count = widget.preset.isId ? 4 : 1;
  late int _cols = _count;
  double _x = 0, _y = 0;
  bool _cutLines = true;
  bool _busy = false;

  /// A finger is on the photos: the page must not scroll under it.
  bool _dragging = false;

  PhotoSheetLayout get _layout => PhotoSheetLayout(
    paperW: _paper.widthMm,
    paperH: _paper.heightMm,
    photoW: widget.preset.widthMm,
    photoH: widget.preset.heightMm,
  );

  @override
  void initState() {
    super.initState();
    _fit();
    _setPos(_layout.align(-1, -1, _count, _cols));
  }

  /// Keeps count, columns and position valid after any change.
  void _fit() {
    final l = _layout;
    _count = _count.clamp(1, l.maxCount);
    _cols = l.colsFor(_count, _cols.clamp(l.minColsFor(_count), l.maxCols));
    _setPos(l.clamp(_x, _y, _count, _cols));
  }

  void _setPos((double, double) p) {
    _x = p.$1;
    _y = p.$2;
  }

  void _update(VoidCallback change) => setState(() {
    change();
    _fit();
  });

  Future<Uint8List> _buildPdf() async {
    const mm = PdfPageFormat.mm;
    final p = widget.preset;
    final image = pw.MemoryImage(widget.photo);
    final doc = pw.Document(title: '${p.name} photos');
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(_paper.widthMm * mm, _paper.heightMm * mm),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(
          children: [
            for (final (x, y) in _layout.positions(_x, _y, _count, _cols))
              pw.Positioned(
                left: x * mm,
                top: y * mm,
                child: pw.Container(
                  width: p.widthMm * mm,
                  height: p.heightMm * mm,
                  foregroundDecoration: _cutLines
                      ? pw.BoxDecoration(
                          border: pw.Border.all(
                            color: PdfColors.grey500,
                            width: 0.25,
                          ),
                        )
                      : null,
                  child: pw.Image(image, fit: pw.BoxFit.fill),
                ),
              ),
          ],
        ),
      ),
    );
    return doc.save();
  }

  String get _fileName =>
      '${widget.preset.name.replaceAll(RegExp(r'[^\w]+'), '_')}_photos.pdf';

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      final pdf = await _buildPdf();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProgressScreen(
            request: PrintRequest(
              fileName: _fileName,
              pdf: pdf,
              pages: const [1],
              copies: 1,
              duplex: false,
              printer: _printer,
              paper: _paper,
              orientation: PageOrientation.portrait,
              highQuality: true,
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final pdf = await _buildPdf();
      final file = File('${(await getTemporaryDirectory()).path}/$_fileName');
      await file.writeAsBytes(pdf);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          subject: _fileName,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _layout;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Place on Paper'),
        actions: [
          IconButton(
            tooltip: 'Share PDF',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _busy ? null : _share,
          ),
        ],
      ),
      body: ListView(
        physics: _dragging ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _sheet(),
          const SizedBox(height: 8),
          Text(
            '${_x.round()} mm from left · ${_y.round()} mm from top',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Brand.grey, fontSize: 13),
          ),
          const SizedBox(height: 4),
          const Text(
            'Drag the photos, or tap where they should go',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.grey, fontSize: 13),
          ),
          const SectionLabel('Photos'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  _row(
                    Icons.photo_library_outlined,
                    'Copies',
                    '${widget.preset.name} · up to ${l.maxCount}',
                    _Stepper(
                      value: _count,
                      min: 1,
                      max: l.maxCount,
                      onChanged: (v) => _update(() => _count = v),
                    ),
                  ),
                  const Divider(height: 20),
                  _row(
                    Icons.view_column_outlined,
                    'Per row',
                    '${l.rowsFor(_count, _cols)} '
                        '${l.rowsFor(_count, _cols) == 1 ? 'row' : 'rows'}',
                    _Stepper(
                      value: _cols,
                      min: l.minColsFor(_count),
                      max: l.colsFor(_count, l.maxCols),
                      onChanged: (v) => _update(() => _cols = v),
                    ),
                  ),
                  const Divider(height: 20),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.content_cut_rounded),
                    title: const Text(
                      'Cut lines',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text('Thin grey border around each photo'),
                    value: _cutLines,
                    onChanged: (v) => setState(() => _cutLines = v),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('Position'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _AlignPad(
                    onAlign: (ax, ay) =>
                        _update(() => _setPos(l.align(ax, ay, _count, _cols))),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text(
                      'Snap to a corner, an edge or the centre. On a used '
                      'photo sheet, place them on the empty part.',
                      style: TextStyle(color: Brand.grey, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('Printer'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.print_rounded, color: Brand.blue),
                  title: Text(
                    _printer.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Best quality · colour'),
                  trailing: const Icon(Icons.expand_more_rounded),
                  onTap: () async {
                    final p = await showPrinterPicker(context, _printer);
                    if (p != null) setState(() => _printer = p);
                  },
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(
                    Icons.description_outlined,
                    color: Brand.blue,
                  ),
                  title: const Text(
                    'Paper size',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: DropdownButton<Paper>(
                    value: _paper,
                    underline: const SizedBox(),
                    borderRadius: BorderRadius.circular(12),
                    items: [
                      for (final p in Paper.values)
                        DropdownMenuItem(value: p, child: Text(p.label)),
                    ],
                    onChanged: (p) => _update(() => _paper = p!),
                  ),
                ),
              ],
            ),
          ),
          if (_printer.isSystem) ...[
            const SizedBox(height: 12),
            const InfoBox(
              icon: Icons.straighten_rounded,
              child: Text(
                'In the print dialog, choose "Actual size" (100%) so the '
                'photos come out at the right size.',
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _busy ? null : _print,
            icon: const Icon(Icons.print_rounded),
            label: Text('Print $_count ${_count == 1 ? 'photo' : 'photos'}'),
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String hint, Widget child) => Row(
    children: [
      Icon(icon, color: Brand.blue),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(hint, style: const TextStyle(color: Brand.grey, fontSize: 12)),
          ],
        ),
      ),
      child,
    ],
  );

  /// The sheet preview: drag the block of photos, or tap to move it there.
  Widget _sheet() {
    final l = _layout;
    return LayoutBuilder(
      builder: (context, c) {
        final maxH = MediaQuery.sizeOf(context).height * 0.5;
        final k = (c.maxWidth * 0.82 / _paper.widthMm).clamp(
          0.0,
          maxH / _paper.heightMm,
        ); // screen px per mm
        final p = widget.preset;
        final bw = l.blockW(_count, _cols), bh = l.blockH(_count, _cols);
        return Center(
          child: GestureDetector(
            onTapUp: (d) {
              final block = Rect.fromLTWH(_x * k, _y * k, bw * k, bh * k);
              if (block.contains(d.localPosition)) return;
              _update(() {
                _x = d.localPosition.dx / k - bw / 2;
                _y = d.localPosition.dy / k - bh / 2;
              });
            },
            child: Container(
              width: _paper.widthMm * k,
              height: _paper.heightMm * k,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x26000000),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Printable area.
                  Positioned(
                    left: l.margin * k,
                    top: l.margin * k,
                    right: l.margin * k,
                    bottom: l.margin * k,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFE3E8F2)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _x * k,
                    top: _y * k,
                    width: bw * k,
                    height: bh * k,
                    child: Listener(
                      onPointerDown: (_) => setState(() => _dragging = true),
                      onPointerUp: (_) => setState(() => _dragging = false),
                      onPointerCancel: (_) => setState(() => _dragging = false),
                      onPointerMove: (d) => _update(() {
                        _x += d.delta.dx / k;
                        _y += d.delta.dy / k;
                      }),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final (x, y) in l.positions(0, 0, _count, _cols))
                            Positioned(
                              left: x * k,
                              top: y * k,
                              width: p.widthMm * k,
                              height: p.heightMm * k,
                              child: DecoratedBox(
                                position: DecorationPosition.foreground,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: _cutLines
                                        ? Colors.black26
                                        : Colors.transparent,
                                    width: 0.5,
                                  ),
                                ),
                                child: Image.memory(
                                  widget.photo,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  cacheWidth: 200,
                                ),
                              ),
                            ),
                          Positioned(
                            left: -3,
                            top: -3,
                            right: -3,
                            bottom: -3,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Brand.blue,
                                    width: 1.5,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, int? to) => IconButton.filledTonal(
      onPressed: to == null ? null : () => onChanged(to),
      icon: Icon(icon, size: 20),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.remove_rounded, value > min ? value - 1 : null),
        SizedBox(
          width: 36,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
        button(Icons.add_rounded, value < max ? value + 1 : null),
      ],
    );
  }
}

/// A 3 × 3 pad of dots that snaps the photos to corners, edges or centre.
class _AlignPad extends StatelessWidget {
  const _AlignPad({required this.onAlign});

  final void Function(int ax, int ay) onAlign;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 108,
      height: 132,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD5DDEC)),
      ),
      child: Column(
        children: [
          for (final ay in const [-1, 0, 1])
            Expanded(
              child: Row(
                children: [
                  for (final ax in const [-1, 0, 1])
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => onAlign(ax, ay),
                        child: Center(
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: Brand.blue.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
