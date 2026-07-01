import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/screens/visit_report/retirement_fund_selection.dart';

void main() {
  group('updateRetirementFundsAtIndex', () {
    test('replaces a single selected fund directly', () {
      final next = updateRetirementFundsAtIndex(
        current: ['Carsat'],
        fundIndex: 0,
        value: 'MSA',
      );

      expect(next, ['MSA']);
      expect(serializeRetirementFunds(next), 'MSA');
    });

    test('swaps values when picking an already selected fund elsewhere', () {
      final next = updateRetirementFundsAtIndex(
        current: ['Carsat', 'MSA'],
        fundIndex: 0,
        value: 'MSA',
      );

      expect(next, ['MSA', 'Carsat']);
      expect(serializeRetirementFunds(next), 'MSA; Carsat');
    });

    test('moves an existing fund into an empty pending slot', () {
      final next = updateRetirementFundsAtIndex(
        current: ['Carsat'],
        fundIndex: 1,
        value: 'Carsat',
      );

      expect(next, ['Carsat']);
      expect(serializeRetirementFunds(next), 'Carsat');
    });

    test('keeps parsing case-insensitive and deduplicated', () {
      expect(parseRetirementFunds('Carsat; carsat | MSA'), ['Carsat', 'MSA']);
    });

    test('can replace a selected fund with Aucune', () {
      final next = updateRetirementFundsAtIndex(
        current: ['Carsat'],
        fundIndex: 0,
        value: 'Aucune',
      );

      expect(next, ['Aucune']);
      expect(serializeRetirementFunds(next), 'Aucune');
    });
  });
}
