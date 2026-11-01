import 'package:duplex_printer/duplex_plan.dart';
import 'package:duplex_printer/pdf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('builds front and back passes from a real PDF', (tester) async {
    final service = PdfService(await PdfService.testDocument());
    expect(await service.pageCount(), 4);

    final plan = DuplexPlan.build(pages: [1, 2, 3], copies: 2);
    final front = PdfService(await service.buildPass(plan.front, dpi: 72));
    final back = PdfService(
      await service.buildPass(plan.back, dpi: 72, rotate: true),
    );
    expect(await front.pageCount(), 4);
    expect(await back.pageCount(), 4);
  });
}
