import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/components/notes_canvas_painters.dart';

/// Couvre les briques extraites de `notes_widget.dart` lors du split
/// 2026-05-15 (audit P0 #9). Focus :
///   • aller-retour `Stroke.toJson()` ↔ `Stroke.fromJson()` (parité
///     avec le format React, c'est ce qui voyage en SQLite + serveur).
///   • plafond de 2000 points par stroke (protection mémoire).
///   • helpers tool/color en aller-retour.
void main() {
  group('toolToString / toolFromString', () {
    test('Aller-retour préserve l\'outil pour chaque valeur d\'enum', () {
      for (final tool in NoteTool.values) {
        final encoded = toolToString(tool);
        final decoded = toolFromString(encoded);
        expect(decoded, tool, reason: '$tool → "$encoded" → $decoded');
      }
    });

    test('Wording inconnu → null', () {
      expect(toolFromString('chainsaw'), isNull);
      expect(toolFromString(''), isNull);
    });
  });

  group('colorToHex / colorFromHex', () {
    test('ARGB int → hex 6 chars #RRGGBB (l\'alpha est masqué)', () {
      expect(colorToHex(0xff112233), '#112233');
      // L\'alpha en entrée doit être ignoré : 0xCC (204) sur #112233
      // donne le même résultat que 0xFF.
      expect(colorToHex(0xcc112233), '#112233');
    });

    test('hex #RRGGBB → ARGB int (alpha=0xFF par défaut)', () {
      expect(colorFromHex('#112233'), 0xff112233);
      expect(colorFromHex('112233'), 0xff112233);
    });

    test('hex #AARRGGBB → ARGB int (alpha respecté)', () {
      expect(colorFromHex('#80112233'), 0x80112233);
    });

    test('hex invalide → fallback noir (0xff111827)', () {
      expect(colorFromHex('#XYZ'), 0xff111827);
      expect(colorFromHex(''), 0xff111827);
      expect(colorFromHex('#123'), 0xff111827); // 3 chars non géré
    });
  });

  group('Stroke.toJson / fromJson', () {
    test('Aller-retour préserve tool, color, size, points', () {
      final original = Stroke(
        tool: NoteTool.pen,
        color: 0xff1122ff,
        size: 3.5,
        points: const [Offset(0.1, 0.2), Offset(0.4, 0.55)],
      );
      final encoded = original.toJson();
      final decoded = Stroke.fromJson(encoded)!;

      expect(decoded.tool, NoteTool.pen);
      expect(decoded.color, 0xff1122ff);
      expect(decoded.size, 3.5);
      expect(decoded.points.length, 2);
      expect(decoded.points[0].dx, closeTo(0.1, 1e-9));
      expect(decoded.points[0].dy, closeTo(0.2, 1e-9));
      expect(decoded.points[1].dx, closeTo(0.4, 1e-9));
      expect(decoded.points[1].dy, closeTo(0.55, 1e-9));
    });

    test('fromJson retourne null sur tool inconnu', () {
      expect(
        Stroke.fromJson({
          'tool': 'unknown',
          'color': '#ff0000',
          'size': 2.0,
          'points': [
            {'x': 0.0, 'y': 0.0},
          ],
        }),
        isNull,
      );
    });

    test('fromJson retourne null sur liste de points vide', () {
      expect(
        Stroke.fromJson({
          'tool': 'pen',
          'color': '#ff0000',
          'size': 2.0,
          'points': const <Map<String, dynamic>>[],
        }),
        isNull,
      );
    });

    test('fromJson retourne null sur points manquants', () {
      expect(
        Stroke.fromJson({
          'tool': 'pen',
          'color': '#ff0000',
          'size': 2.0,
        }),
        isNull,
      );
    });

    test('Plafond de 2000 points : un stroke avec 5000 points est tronqué',
        () {
      final points = List.generate(
        5000,
        (i) => {'x': i / 5000.0, 'y': i / 5000.0},
      );
      final decoded = Stroke.fromJson({
        'tool': 'pen',
        'color': '#ff0000',
        'size': 2.0,
        'points': points,
      })!;
      expect(decoded.points.length, 2000);
      // Les 2000 premiers points sont conservés dans l'ordre.
      expect(decoded.points[0].dx, closeTo(0.0, 1e-9));
      expect(decoded.points[1999].dx, closeTo(1999 / 5000.0, 1e-9));
    });

    test('Valeurs manquantes → defaults raisonnables', () {
      // Pas de "color" → fallback noir. Pas de "size" → 2.0.
      final decoded = Stroke.fromJson({
        'tool': 'pen',
        'points': [
          {'x': 0.5, 'y': 0.5},
        ],
      })!;
      expect(decoded.color, 0xff111827);
      expect(decoded.size, 2.0);
    });

    test('Points non-numériques → throws TypeError (limite connue)', () {
      // Limite documentée : `(raw['x'] as num?)` lève un TypeError quand
      // la valeur est un String. En pratique les strokes sont toujours
      // sérialisés via `toJson` qui produit des doubles, donc ce cas
      // ne devrait jamais arriver depuis un payload valide. Si on
      // veut une coercion défensive, il faudra remplacer le cast par
      // un `num.tryParse(raw['x'].toString())` dans fromJson. Pour
      // l'instant on documente le comportement actuel.
      expect(
        () => Stroke.fromJson({
          'tool': 'pen',
          'color': '#ff0000',
          'size': 2.0,
          'points': [
            {'x': 'oops', 'y': 'nope'},
          ],
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });
}
