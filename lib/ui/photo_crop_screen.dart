import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/store.dart';
import '../photo/photo_layout.dart';
import 'photo_layout_screen.dart';
import 'theme.dart';

/// Pixels per inch the cropped photo is rendered at.
const photoDpi = 300;

/// Step 1 of Photo Print: pick a size preset, then pinch, drag and rotate the
/// photo inside a frame of exactly that shape.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  final _store = AppStore.instance;
  ui.Image? _image;
  String? _error;
  PhotoPreset _preset = PhotoPreset.builtIn.first;

  // Crop state: zoom over the smallest scale that still fills the frame, and
  // the crop centre's offset from the image centre in image pixels.
  double _zoom = 1;
  Offset _centre = Offset.zero;
  Size _frame = Size.zero;
  Size _area = Size.zero;

  // Gesture start values.
  double _zoom0 = 1;
  Offset _anchor = Offset.zero;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  /// Decodes the photo, capped at 3000 px on the long side to save memory.
  Future<void> _decode() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      final wide = desc.width >= desc.height;
      final codec = await desc.instantiateCodec(
        targetWidth: wide && desc.width > 3000 ? 3000 : null,
        targetHeight: !wide && desc.height > 3000 ? 3000 : null,
      );
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _error = 'This photo could not be opened.');
    }
  }

  double get _minScale {
    final img = _image!;
    return math.max(_frame.width / img.width, _frame.height / img.height);
  }

  double get _scale => _minScale * _zoom;

  /// Keeps the frame inside the photo.
  Offset _clamped(Offset c, double scale) {
    final img = _image!;
    final mx = math.max(0.0, (img.width - _frame.width / scale) / 2);
    final my = math.max(0.0, (img.height - _frame.height / scale) / 2);
    return Offset(c.dx.clamp(-mx, mx), c.dy.clamp(-my, my));
  }

  void _onScaleStart(ScaleStartDetails d) {
    _zoom0 = _zoom;
    final centre = _area.center(Offset.zero);
    // The photo point under the fingers, which should stay under them.
    _anchor = _centre + (d.localFocalPoint - centre) / _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final centre = _area.center(Offset.zero);
    setState(() {
      _zoom = (_zoom0 * d.scale).clamp(1.0, 8.0);
      _centre = _clamped(
        _anchor - (d.localFocalPoint - centre) / _scale,
        _scale,
      );
    });
  }

  Future<void> _rotate() async {
    final img = _image!;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..translate(img.height.toDouble(), 0)
      ..rotate(math.pi / 2)
      ..drawImage(img, Offset.zero, Paint());
    final picture = recorder.endRecording();
    final rotated = await picture.toImage(img.height, img.width);
    picture.dispose();
    img.dispose();
    setState(() {
      _image = rotated;
      _zoom = 1;
      _centre = Offset.zero;
    });
  }

  /// Renders the framed area at [photoDpi] for the preset's real size.
  Future<Uint8List> _export() async {
    final img = _image!;
    final w = (_preset.widthMm / 25.4 * photoDpi).round();
    final h = (_preset.heightMm / 25.4 * photoDpi).round();
    final src = Rect.fromCenter(
      center: Offset(img.width / 2, img.height / 2) + _centre,
      width: _frame.width / _scale,
      height: _frame.height / _scale,
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      img,
      src,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(w, h);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    out.dispose();
    return png!.buffer.asUint8List();
  }

  Future<void> _next() async {
    setState(() => _exporting = true);
    try {
      final photo = await _export();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PhotoLayoutScreen(photo: photo, preset: _preset),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _addPreset() async {
    final preset = await showDialog<PhotoPreset>(
      context: context,
      builder: (_) => const _PresetDialog(),
    );
    if (preset == null) return;
    await _store.addPhotoPreset(preset);
    setState(() => _preset = preset);
  }

  Future<void> _deletePreset(PhotoPreset preset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${preset.name}"?'),
        content: Text('${preset.sizeLabel} will be removed from your sizes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.removePhotoPreset(preset);
    if (_preset == preset) _preset = PhotoPreset.builtIn.first;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo Print')),
      body: Column(
        children: [
          _presetBar(),
          Expanded(child: _cropArea()),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  Widget _presetBar() {
    final presets = [...PhotoPreset.builtIn, ..._store.photoPresets];
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        children: [
          for (final p in presets)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _PresetChip(
                preset: p,
                selected: p == _preset,
                onTap: () => setState(() => _preset = p),
                onLongPress: p.custom ? () => _deletePreset(p) : null,
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Custom size'),
            onPressed: _addPreset,
          ),
        ],
      ),
    );
  }

  Widget _cropArea() {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Brand.grey)),
      );
    }
    if (_image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, c) {
        _area = c.biggest;
        final aspect = _preset.widthMm / _preset.heightMm;
        final fw = math.min(c.maxWidth - 64, (c.maxHeight - 64) * aspect);
        _frame = Size(fw, fw / aspect);
        // The preset may have changed shape: keep the frame inside the photo.
        _centre = _clamped(_centre, _scale);

        final img = _image!;
        final s = _scale;
        final topLeft =
            _area.center(Offset.zero) -
            Offset(img.width / 2, img.height / 2) * s -
            _centre * s;
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onDoubleTap: () => setState(() {
            _zoom = 1;
            _centre = Offset.zero;
          }),
          child: ColoredBox(
            color: Brand.navy,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: topLeft.dx,
                  top: topLeft.dy,
                  width: img.width * s,
                  height: img.height * s,
                  child: RawImage(
                    image: img,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _FramePainter(
                      frame: Rect.fromCenter(
                        center: _area.center(Offset.zero),
                        width: _frame.width,
                        height: _frame.height,
                      ),
                      faceGuide: _preset.isId,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Text(
                    '${_preset.name} · ${_preset.sizeLabel}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bottomBar() {
    final ready = _image != null && !_exporting;
    return Container(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _preset.isId
                    ? 'Pinch and drag to fit the head inside the oval'
                    : 'Pinch to zoom, drag to move',
                style: const TextStyle(color: Brand.grey, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: ready ? _rotate : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                    icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
                    label: const Text('Rotate'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: ready ? _next : null,
                      icon: _exporting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.grid_view_rounded),
                      label: const Text('Place on paper'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final PhotoPreset preset;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : Brand.navy;
    return Material(
      color: selected ? Brand.blue : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? Brand.blue : const Color(0xFFD5DDEC),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (preset.custom) ...[
                    Icon(Icons.star_rounded, size: 14, color: fg),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    preset.name,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Text(
                preset.sizeLabel,
                style: TextStyle(
                  color: selected ? Colors.white70 : Brand.grey,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dims everything outside the crop frame and draws guides inside it.
class _FramePainter extends CustomPainter {
  _FramePainter({required this.frame, required this.faceGuide});

  final Rect frame;
  final bool faceGuide;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(frame),
      Paint()..color = const Color(0xB30F1B3D),
    );
    final thin = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas
        ..drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thin)
        ..drawLine(Offset(frame.left, y), Offset(frame.right, y), thin);
    }
    if (faceGuide) {
      // Head from crown to chin is about 70-80% of an ID photo's height.
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(frame.center.dx, frame.top + frame.height * 0.45),
          width: frame.width * 0.58,
          height: frame.height * 0.66,
        ),
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.frame != frame || old.faceGuide != faceGuide;
}

class _PresetDialog extends StatefulWidget {
  const _PresetDialog();

  @override
  State<_PresetDialog> createState() => _PresetDialogState();
}

class _PresetDialogState extends State<_PresetDialog> {
  final _name = TextEditingController();
  final _w = TextEditingController();
  final _h = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  double? _mm(TextEditingController c) {
    final v = double.tryParse(c.text.trim().replaceAll(',', '.'));
    return v != null && v >= 10 && v <= 200 ? v : null;
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty && _mm(_w) != null && _mm(_h) != null;

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, [String? suffix]) => InputDecoration(
      labelText: label,
      suffixText: suffix,
      border: const OutlineInputBorder(),
    );
    final number = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return AlertDialog(
      title: const Text('New photo size'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: deco('Name', null),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _w,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: number,
                  decoration: deco('Width', 'mm'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _h,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: number,
                  decoration: deco('Height', 'mm'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Between 10 and 200 mm. 1 cm = 10 mm.',
            style: TextStyle(color: Brand.grey, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
          onPressed: _valid
              ? () => Navigator.pop(
                  context,
                  PhotoPreset(
                    _name.text.trim(),
                    _mm(_w)!,
                    _mm(_h)!,
                    custom: true,
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
