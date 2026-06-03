import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

class ScannedDocumentResult {
  const ScannedDocumentResult({
    required this.path,
    required this.fileName,
    required this.mimeType,
    required this.pageCount,
  });

  final String path;
  final String fileName;
  final String mimeType;
  final int pageCount;

  factory ScannedDocumentResult.fromMap(Map<dynamic, dynamic> raw) {
    return ScannedDocumentResult(
      path: raw['path']?.toString() ?? '',
      fileName: raw['fileName']?.toString() ?? 'scan.pdf',
      mimeType: raw['mimeType']?.toString() ?? 'application/pdf',
      pageCount: (raw['pageCount'] as num?)?.toInt() ?? 1,
    );
  }

  bool get isValid => path.trim().isNotEmpty;
}

class DocumentScannerService {
  DocumentScannerService._();

  static final DocumentScannerService instance = DocumentScannerService._();

  static const MethodChannel _channel = MethodChannel(
    'aidhabitat/document_scanner',
  );

  bool get isNativeScannerSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<ScannedDocumentResult?> scanToPdf() async {
    if (!isNativeScannerSupported) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'scanDocument',
      );
      if (raw == null || raw.isEmpty) return null;
      final result = ScannedDocumentResult.fromMap(raw);
      return result.isValid ? result : null;
    } on PlatformException catch (error) {
      final code = error.code.trim().toLowerCase();
      if (code == 'cancelled' || code == 'user_cancelled') return null;
      rethrow;
    } on MissingPluginException {
      return null;
    }
  }
}
