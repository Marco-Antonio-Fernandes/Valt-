import 'package:flutter_test/flutter_test.dart';
import 'package:hq_reader/main.dart';

void main() {
  testWidgets('abre biblioteca', (tester) async {
    await tester.pumpWidget(const VaultApp());
    expect(find.text('As tuas sagas'), findsOneWidget);
  });
}
