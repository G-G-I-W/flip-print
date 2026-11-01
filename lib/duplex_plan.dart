/// Pure logic for manual duplex printing: which pages go on the front pass
/// and which go on the back pass, for any number of copies.
library;

/// Settings that depend on how the printer feeds and stacks paper.
class PrinterProfile {
  const PrinterProfile({this.reverseBack = true, this.rotateBack = false});

  /// Print the back pass in reverse order. Needed when the printed stack
  /// comes out face-up (most Epson inkjets), so the last sheet ends up on top.
  final bool reverseBack;

  /// Rotate back pages 180° — needed if the backs come out upside down
  /// after you flip the stack.
  final bool rotateBack;

  PrinterProfile copyWith({bool? reverseBack, bool? rotateBack}) =>
      PrinterProfile(
        reverseBack: reverseBack ?? this.reverseBack,
        rotateBack: rotateBack ?? this.rotateBack,
      );
}

/// One sheet of paper: a front page and an optional back page (1-based).
class Sheet {
  const Sheet(this.front, this.back);
  final int front;
  final int? back;
}

class DuplexPlan {
  DuplexPlan._(this.sheets, this.front, this.back);

  /// Builds the plan for [pages] (1-based page numbers, in reading order)
  /// printed [copies] times.
  ///
  /// [front] and [back] are the page sequences to send to the printer in
  /// each pass; `null` means a blank page that keeps sheets aligned (when a
  /// copy has an odd number of pages, its last sheet has no back).
  factory DuplexPlan.build({
    required List<int> pages,
    int copies = 1,
    PrinterProfile profile = const PrinterProfile(),
  }) {
    if (pages.isEmpty) throw ArgumentError('No pages selected');
    if (copies < 1) throw ArgumentError('Copies must be at least 1');

    final sheets = <Sheet>[];
    for (var c = 0; c < copies; c++) {
      for (var i = 0; i < pages.length; i += 2) {
        sheets.add(Sheet(pages[i], i + 1 < pages.length ? pages[i + 1] : null));
      }
    }
    final front = [for (final s in sheets) s.front];
    final back = [for (final s in sheets) s.back];
    return DuplexPlan._(
      sheets,
      front,
      profile.reverseBack ? back.reversed.toList() : back,
    );
  }

  final List<Sheet> sheets;
  final List<int> front;
  final List<int?> back;

  int get sheetCount => sheets.length;

  /// True when the back pass has nothing printed at all (single page docs).
  bool get hasBack => back.any((p) => p != null);
}

/// Parses a page range like "1-3, 5, 8-10" into 1-based page numbers.
/// An empty string selects every page. Throws [FormatException] on bad input.
List<int> parsePageRange(String input, int pageCount) {
  final text = input.trim();
  if (text.isEmpty) return [for (var i = 1; i <= pageCount; i++) i];

  final result = <int>[];
  for (final raw in text.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final bounds = part.split('-').map((s) => s.trim()).toList();
    if (bounds.length > 2) throw FormatException('Bad range "$part"');
    final start = int.tryParse(bounds[0]);
    final end = bounds.length == 2
        ? (bounds[1].isEmpty ? pageCount : int.tryParse(bounds[1]))
        : start;
    if (start == null || end == null) {
      throw FormatException('Bad range "$part"');
    }
    if (start < 1 || end > pageCount || start > end) {
      throw FormatException('"$part" is outside pages 1-$pageCount');
    }
    for (var p = start; p <= end; p++) {
      result.add(p);
    }
  }
  if (result.isEmpty) throw const FormatException('No pages selected');
  return result;
}

/// Turns sorted page numbers back into a compact range like "1-3, 5".
/// Returns an empty string when every page of [pageCount] is selected.
String formatPageRange(Iterable<int> pages, int pageCount) {
  final sorted = pages.toSet().toList()..sort();
  if (sorted.length == pageCount) return '';
  final parts = <String>[];
  for (var i = 0; i < sorted.length; i++) {
    final start = sorted[i];
    while (i + 1 < sorted.length && sorted[i + 1] == sorted[i] + 1) {
      i++;
    }
    parts.add(start == sorted[i] ? '$start' : '$start-${sorted[i]}');
  }
  return parts.join(', ');
}

/// How the finished sheets are meant to be turned when reading.
enum DuplexBinding {
  /// Turn sideways like a book page (long edge for portrait pages).
  book,

  /// Flip upwards like a wall calendar (short edge for portrait pages).
  calendar,
}

/// Whether a back page must be turned 180° on the paper.
///
/// The paper is always flipped the same way (the way the printer was
/// calibrated, book-style), so only the content rotates: calendar binding
/// adds a half turn, and so does landscape content that was rotated 90° to
/// fit portrait paper — its book and calendar edges are swapped.
bool backNeedsHalfTurn({
  required bool printerRotatesBack,
  required DuplexBinding binding,
  required bool contentRotated90,
}) =>
    printerRotatesBack ^
    ((binding == DuplexBinding.calendar) != contentRotated90);
