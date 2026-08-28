import 'package:aid_habitat_app/components/doc_card.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

void main() {
  final document = DocItem(
    id: 'doc-1',
    type: 'doc',
    name: 'document.docx',
    title: 'Document de test',
    date: '2026-08-28T10:00:00Z',
  );

  Widget buildCard({required VoidCallback onSelect}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            height: 280,
            child: DocCard(
              doc: document,
              selected: false,
              selectionMode: false,
              onTap: () {},
              onSelect: onSelect,
              onToggleSelect: () {},
              onDelete: () {},
              onDownload: () {},
              onRename: () {},
              onShare: () {},
              onDuplicate: () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('long press exposes selection without selecting immediately', (
    tester,
  ) async {
    var selectionCount = 0;
    await tester.pumpWidget(buildCard(onSelect: () => selectionCount += 1));

    await tester.longPress(find.byType(DocCard));
    await tester.pumpAndSettle();

    expect(selectionCount, 0);
    expect(find.text('Sélectionner'), findsOneWidget);
    expect(find.text('Télécharger'), findsOneWidget);
    expect(find.text('Renommer'), findsOneWidget);
    expect(find.text('Partager'), findsOneWidget);
    expect(find.text('Dupliquer'), findsOneWidget);
    expect(find.text('Supprimer'), findsOneWidget);

    await tester.tap(find.text('Sélectionner'));
    await tester.pumpAndSettle();

    expect(selectionCount, 1);
  });

  testWidgets('three-dot menu keeps document actions without selection', (
    tester,
  ) async {
    await tester.pumpWidget(buildCard(onSelect: () {}));

    await tester.tap(find.byIcon(LucideIcons.moreVertical));
    await tester.pumpAndSettle();

    expect(find.text('Sélectionner'), findsNothing);
    expect(find.text('Télécharger'), findsOneWidget);
    expect(find.text('Supprimer'), findsOneWidget);
  });
}
