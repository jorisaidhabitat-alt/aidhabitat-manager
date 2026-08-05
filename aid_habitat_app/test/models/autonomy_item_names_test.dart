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
}
