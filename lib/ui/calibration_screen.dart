import 'package:flutter/material.dart';

import '../data/store.dart';
import '../pdf_service.dart';
import 'printers_tab.dart';
import 'progress_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Prints 4 numbered pages on 2 sheets, then asks what ended up on the back
/// of page 1 — that tells us the order and rotation this printer needs.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

enum _Answer { page2, page2UpsideDown, page4, page4UpsideDown }

class _CalibrationScreenState extends State<CalibrationScreen> {
  final _store = AppStore.instance;
  late SavedPrinter _printer = _store.defaultPrinter;
  bool _printed = false;
  _Answer? _answer;

  Future<void> _printTest() async {
    final pdf = await PdfService.testDocument();
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProgressScreen(
          request: PrintRequest(
            fileName: 'FlipPrint calibration',
            pdf: pdf,
            pages: const [1, 2, 3, 4],
            copies: 1,
            duplex: true,
            printer: _printer,
            paper: _store.settings.paper,
            calibration: true,
          ),
        ),
      ),
    );
    if (ok == true) setState(() => _printed = true);
  }

  void _save() {
    final a = _answer!;
    final flipOrder = a == _Answer.page4 || a == _Answer.page4UpsideDown;
    final flipRotation =
        a == _Answer.page2UpsideDown || a == _Answer.page4UpsideDown;
    _printer
      ..reverseBack = flipOrder ? !_printer.reverseBack : _printer.reverseBack
      ..rotateBack = flipRotation ? !_printer.rotateBack : _printer.rotateBack;
    // A changed setting needs one more check; an unchanged one is confirmed.
    final changed = flipOrder || flipRotation;
    if (!changed) _printer.calibrated = true;
    _store.save();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          changed ? Icons.autorenew_rounded : Icons.check_circle_rounded,
          color: changed ? Brand.blue : Brand.success,
          size: 40,
        ),
        title: Text(changed ? 'Settings adjusted' : 'All set!'),
        content: Text(
          changed
              ? 'FlipPrint changed how it prints the back sides. Print the test '
                    'once more to confirm — you should get page 2 behind page 1.'
              : '${_printer.name} is calibrated. Double-sided prints will come '
                    'out in the right order.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              if (changed) {
                setState(() {
                  _printed = false;
                  _answer = null;
                });
              } else {
                Navigator.pop(this.context);
              }
            },
            child: Text(changed ? 'Print again' : 'Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Calibration')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const InfoBox(
            child: Text(
              'Every printer feeds and stacks paper a little differently. '
              'Print 4 test pages on 2 sheets once, tell us what you see, and '
              'FlipPrint remembers it for this printer.',
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.print_rounded, color: Brand.blue),
              title: Text(
                _printer.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _printer.calibrated ? 'Calibrated' : 'Not calibrated',
              ),
              trailing: const Icon(Icons.expand_more_rounded),
              onTap: () async {
                final p = await showPrinterPicker(context, _printer);
                if (p != null) {
                  setState(() {
                    _printer = p;
                    _printed = false;
                    _answer = null;
                  });
                }
              },
            ),
          ),
          const SectionLabel('Step 1 — print the test'),
          const _Bullet('Load 2 sheets of plain paper.'),
          const _Bullet(
            'When asked, turn the stack over like a book page and load it '
            'back with the same edge first. Do it the same way every time.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _printTest,
            icon: const Icon(Icons.print_rounded),
            label: Text(_printed ? 'Print test again' : 'Print test pages'),
          ),
          if (_printed) ...[
            const SectionLabel('Step 2 — check the result'),
            const Text(
              'Find the sheet with "Page 1" on it and turn it over. '
              'What is on the back?',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            RadioGroup<_Answer>(
              groupValue: _answer,
              onChanged: (v) => setState(() => _answer = v),
              child: const Column(
                children: [
                  _Choice(_Answer.page2, 'Page 2, the right way up', 'Perfect'),
                  _Choice(_Answer.page2UpsideDown, 'Page 2, upside down', null),
                  _Choice(_Answer.page4, 'Page 4, the right way up', null),
                  _Choice(_Answer.page4UpsideDown, 'Page 4, upside down', null),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _answer == null ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6, right: 10),
          child: Icon(Icons.circle, size: 7, color: Brand.blue),
        ),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ],
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice(this.value, this.label, this.badge);
  final _Answer value;
  final String label;
  final String? badge;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: RadioListTile<_Answer>(
      value: value,
      title: Text(label),
      secondary: badge == null
          ? null
          : Text(
              badge!,
              style: const TextStyle(
                color: Brand.success,
                fontWeight: FontWeight.w700,
              ),
            ),
    ),
  );
}
