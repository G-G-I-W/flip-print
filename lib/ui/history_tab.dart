import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../pdf_service.dart';
import 'print_setup_screen.dart';
import 'theme.dart';

/// Every print, scan and copy, newest first, with filters.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  HistoryKind? _filter; // null = all

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final all = store.history;
        final shown = _filter == null
            ? all
            : all.where((h) => h.kind == _filter).toList();
        final saved = all
            .where((h) => h.status == 'completed' && h.duplex)
            .fold<int>(0, (s, h) => s + h.pages * h.copies - h.sheets);

        final children = <Widget>[
          _filters(all),
          if (saved > 0 && _filter != HistoryKind.scan) ...[
            const SizedBox(height: 12),
            _SavingsBanner(sheets: saved),
          ],
        ];
        if (shown.isEmpty) {
          children.add(_empty());
        } else {
          String? lastDay;
          for (final h in shown) {
            final day = _dayLabel(h.date);
            if (day != lastDay) {
              lastDay = day;
              children.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                  child: Text(
                    day,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Brand.grey,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              );
            }
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _EntryCard(entry: h, onTap: () => _showActions(h)),
              ),
            );
          }
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: _confirmClear,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear history'),
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: children,
        );
      },
    );
  }

  Widget _filters(List<HistoryEntry> all) {
    Widget chip(HistoryKind? kind, String label) {
      final count = kind == null
          ? all.length
          : all.where((h) => h.kind == kind).length;
      final selected = _filter == kind;
      return Expanded(
        child: ChoiceChip(
          visualDensity: VisualDensity.compact,
          labelPadding: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(vertical: 6),
          label: SizedBox(
            width: double.infinity,
            child: Text('$label $count', textAlign: TextAlign.center),
          ),
          selected: selected,
          showCheckmark: false,
          selectedColor: Brand.blue,
          backgroundColor: Colors.white,
          side: BorderSide(
            color: selected ? Brand.blue : const Color(0xFFD5DDEC),
          ),
          labelStyle: TextStyle(
            color: selected ? Colors.white : Brand.navy,
            fontWeight: FontWeight.w600,
          ),
          onSelected: (_) => setState(() => _filter = kind),
        ),
      );
    }

    const gap = SizedBox(width: 6);
    return Row(
      children: [
        chip(null, 'All'),
        gap,
        chip(HistoryKind.print, 'Prints'),
        gap,
        chip(HistoryKind.scan, 'Scans'),
        gap,
        chip(HistoryKind.copy, 'Copies'),
      ],
    );
  }

  Widget _empty() {
    final what = switch (_filter) {
      HistoryKind.print => 'prints',
      HistoryKind.scan => 'scans',
      HistoryKind.copy => 'copies',
      null => 'activity',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              color: Brand.tint,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _filter?.icon ?? Icons.history_rounded,
              size: 44,
              color: Brand.blue,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'No $what yet',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Things you print, scan or copy show up here.',
            style: TextStyle(color: Brand.grey),
          ),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'TODAY';
    if (diff == 1) return 'YESTERDAY';
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'Saved copies of these documents will be deleted from FlipPrint.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) AppStore.instance.clearHistory();
  }

  void _showActions(HistoryEntry h) {
    final hasDoc = h.hasDoc;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: _KindIcon(kind: h.kind),
              title: Text(
                h.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(_details(h)),
            ),
            const Divider(),
            if (hasDoc) ...[
              ListTile(
                leading: const Icon(Icons.print_rounded, color: Brand.blue),
                title: Text(
                  h.kind == HistoryKind.scan
                      ? 'Print this scan'
                      : 'Print again',
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  _reprint(h);
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share_rounded, color: Brand.blue),
                title: const Text('Share PDF'),
                onTap: () {
                  Navigator.pop(sheet);
                  SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(h.docPath!, mimeType: 'application/pdf')],
                      fileNameOverrides: [h.fileName],
                      subject: h.fileName,
                    ),
                  );
                },
              ),
            ] else
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('The document is no longer saved on this phone'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Remove from history'),
              onTap: () {
                Navigator.pop(sheet);
                AppStore.instance.removeHistory(h);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reprint(HistoryEntry h) async {
    try {
      final bytes = await File(h.docPath!).readAsBytes();
      final pages = await PdfService(bytes).pageCount();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PrintSetupScreen(
            fileName: h.fileName,
            bytes: bytes,
            pageCount: pages,
            kind: h.kind == HistoryKind.print
                ? HistoryKind.print
                : HistoryKind.copy,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open that document')),
        );
      }
    }
  }
}

String _details(HistoryEntry h) {
  String plural(int n, String w) => '$n $w${n == 1 ? '' : 's'}';
  if (h.kind == HistoryKind.scan) {
    return '${plural(h.pages, 'page')} scanned • ${h.printerName}';
  }
  final copies = h.copies > 1 ? ' × ${h.copies} copies' : '';
  return '${plural(h.pages, 'page')}$copies • ${plural(h.sheets, 'sheet')}'
      '${h.duplex ? ' • double-sided' : ''}';
}

extension on HistoryKind {
  IconData get icon => switch (this) {
    HistoryKind.print => Icons.print_rounded,
    HistoryKind.scan => Icons.document_scanner_rounded,
    HistoryKind.copy => Icons.copy_rounded,
  };

  Color get color => switch (this) {
    HistoryKind.print => Brand.blue,
    HistoryKind.scan => const Color(0xFF7B5CF0),
    HistoryKind.copy => const Color(0xFFF08A24),
  };
}

class _KindIcon extends StatelessWidget {
  const _KindIcon({required this.kind});
  final HistoryKind kind;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: kind.color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(kind.icon, color: kind.color),
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, required this.onTap});
  final HistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = entry;
    final time =
        '${h.date.hour.toString().padLeft(2, '0')}:'
        '${h.date.minute.toString().padLeft(2, '0')}';
    final (statusText, statusColor) = switch (h.status) {
      'cancelled' => ('Cancelled', Brand.grey),
      'failed' => ('Failed', Theme.of(context).colorScheme.error),
      _ => (null, null),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(
            children: [
              _KindIcon(kind: h.kind),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            h.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (statusText != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: statusColor!.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: statusColor,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _details(h),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Brand.grey, fontSize: 13),
                    ),
                    Text(
                      '${h.kind.label} • $time',
                      style: TextStyle(
                        color: h.kind.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.more_vert_rounded, color: Brand.grey),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavingsBanner extends StatelessWidget {
  const _SavingsBanner({required this.sheets});
  final int sheets;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: Brand.gradient,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        const Icon(Icons.eco_rounded, color: Colors.white, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'You\'ve saved $sheets sheet${sheets == 1 ? '' : 's'} of paper '
            'with double-sided printing',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}
