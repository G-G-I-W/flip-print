import 'package:duplex_printer/duplex_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const forward = PrinterProfile(reverseBack: false);
  const reversed = PrinterProfile(reverseBack: true);

  group('DuplexPlan', () {
    test('even page count, one copy', () {
      final plan = DuplexPlan.build(pages: [1, 2, 3, 4], profile: forward);
      expect(plan.front, [1, 3]);
      expect(plan.back, [2, 4]);
      expect(plan.sheetCount, 2);
    });

    test('odd page count adds a blank back', () {
      final plan = DuplexPlan.build(pages: [1, 2, 3, 4, 5], profile: forward);
      expect(plan.front, [1, 3, 5]);
      expect(plan.back, [2, 4, null]);
    });

    test('reversed back pass', () {
      final plan = DuplexPlan.build(pages: [1, 2, 3, 4, 5], profile: reversed);
      expect(plan.back, [null, 4, 2]);
    });

    test('multiple copies keep each copy on its own sheets', () {
      final plan = DuplexPlan.build(
        pages: [1, 2, 3],
        copies: 2,
        profile: forward,
      );
      expect(plan.front, [1, 3, 1, 3]);
      expect(plan.back, [2, null, 2, null]);
      expect(plan.sheetCount, 4);
    });

    test('multiple copies reversed', () {
      final plan = DuplexPlan.build(
        pages: [1, 2, 3],
        copies: 2,
        profile: reversed,
      );
      expect(plan.back, [null, 2, null, 2]);
    });

    test('single page has no back', () {
      expect(DuplexPlan.build(pages: [1]).hasBack, isFalse);
    });
  });

  group('parsePageRange', () {
    test('empty means all pages', () {
      expect(parsePageRange('', 3), [1, 2, 3]);
    });

    test('mixed ranges', () {
      expect(parsePageRange('1-3, 5, 7-', 8), [1, 2, 3, 5, 7, 8]);
    });

    test('out of range throws', () {
      expect(() => parsePageRange('2-9', 5), throwsFormatException);
      expect(() => parsePageRange('abc', 5), throwsFormatException);
    });
  });

  group('formatPageRange', () {
    test('compacts runs and round-trips', () {
      expect(formatPageRange([1, 2, 3, 5, 7, 8], 10), '1-3, 5, 7-8');
      expect(parsePageRange(formatPageRange([2, 4, 5, 6], 9), 9), [2, 4, 5, 6]);
    });

    test('all pages gives empty string', () {
      expect(formatPageRange([3, 1, 2], 3), '');
    });
  });

  group('backNeedsHalfTurn', () {
    bool turn(
      DuplexBinding b, {
      bool printer = false,
      bool landscape = false,
    }) => backNeedsHalfTurn(
      printerRotatesBack: printer,
      binding: b,
      contentRotated90: landscape,
    );

    test('portrait: book as calibrated, calendar adds a half turn', () {
      expect(turn(DuplexBinding.book), isFalse);
      expect(turn(DuplexBinding.calendar), isTrue);
    });

    test('landscape content swaps book and calendar', () {
      expect(turn(DuplexBinding.book, landscape: true), isTrue);
      expect(turn(DuplexBinding.calendar, landscape: true), isFalse);
    });

    test('printer calibration rotation is applied on top', () {
      // e.g. the L3250, calibrated to rotate back pages
      expect(turn(DuplexBinding.book, printer: true), isTrue);
      expect(turn(DuplexBinding.calendar, printer: true), isFalse);
      expect(turn(DuplexBinding.book, printer: true, landscape: true), isFalse);
    });
  });
}
