import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/store.dart';
import '../duplex_plan.dart';
import '../print/background.dart';
import '../print/print_engine.dart';
import 'theme.dart';
import 'widgets.dart';

class PrintRequest {
  const PrintRequest({
    required this.fileName,
    required this.pdf,
    required this.pages,
    required this.copies,
    required this.duplex,
    required this.printer,
    required this.paper,
    this.orientation = PageOrientation.auto,
    this.calibration = false,
    this.binding = DuplexBinding.book,
    this.kind = HistoryKind.print,
    this.docPath,
    this.highQuality,
  });

  final String fileName;
  final Uint8List pdf;
  final List<int> pages;
  final int copies;
  final bool duplex;
  final SavedPrinter printer;
  final Paper paper;
  final PageOrientation orientation;

  /// A calibration run: no history entry, and the caller asks the questions.
  final bool calibration;
  final DuplexBinding binding;
  final HistoryKind kind;
  final String? docPath;

  /// Overrides the quality setting, e.g. always high for photos.
  final bool? highQuality;
}

enum _Stage { front, flip, back, done }

/// Runs the front pass, waits for the user to flip the paper, then the back
/// pass. Pops with `true` when everything printed.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key, required this.request});
  final PrintRequest request;

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  late final PrintRequest r = widget.request;
  late final DuplexPlan _plan = DuplexPlan.build(
    pages: r.pages,
    copies: r.copies,
    profile: r.printer.profile,
  );
  late final List<int?> _single = [
    for (var c = 0; c < r.copies; c++) ...r.pages,
  ];

  _Stage _stage = _Stage.front;
  PassRunner? _runner;
  bool _recorded = false;
  bool _flipAlerted = false;

  int get _sheets => r.duplex ? _plan.sheetCount : _single.length;
  int get _totalPages => r.pages.length * r.copies;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {});
    _startPass(back: false);
  }

  @override
  void dispose() {
    _runner?.removeListener(_onRunner);
    BackgroundPrint.stop();
    BackgroundPrint.clearAlert();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  void _startPass({required bool back}) {
    final s = AppStore.instance.settings;
    final base = r.fileName.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    _runner?.removeListener(_onRunner);
    _recorded = false;
    final runner = _runner = PassRunner(
      PassSpec(
        pdf: r.pdf,
        jobName: r.duplex ? '$base (${back ? 'even' : 'odd'})' : base,
        sequence: !r.duplex
            ? _single
            : back
            ? _plan.back
            : _plan.front,
        printer: r.printer,
        paper: r.paper,
        orientation: r.orientation,
        backSide: back,
        printerRotatesBack: r.printer.rotateBack,
        binding: r.binding,
        color: s.color,
        highQuality: r.highQuality ?? s.highQuality,
        markBlanks: s.markBlanks,
      ),
    )..addListener(_onRunner);
    if (back) BackgroundPrint.clearAlert();
    if (!back) _flipAlerted = false;
    setState(() => _stage = back ? _Stage.back : _Stage.front);
    runner.run();
  }

  void _onRunner() {
    final runner = _runner!;
    if (runner.done) {
      if (_stage == _Stage.front && r.duplex && _plan.hasBack) {
        _stage = _Stage.flip;
        _alert();
      } else if (_stage != _Stage.flip && _stage != _Stage.done) {
        _stage = _Stage.done;
        _record('completed');
        _alert();
      }
    } else if (runner.cancelled) {
      _record('cancelled');
    } else if (runner.error != null) {
      _record('failed');
    }
    _notify();
    if (mounted) setState(() {});
  }

  /// Mirrors the progress in a notification so printing carries on (and
  /// can be followed) while the user is in another app.
  void _notify() {
    final runner = _runner!;
    final title = r.calibration ? 'Calibration print' : r.fileName;
    if (_stage == _Stage.flip) {
      BackgroundPrint.update(
        'Flip the paper',
        'Turn the stack over, load it again and tap Continue.',
      );
      if (BackgroundPrint.inBackground && !_flipAlerted) {
        _flipAlerted = true;
        BackgroundPrint.alert(
          'Time to flip the paper',
          'Odd pages are done. Open FlipPrint to print the backs.',
        );
      }
    } else if (_stage == _Stage.done) {
      BackgroundPrint.stop(
        title: 'Printing finished',
        text: '$title · $_sheets ${_sheets == 1 ? 'sheet' : 'sheets'}',
      );
    } else if (runner.error != null) {
      BackgroundPrint.stop(title: 'Printing stopped', text: '${runner.error}');
    } else if (runner.cancelled) {
      BackgroundPrint.stop();
    } else {
      final pass = !r.duplex
          ? 'Printing'
          : _stage == _Stage.back
          ? 'Printing even pages'
          : 'Printing odd pages';
      BackgroundPrint.update(
        '$pass · $title',
        runner.status,
        progress: runner.completed,
        max: runner.total,
      );
    }
  }

  /// Buzz so the user notices even if the phone is on the table.
  Future<void> _alert() async {
    SystemSound.play(SystemSoundType.alert);
    for (var i = 0; i < 3; i++) {
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
  }

  void _record(String status) {
    if (_recorded || r.calibration) return;
    _recorded = true;
    AppStore.instance.addHistory(
      HistoryEntry(
        kind: r.kind,
        docPath: r.docPath,
        fileName: r.fileName,
        pages: r.pages.length,
        copies: r.copies,
        sheets: _sheets,
        printerName: r.printer.name,
        duplex: r.duplex,
        status: status,
      ),
    );
  }

  bool get _active {
    final runner = _runner;
    return _stage != _Stage.done &&
        runner != null &&
        !runner.cancelled &&
        runner.error == null;
  }

  Future<bool> _confirmStop() async {
    if (!_active) return true;
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.stop_circle_outlined, size: 36),
        title: const Text('Stop printing?'),
        content: Text(
          _stage == _Stage.flip
              ? 'The odd pages are already printed. You can start again later.'
              : 'The pages already sent will finish, then the job stops.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (stop == true && !_runner!.finished) await _runner!.cancel();
    if (stop == true && _stage == _Stage.flip) _record('cancelled');
    return stop == true;
  }

  @override
  Widget build(BuildContext context) {
    final runner = _runner!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Leaving mid-print just hides the app; the print keeps going and
        // the notification brings the user back. Cancel stops it.
        if (_active) {
          SystemNavigator.pop();
          return;
        }
        if (await _confirmStop() && context.mounted) {
          Navigator.of(context).pop(_stage == _Stage.done);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            r.calibration ? 'Calibration Print' : 'Printing Progress',
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              if (r.duplex) ...[
                _StepTracker(stage: _stage),
                const SizedBox(height: 14),
              ],
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: KeyedSubtree(
                      key: ValueKey(
                        '$_stage${runner.error}${runner.cancelled}',
                      ),
                      child: switch (_stage) {
                        _Stage.done => _doneView(),
                        _Stage.flip => _flipView(),
                        _ => _printingView(runner),
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _printingView(PassRunner runner) {
    final failed = runner.error != null;
    if (failed || runner.cancelled) return _stoppedView(runner);
    final title = switch (_stage) {
      _Stage.back => 'Printing Even Pages...',
      _ => r.duplex ? 'Printing Odd Pages...' : 'Printing Pages...',
    };
    final pct = (runner.fraction * 100).round();
    return Column(
      children: [
        ProgressRing(value: runner.fraction),
        const SizedBox(height: 22),
        Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          _stage == _Stage.back
              ? 'Back sides of your sheets'
              : r.duplex
              ? 'Front sides of your sheets'
              : 'Please wait while we print your document',
          style: const TextStyle(color: Brand.grey),
        ),
        const SizedBox(height: 16),
        Text(
          '$pct%',
          style: const TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.w800,
            color: Brand.blue,
          ),
        ),
        Text(
          '(${runner.completed} of ${runner.total} pages)',
          style: const TextStyle(color: Brand.grey),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: runner.fraction,
            minHeight: 8,
            backgroundColor: Brand.tint,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          runner.status,
          style: const TextStyle(color: Brand.grey, fontSize: 13),
        ),
        if (runner.warning != null) ...[
          const SizedBox(height: 14),
          InfoBox(
            icon: Icons.warning_amber_rounded,
            color: Brand.warning,
            background: const Color(0xFFFFF6E0),
            child: Text(
              runner.warning!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
        if (_stage == _Stage.front && r.duplex) ...[
          const SizedBox(height: 16),
          const InfoBox(
            icon: Icons.notifications_active_outlined,
            child: Text(
              'Your phone will buzz when it\'s time to flip the paper.',
            ),
          ),
        ],
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: () async {
            if (await _confirmStop() && mounted) setState(() {});
          },
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _flipView() {
    final oddCopy = r.pages.length.isOdd;
    Widget step(int n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Brand.blue,
            child: Text(
              '$n',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
        ],
      ),
    );
    return Column(
      children: [
        const _FlipAnimation(),
        const SizedBox(height: 18),
        const Text(
          'Time to flip!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'Odd pages are done on ${_plan.sheetCount} '
          'sheet${_plan.sheetCount == 1 ? '' : 's'}.',
          style: const TextStyle(color: Brand.grey),
        ),
        const SizedBox(height: 20),
        step(1, 'Take all sheets from the output tray. Keep the order.'),
        step(2, 'Turn the stack over like a book page, as shown above.'),
        step(
          3,
          'Load it into the rear paper feeder with the same edge going in '
          'first, then tap Continue.',
        ),
        if (r.binding == DuplexBinding.calendar)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: InfoBox(
              icon: Icons.calendar_view_day_rounded,
              child: Text(
                'Calendar mode: still flip the stack like a book page. '
                'FlipPrint turns the back pages for you.',
              ),
            ),
          ),
        if (oddCopy)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: InfoBox(
              child: Text(
                'Odd page count: the last sheet of each copy gets a blank '
                'back. Leave it in the stack.',
              ),
            ),
          ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => _startPass(back: true),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Continue — print even pages'),
        ),
        TextButton(
          onPressed: () async {
            if (await _confirmStop() && mounted) {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text('Stop here'),
        ),
      ],
    );
  }

  Widget _stoppedView(PassRunner runner) {
    final failed = runner.error != null;
    final err = runner.error ?? '';
    final unreachable =
        err.contains('Cannot reach') || err.contains('did not answer');
    return Column(
      children: [
        ProgressRing(
          value: runner.fraction,
          color: failed ? Theme.of(context).colorScheme.error : Brand.grey,
          icon: failed ? Icons.print_disabled_rounded : Icons.close_rounded,
        ),
        const SizedBox(height: 22),
        Text(
          failed ? 'Printing Stopped' : 'Printing Cancelled',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        if (failed)
          InfoBox(
            icon: Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
            background: Theme.of(context).colorScheme.errorContainer,
            child: Text(
              unreachable
                  ? 'Can\'t reach ${r.printer.name}. Check that it\'s switched '
                        'on and connected to the same Wi-Fi as this phone.'
                  : err,
            ),
          )
        else
          const Text(
            'Nothing more will be printed.',
            style: TextStyle(color: Brand.grey),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _startPass(back: _stage == _Stage.back),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(_stage == _Stage.back ? 'Retry even pages' : 'Try again'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _doneView() {
    final saved = r.duplex ? _totalPages - _sheets : 0;
    return Column(
      children: [
        const ProgressRing(
          value: 1,
          color: Brand.success,
          icon: Icons.check_rounded,
        ),
        const SizedBox(height: 22),
        Text(
          r.calibration ? 'Test pages printed' : 'All Done!',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          r.calibration
              ? 'Now check the sheets and answer one question.'
              : '$_totalPages page${_totalPages == 1 ? '' : 's'} on $_sheets '
                    'sheet${_sheets == 1 ? '' : 's'}'
                    '${r.copies > 1 ? ' • ${r.copies} copies' : ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Brand.grey),
        ),
        if (saved > 0 && !r.calibration) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Brand.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.eco_rounded, color: Brand.success, size: 18),
                const SizedBox(width: 6),
                Text(
                  'You saved $saved sheet${saved == 1 ? '' : 's'} of paper',
                  style: const TextStyle(
                    color: Brand.success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(r.calibration ? 'Continue' : 'Done'),
        ),
        if (!r.calibration) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _startPass(back: false),
            icon: const Icon(Icons.replay_rounded),
            label: const Text('Print another set'),
          ),
        ],
      ],
    );
  }
}

/// Odd pages → Flip → Even pages, with the current step highlighted.
class _StepTracker extends StatelessWidget {
  const _StepTracker({required this.stage});
  final _Stage stage;

  @override
  Widget build(BuildContext context) {
    final current = switch (stage) {
      _Stage.front => 0,
      _Stage.flip => 1,
      _Stage.back => 2,
      _Stage.done => 3,
    };
    const labels = ['Odd pages', 'Flip paper', 'Even pages'];
    const icons = [
      Icons.looks_one_rounded,
      Icons.flip_rounded,
      Icons.looks_two_rounded,
    ];
    final children = <Widget>[];
    for (var i = 0; i < 3; i++) {
      final done = i < current;
      final active = i == current;
      children.add(
        Expanded(
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? Brand.success
                      : active
                      ? Brand.blue
                      : Colors.white,
                  border: Border.all(
                    color: done
                        ? Brand.success
                        : active
                        ? Brand.blue
                        : const Color(0xFFD5DDEC),
                    width: 2,
                  ),
                ),
                child: Icon(
                  done ? Icons.check_rounded : icons[i],
                  size: 20,
                  color: done || active ? Colors.white : Brand.grey,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Brand.navy : Brand.grey,
                ),
              ),
            ],
          ),
        ),
      );
      if (i < 2) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: SizedBox(
              width: 28,
              child: Divider(
                thickness: 2,
                color: i < current ? Brand.success : const Color(0xFFD5DDEC),
              ),
            ),
          ),
        );
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(children: children),
      ),
    );
  }
}

/// A sheet turning over like a book page: "1" on the front, "2" behind.
class _FlipAnimation extends StatefulWidget {
  const _FlipAnimation();

  @override
  State<_FlipAnimation> createState() => _FlipAnimationState();
}

class _FlipAnimationState extends State<_FlipAnimation>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      height: 160,
      decoration: const BoxDecoration(
        color: Brand.tint,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Hold, flip over 40% of the cycle, hold, then snap back.
          final t = _c.value;
          final p = t < 0.2
              ? 0.0
              : t < 0.6
              ? Curves.easeInOut.transform((t - 0.2) / 0.4)
              : 1.0;
          final angle = p * math.pi;
          final showBack = angle > math.pi / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..rotateY(angle),
            child: Transform(
              alignment: Alignment.center,
              transform: showBack
                  ? (Matrix4.identity()..rotateY(math.pi))
                  : Matrix4.identity(),
              child: _sheet(showBack),
            ),
          );
        },
      ),
    );
  }

  Widget _sheet(bool back) => Container(
    width: 78,
    height: 104,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: back ? Brand.success : Brand.blue, width: 2),
      boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 8)],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          back ? '2' : '1',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: back ? Brand.success : Brand.blue,
          ),
        ),
        Text(
          back ? 'blank side' : 'printed',
          style: const TextStyle(fontSize: 10, color: Brand.grey),
        ),
      ],
    ),
  );
}
