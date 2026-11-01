import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/store.dart';
import '../ipp/ipp.dart';
import '../duplex_plan.dart';
import '../ipp/pwg_raster.dart';
import 'discovery.dart';
import '../pdf_service.dart';

enum PageOrientation { auto, portrait, landscape }

/// Everything needed to print one pass (front sides or back sides).
class PassSpec {
  const PassSpec({
    required this.pdf,
    required this.jobName,
    required this.sequence,
    required this.printer,
    required this.paper,
    this.orientation = PageOrientation.auto,
    this.backSide = false,
    this.printerRotatesBack = false,
    this.binding = DuplexBinding.book,
    this.color = true,
    this.highQuality = false,
    this.markBlanks = true,
  });

  final Uint8List pdf;
  final String jobName;

  /// 1-based page numbers; `null` is a blank page.
  final List<int?> sequence;
  final SavedPrinter printer;
  final Paper paper;
  final PageOrientation orientation;

  /// True for the second pass (the back sides).
  final bool backSide;

  /// Calibration: this printer needs back pages turned 180°.
  final bool printerRotatesBack;
  final DuplexBinding binding;
  final bool color;
  final bool highQuality;
  final bool markBlanks;
}

/// Runs one pass and reports progress. IPP printers get pages streamed
/// directly with live status; "system" printers go through the OS dialog.
class PassRunner extends ChangeNotifier {
  PassRunner(this.spec);

  static const _dpi = 360; // the only PWG resolution the L3250 accepts
  static const _cacheBudget = 150 * 1024 * 1024;

  final PassSpec spec;

  int sent = 0;
  int printed = 0;
  bool _printerCounts = false;
  String status = 'Starting…';
  String? warning;
  bool done = false;
  bool cancelled = false;
  String? error;

  int? _jobId;
  IppClient? _client;
  final _cache = <int, Uint8List>{};
  var _cacheBytes = 0;

  int get total => spec.sequence.length;

  /// Pages finished — counted by the printer when it reports it,
  /// otherwise pages delivered to it.
  int get completed => done ? total : (_printerCounts ? printed : sent);
  double get fraction => total == 0 ? 0 : completed / total;
  bool get finished => done || cancelled || error != null;

  void _set(VoidCallback fn) {
    fn();
    notifyListeners();
  }

  Future<void> run() async {
    try {
      if (spec.printer.isSystem) {
        await _runSystem();
      } else {
        await _runIpp();
      }
    } catch (e) {
      if (!cancelled) _set(() => error = e.toString());
    }
  }

