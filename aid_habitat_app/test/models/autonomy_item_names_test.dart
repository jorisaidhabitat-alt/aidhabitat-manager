import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('le libellé historique des tâches ménagères est normalisé', () {
    expect(
      canonicalAutonomyItemName(kLegacyHouseholdAutonomyItemName),
      kHouseholdAutonomyItemName,
    );
    expect(
      canonicalAutonomyItemName(kHouseholdAutonomyItemName),
      kHouseholdAutonomyItemName,
    );
  });

  test('la désérialisation locale normalise immédiatement le libellé', () {
    final item = AutonomyItem.fromJson({
      'name': kLegacyHouseholdAutonomyItemName,
      'checked': true,
    });

    expect(item.name, kHouseholdAutonomyItemName);
    expect(item.checked, isTrue);
  });
}
