import 'package:flutter_test/flutter_test.dart';
import 'package:donloader/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const DonloaderApp());
    expect(find.text('Donloader'), findsOneWidget);
  });
}