  Future<void> cancel() async {
    _set(() {
      cancelled = true;
      status = 'Cancelled';
    });
    final id = _jobId;
    if (id != null) {
      try {
        await _client?.cancelJob(id);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------ system path

  Future<void> _runSystem() async {
    _set(() => status = 'Preparing pages…');
    final bytes = await PdfService(spec.pdf).buildPass(
      spec.sequence,
      dpi: 200,
      // The OS dialog prints pages as they are; treat them as portrait.
      rotate:
          spec.backSide &&
          backNeedsHalfTurn(
            printerRotatesBack: spec.printerRotatesBack,
            binding: spec.binding,
            contentRotated90: false,
          ),
      markBlanks: spec.markBlanks,
      onProgress: (d, t) => _set(() => status = 'Preparing pages… $d/$t'),
    );
    _set(() => status = 'Choose the printer in the dialog');
    final ok = await Printing.layoutPdf(
      name: spec.jobName,
      onLayout: (_) async => bytes,
      usePrinterSettings: true,
    );
    _set(() {
      if (ok) {
        done = true;
        sent = total;
        status = 'Sent to printer';
      } else {
        cancelled = true;
        status = 'Cancelled';
      }
    });
  }

  // --------------------------------------------------------------- IPP path

  Future<void> _runIpp() async {
    final p = spec.printer;
    final client = _client = IppClient(
      host: p.host!,
      port: p.port,
      path: p.path,
    );
    _set(() => status = 'Connecting to ${p.name}…');
    _jobId = await client.createJob(
      jobName: spec.jobName,
      media: spec.paper.media,
      color: spec.color,
      highQuality: spec.highQuality,
    );

    var polling = true;
    final poller = () async {
      while (polling && !cancelled) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (polling) await _poll();
      }
    }();

    _set(() => status = 'Printing…');
    try {
      await client.sendDocument(_jobId!, _document());
    } finally {
      if (cancelled) polling = false;
    }
    if (cancelled) return;

    _set(() => status = 'Finishing…');
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (!finished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    polling = false;
    await poller;
    if (!finished) {
      _set(() {
        done = true;
        status = 'Sent to printer';
      });
    }
  }

  Stream<List<int>> _document() async* {
    yield pwgSyncWord;
    for (var i = 0; i < total; i++) {
      if (cancelled) return;
      yield await _encode(spec.sequence[i]);
      _set(() => sent = i + 1);
    }
  }

  PwgPage get _pageInfo => PwgPage(
    width: spec.paper.pixelsWide(_dpi),
    height: spec.paper.pixelsHigh(_dpi),
    dpi: _dpi,
    pageSizePoints: spec.paper.points,
    mediaName: spec.paper.media,
    color: spec.color,
    highQuality: spec.highQuality,
  );

  Future<Uint8List> _encode(int? page) async {
    final info = _pageInfo;
    final key = page ?? 0;
    final cached = _cache[key];
    if (cached != null) return cached;

    final Uint8List bytes;
    if (page == null) {
      final mark = spec.markBlanks;
      bytes = await Isolate.run(() => encodeBlankPwgPage(info, mark: mark));
    } else {
      final rgba = await _render(page, info);
      bytes = await Isolate.run(() => encodePwgPage(info, rgba));
    }
    if (_cacheBytes + bytes.length <= _cacheBudget &&
        spec.sequence.where((p) => p == page).length > 1) {
      _cache[key] = bytes;
      _cacheBytes += bytes.length;
    }
    return bytes;
  }

  /// Renders a PDF page onto a paper-sized white canvas, fitted and rotated.
  Future<Uint8List> _render(int page, PwgPage info) async {
    final raster = await Printing.raster(
      spec.pdf,
      pages: [page - 1],
      dpi: _dpi.toDouble(),
    ).first;
    final img = await raster.toImage();

    final w = info.width.toDouble(), h = info.height.toDouble();
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final rotate90 = switch (spec.orientation) {
      PageOrientation.auto => iw > ih,
      PageOrientation.portrait => false,
      PageOrientation.landscape => true,
    };

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white)
      ..translate(w / 2, h / 2);
    final halfTurn =
        spec.backSide &&
        backNeedsHalfTurn(
          printerRotatesBack: spec.printerRotatesBack,
          binding: spec.binding,
          contentRotated90: rotate90,
        );
    if (halfTurn) canvas.rotate(math.pi);
    if (rotate90) canvas.rotate(-math.pi / 2);
    final boxW = rotate90 ? h : w, boxH = rotate90 ? w : h;
    final scale = math.min(boxW / iw, boxH / ih);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromCenter(
        center: Offset.zero,
        width: iw * scale,
        height: ih * scale,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(info.width, info.height);
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    out.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> _poll() async {
    final id = _jobId;
    final client = _client;
    if (id == null || client == null || finished) return;
    try {
      final job = await client.getJobAttributes(id);
      final state = job['job-state']?.firstOrNull;
      final impressions = job['job-impressions-completed']?.firstOrNull;
      String? attention;
      if (state == jobStateProcessing || state == 6 /* stopped */ ) {
        final reasons = (await client.getPrinterAttributes([
          'printer-state-reasons',
        ]))['printer-state-reasons'];
        attention = describePrinterReasons(reasons?.cast<String>() ?? const []);
      }
      _set(() {
        warning = attention;
        if (impressions is int && impressions > 0) {
          _printerCounts = true;
          printed = math.min(impressions, total);
        }
        if (state == jobStateCompleted) {
          done = true;
          status = 'Completed';
        } else if (state == jobStateCanceled) {
          cancelled = true;
          status = 'Cancelled on the printer';
        } else if (state == jobStateAborted) {
          error =
              'The printer stopped the job${attention != null ? ': $attention' : ''}';
        }
      });
    } catch (_) {
      // Polling is best effort; the main upload reports real failures.
    }
  }
}
