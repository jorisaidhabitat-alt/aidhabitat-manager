import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/main.dart';

void main() {
  testWidgets('MyApp exposes the production app shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MyApp(
        home: Scaffold(
          body: Text('Aid Habitat smoke'),
        ),
      ),
    );

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(materialApp.title, "App'Ergo");
    expect(materialApp.locale, const Locale('fr', 'FR'));
    expect(materialApp.debugShowCheckedModeBanner, isFalse);
    expect(find.text('Aid Habitat smoke'), findsOneWidget);
  });
}
