import 'package:aid_habitat_app/services/document_file_naming.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('publicDocumentFileName', () {
    test('remplace un nom technique remote_doc par le titre et le format', () {
      expect(
        publicDocumentFileName(
          storedName:
              'remote_doc_bm9jb2RiLWJlbmVmaWNpYWlyZS01NQ__bm9jb2RiLWJlbmVmaWNpYWlyZS01NTo6MzRjZDkwNWYtMWJmNy00MGE3LTgyNzQtMGNjODIyMWViMmVm',
          title: 'devis sdb',
          mimeType: 'application/pdf',
        ),
        'devis sdb.pdf',
      );
    });

    test('conserve un vrai nom de fichier', () {
      expect(
        publicDocumentFileName(
          storedName: 'Devis SDB.pdf',
          title: 'Titre ignore',
          mimeType: 'application/pdf',
        ),
        'Devis SDB.pdf',
      );
    });

    test('corrige un nom technique qui contient deja une extension', () {
      expect(
        publicDocumentFileName(
          storedName: 'remote_doc_abc.pdf',
          title: 'devis sdb',
        ),
        'devis sdb.pdf',
      );
    });

    test('utilise le type quand le mime type est absent', () {
      expect(
        publicDocumentFileName(
          storedName: 'remote_doc_abc',
          title: 'devis sdb',
          type: 'pdf',
        ),
        'devis sdb.pdf',
      );
    });

    test('nettoie les separateurs dangereux', () {
      expect(
        publicDocumentFileName(
          storedName: 'remote_doc_abc',
          title: 'devis/sdb',
          mimeType: 'application/pdf',
        ),
        'devis sdb.pdf',
      );
    });
  });
}
