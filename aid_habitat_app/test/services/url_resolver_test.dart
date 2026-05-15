import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/services/url_resolver.dart';

/// Tests de `isSvgUrl` — détecte si une URL doit être routée vers
/// `SvgPicture.memory` plutôt que `Image.memory` côté `CachedRemoteImage`.
///
/// Bug fix 2026-05-16 : les logos de caisses retraite MSA, SRE et
/// CAVIMAC ne s'affichaient pas dans le sélecteur admin parce que le
/// serveur les renvoie en data URI `data:image/svg+xml;base64,...` et
/// que `isSvgUrl` ne reconnaissait que les URLs avec extension `.svg`.
/// Cette suite verrouille les deux chemins de détection pour empêcher
/// la régression.
void main() {
  group('isSvgUrl — extension', () {
    test('URL HTTP qui finit par .svg → true', () {
      expect(isSvgUrl('https://example.com/logo.svg'), isTrue);
      expect(isSvgUrl('/retirement-logos/principal/msa.svg'), isTrue);
    });

    test('URL avec query string après .svg → true', () {
      expect(isSvgUrl('https://example.com/logo.svg?v=2'), isTrue);
      expect(isSvgUrl('/logo.svg?cache=bust'), isTrue);
    });

    test('Casse mixte → true (matching case-insensitive)', () {
      expect(isSvgUrl('https://example.com/Logo.SVG'), isTrue);
      expect(isSvgUrl('/path/MSA.Svg'), isTrue);
    });

    test('URL HTTP qui ne finit pas par .svg → false', () {
      expect(isSvgUrl('https://example.com/logo.png'), isFalse);
      expect(isSvgUrl('https://example.com/logo.jpg'), isFalse);
      expect(isSvgUrl('https://example.com/logo'), isFalse);
    });

    test('Empty / random → false', () {
      expect(isSvgUrl(''), isFalse);
      expect(isSvgUrl('garbage'), isFalse);
    });
  });

  group('isSvgUrl — data URI (fix audit 2026-05-16)', () {
    test('data:image/svg+xml;base64,... → true', () {
      // Cas réel renvoyé par `readPrincipalLogoAsDataUri` côté serveur
      // pour les logos MSA / SRE / CAVIMAC (inline SVG).
      expect(
        isSvgUrl('data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg=='),
        isTrue,
      );
    });

    test('data:image/svg+xml;utf8,... (non-base64) → true', () {
      // Variante URL-encoded utilisée par certains backends.
      expect(
        isSvgUrl('data:image/svg+xml;utf8,%3Csvg%3E%3C%2Fsvg%3E'),
        isTrue,
      );
    });

    test('data:image/png;base64,... → false (bitmap, pas SVG)', () {
      // Les logos PNG inline (CNAV, CNRACL, SSI, etc.) doivent aller
      // dans `Image.memory`, pas `SvgPicture.memory`.
      expect(
        isSvgUrl('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA'),
        isFalse,
      );
      expect(
        isSvgUrl('data:image/jpeg;base64,/9j/4AAQSkZJRgAB'),
        isFalse,
      );
    });

    test('data:application/json → false (pas une image)', () {
      expect(isSvgUrl('data:application/json,{"a":1}'), isFalse);
    });
  });
}
