import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const documentsRoot =
      '/var/mobile/Containers/Data/Application/CURRENT/Documents';

  group('resolveReplacementDocumentPath', () {
    test('keeps a compatible file inside the current Documents sandbox', () {
      const existing = '$documentsRoot/offline_documents/patient-1/devis.pdf';

      final result = resolveReplacementDocumentPath(
        applicationDocumentsPath: documentsRoot,
        existingPath: existing,
        patientId: 'patient-1',
        documentId: 'doc-1',
        fileName: 'devis.pdf',
        mimeType: 'application/pdf',
      );

      expect(result, existing);
    });

    test('repairs a path pointing to the iOS application container root', () {
      const invalidRoot = '/var/mobile/Containers/Data/Application/CURRENT';

      final result = resolveReplacementDocumentPath(
        applicationDocumentsPath: documentsRoot,
        existingPath: invalidRoot,
        patientId: 'BOISSIN Chantal',
        documentId: 'devis/sdb',
        fileName: 'devis sdb.pdf',
        mimeType: 'application/pdf',
      );

      expect(
        result,
        '$documentsRoot/offline_documents/BOISSIN_Chantal/devis_sdb.pdf',
      );
    });

    test('repairs a path left by a previous iOS sandbox UUID', () {
      const stale =
          '/var/mobile/Containers/Data/Application/OLD/Documents/'
          'offline_documents/patient-1/devis.pdf';

      final result = resolveReplacementDocumentPath(
        applicationDocumentsPath: documentsRoot,
        existingPath: stale,
        patientId: 'patient-1',
        documentId: 'doc-1',
        fileName: 'devis.pdf',
        mimeType: 'application/pdf',
      );

      expect(result, '$documentsRoot/offline_documents/patient-1/doc-1.pdf');
    });

    test('changes the local extension when rotated image bytes become PNG', () {
      const jpegPath = '$documentsRoot/offline_documents/patient-1/photo.jpg';

      final result = resolveReplacementDocumentPath(
        applicationDocumentsPath: documentsRoot,
        existingPath: jpegPath,
        patientId: 'patient-1',
        documentId: 'photo-1',
        fileName: 'photo.png',
        mimeType: 'image/png',
      );

      expect(result, '$documentsRoot/offline_documents/patient-1/photo-1.png');
    });
  });
}
