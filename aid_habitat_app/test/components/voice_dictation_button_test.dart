import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/components/voice_dictation_button.dart';

void main() {
  group('applyVoiceDictationTranscript', () {
    test('insère la dictée à la fin avec un espace naturel', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'La personne',
          selection: TextSelection.collapsed(offset: 11),
        ),
        transcript: 'vit seule',
      );

      expect(result.text, 'La personne vit seule');
      expect(result.selection.baseOffset, result.text.length);
    });

    test('insère au curseur sans perdre le suffixe', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'La personne seule.',
          selection: TextSelection.collapsed(offset: 12),
        ),
        transcript: 'vit',
      );

      expect(result.text, 'La personne vit seule.');
      expect(result.selection.baseOffset, 16);
    });

    test('remplace la sélection courante', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'Autonomie faible',
          selection: TextSelection(baseOffset: 10, extentOffset: 16),
        ),
        transcript: 'partielle',
      );

      expect(result.text, 'Autonomie partielle');
    });

    test('les résultats partiels repartent de la même base', () {
      const base = TextEditingValue(
        text: 'Observation :',
        selection: TextSelection.collapsed(offset: 13),
      );

      final partial = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: 'marche',
      );
      final finalResult = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: 'marche avec une canne',
      );

      expect(partial.text, 'Observation : marche');
      expect(finalResult.text, 'Observation : marche avec une canne');
      expect(finalResult.text, isNot(contains('marche marche')));
    });

    test('une hypothèse vide ne supprime pas la note existante', () {
      const base = TextEditingValue(
        text: 'Texte conservé',
        selection: TextSelection.collapsed(offset: 5),
      );

      final result = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: '   ',
      );

      expect(result, base);
    });

    test('la ponctuation dictée ne reçoit pas d’espace avant', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'Besoin identifié',
          selection: TextSelection.collapsed(offset: 16),
        ),
        transcript: '.',
      );

      expect(result.text, 'Besoin identifié.');
    });
  });
}
