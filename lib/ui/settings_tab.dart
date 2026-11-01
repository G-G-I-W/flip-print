import 'package:flutter/material.dart';

import '../data/store.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final s = store.settings;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          const SectionLabel('Print'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Quality'),
                  trailing: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Normal')),
                      ButtonSegment(value: true, label: Text('High')),
                    ],
                    selected: {s.highQuality},
                    onSelectionChanged: (v) {
                      s.highQuality = v.first;
                      store.save();
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Colour'),
                  trailing: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: true, label: Text('Colour')),
                      ButtonSegment(value: false, label: Text('B&W')),
                    ],
                    selected: {s.color},
                    onSelectionChanged: (v) {
                      s.color = v.first;
                      store.save();
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Default paper size'),
                  trailing: DropdownButton<Paper>(
                    value: s.paper,
                    underline: const SizedBox(),
                    items: [
                      for (final p in Paper.values)
                        DropdownMenuItem(value: p, child: Text(p.label)),
                    ],
                    onChanged: (p) {
                      s.paper = p!;
                      store.save();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('Duplex'),
          Card(
            child: SwitchListTile(
              title: const Text('Mark blank pages'),
              subtitle: const Text(
                'Adds a tiny dot to blank backs so the printer doesn\'t skip '
                'them and mix up the order.',
              ),
              value: s.markBlanks,
              onChanged: (v) {
                s.markBlanks = v;
                store.save();
              },
            ),
          ),
          const SectionLabel('About'),
          const Card(
            child: ListTile(
              leading: FlipLogo(size: 30, color: Brand.blue),
              title: Wordmark(size: 18),
              subtitle: Text(
                'Manual double-sided printing for printers without duplex. '
                'Prints directly to IPP printers like the Epson L3250 over Wi-Fi.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
