import 'dart:convert';
import 'dart:typed_data';

import 'package:aid_habitat_app/services/wiki_share_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wiki image sharing', () {
    test('uses the item title and the detected JPEG extension', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x00]);
      final format = detectWikiShareImageFormat(bytes);

      expect(format?.mimeType, 'image/jpeg');
      expect(
        wikiShareImageFileName('abattant automatique', format!),
        'abattant automatique.jpg',
      );
    });

    test('preserves accents and removes forbidden filename characters', () {
      const format = WikiShareImageFormat(
        extension: 'png',
        mimeType: 'image/png',
      );

      expect(
        wikiShareImageFileName('Évier / réglable?.jpg', format),
        'Évier _ réglable_.png',
      );
    });

    test('decodes an inline image instead of sharing its URL as text', () {
      final source = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final dataUrl = 'data:image/png;base64,${base64Encode(source)}';

      final decoded = decodeWikiImageDataUrl(dataUrl);

      expect(decoded, source);
      expect(detectWikiShareImageFormat(decoded!)?.extension, 'png');
    });
  });
}
