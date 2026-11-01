import 'package:flutter/material.dart';

import '../data/store.dart';
import '../print/discovery.dart';
import 'calibration_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Bottom sheet to choose a printer. Returns the chosen one.
Future<SavedPrinter?> showPrinterPicker(
  BuildContext context,
  SavedPrinter current,
) {
  final store = AppStore.instance;
  return showModalBottomSheet<SavedPrinter>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Choose printer',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          for (final p in store.printers)
            ListTile(
              leading: Icon(
                p.isSystem ? Icons.print_outlined : Icons.wifi_rounded,
                color: Brand.blue,
              ),
              title: Text(p.name),
              subtitle: Text(
                p.isSystem ? 'Android print dialog' : p.host ?? '',
              ),
              trailing: p.id == current.id
                  ? const Icon(Icons.check_rounded, color: Brand.blue)
                  : null,
              onTap: () => Navigator.pop(context, p),
            ),
        ],
      ),
    ),
  );
}

class PrintersTab extends StatefulWidget {
  const PrintersTab({super.key});

  @override
  State<PrintersTab> createState() => _PrintersTabState();
}

class _PrintersTabState extends State<PrintersTab> {
  final _store = AppStore.instance;
  final _discovery = PrinterDiscovery();
  final Set<String> _adding = {};

  @override
  void initState() {
    super.initState();
    _discovery.start();
  }

  @override
  void dispose() {
    _discovery.dispose();
    super.dispose();
  }

  Future<void> _add(
    String name,
    String host,
    int port,
    String path,
    String? service,
  ) async {
    setState(() => _adding.add(host));
    try {
      final model = await probePrinter(host, port: port, path: path);
      _store.upsertNetworkPrinter(
        name: model,
        host: host,
        port: port,
        path: path,
        serviceName: service,
      );
      _snack('$model added');
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _adding.remove(host));
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addByIp() async {
    final ctrl = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add printer by IP'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: '192.168.1.12',
            helperText: 'Find it on the printer\'s network status sheet\nor your router.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ip != null && ip.isNotEmpty) await _add(ip, ip, 631, 'ipp/print', null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_store, _discovery]),
      builder: (context, _) {
        final saved = _store.printers;
        final newFound = _discovery.printers
            .where(
              (f) => !saved.any(
                (s) => s.serviceName == f.serviceName || s.host == f.host,
              ),
            )
            .toList();
        return RefreshIndicator(
          onRefresh: () async {
            await _discovery.stop();
            await _discovery.start();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              const SectionLabel('Your printers'),
              for (final p in saved) ...[
                _PrinterCard(printer: p),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  const Expanded(child: SectionLabel('Found on your Wi-Fi')),
                  if (_discovery.scanning)
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (_discovery.error != null)
                Text(
                  _discovery.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (newFound.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    'No new printers. Make sure the printer is on and connected '
                    'to the same Wi-Fi as this phone.',
                    style: TextStyle(color: Brand.grey),
                  ),
                ),
              for (final f in newFound)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(
                      Icons.wifi_find_rounded,
                      color: Brand.blue,
                    ),
                    title: Text(f.name),
                    subtitle: Text(f.host),
                    trailing: _adding.contains(f.host)
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(64, 36),
                            ),
                            onPressed: () => _add(
                              f.name,
                              f.host,
                              f.port,
                              f.path,
                              f.serviceName,
                            ),
                            child: const Text('Add'),
                          ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _addByIp,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add printer by IP address'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({required this.printer});
  final SavedPrinter printer;

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final isDefault = store.settings.defaultPrinterId == printer.id;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        leading: CircleAvatar(
          backgroundColor: Brand.tint,
          child: Icon(
            printer.isSystem ? Icons.print_outlined : Icons.print_rounded,
            color: Brand.blue,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                printer.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (isDefault) ...[
              const SizedBox(width: 6),
              const Icon(Icons.star_rounded, color: Brand.warning, size: 18),
            ],
          ],
        ),
        subtitle: Text(
          printer.isSystem
              ? 'Any printer via Android print dialog'
              : '${printer.host} • ${printer.calibrated ? 'Calibrated' : 'Not calibrated'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          SwitchListTile(
            title: const Text('Print back sides in reverse order'),
            value: printer.reverseBack,
            onChanged: (v) {
              printer.reverseBack = v;
              store.save();
            },
          ),
          SwitchListTile(
            title: const Text('Rotate back sides 180°'),
            value: printer.rotateBack,
            onChanged: (v) {
              printer.rotateBack = v;
              store.save();
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              if (!isDefault)
                TextButton.icon(
                  icon: const Icon(Icons.star_outline_rounded),
                  label: const Text('Make default'),
                  onPressed: () {
                    store.settings.defaultPrinterId = printer.id;
                    store.save();
                  },
                ),
              TextButton.icon(
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Calibrate'),
                onPressed: () {
                  store.settings.defaultPrinterId = printer.id;
                  store.save();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CalibrationScreen(),
                    ),
                  );
                },
              ),
              if (!printer.isSystem)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => store.removePrinter(printer),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
