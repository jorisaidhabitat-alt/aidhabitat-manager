import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

/// Rotation PDF native pour iPad/iPhone.
///
/// Le fallback Flutter dans `documents_screen.dart` rasterise chaque page en
/// PNG avant de reconstruire un PDF. C'est lent et ça alourdit fortement les
/// justificatifs scannés. Sur iOS, PDFKit sait persister uniquement la
/// rotation des pages, en conservant le PDF original beaucoup plus léger.
class PdfRotationService {
  PdfRotationService._();

  static final PdfRotationService instance = PdfRotationService._();

  static const MethodChannel _channel = MethodChannel(
    'aidhabitat/pdf_rotation',
  );

  bool get supportsNativeRotation =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<String?> rotatePdfFile({
    required String sourcePath,
    required int quarterTurns,
  }) async {
    final turns = quarterTurns % 4;
    if (!supportsNativeRotation || turns == 0 || sourcePath.trim().isEmpty) {
      return null;
    }

    try {
      final path = await _channel.invokeMethod<String>('rotatePdfFile', {
        'sourcePath': sourcePath,
        'quarterTurns': turns,
      });
      final trimmed = path?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw StateError(
        error.message?.trim().isNotEmpty == true
            ? error.message!
            : 'Rotation PDF native impossible.',
      );
    }
  }
}
