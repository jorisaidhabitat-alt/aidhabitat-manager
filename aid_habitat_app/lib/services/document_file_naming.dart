import 'package:path/path.dart' as p;

bool isTechnicalDocumentFileName(String value) {
  final baseName = p.basename(value.trim());
  if (baseName.isEmpty) return false;
  final stem = p.basenameWithoutExtension(baseName);
  if (stem.startsWith('remote_doc_')) return true;
  if (RegExp(r'^doc_\d{10,}$').hasMatch(stem)) return true;
  return false;
}

String publicDocumentFileName({
  required String storedName,
  required String title,
  String? mimeType,
  String? type,
}) {
  final extension = documentFileExtension(
    storedName: storedName,
    mimeType: mimeType,
    type: type,
  );
  final storedBase = _cleanFileName(p.basename(storedName));
  if (storedBase.isNotEmpty && !isTechnicalDocumentFileName(storedBase)) {
    return _ensureExtension(storedBase, extension);
  }

  final titleBase = _cleanFileName(title);
  return _ensureExtension(
    titleBase.isEmpty ? 'document' : titleBase,
    extension,
  );
}

String documentFileExtension({
  required String storedName,
  String? mimeType,
  String? type,
}) {
  final fromName = p.extension(p.basename(storedName)).toLowerCase();
  if (_isSafeExtension(fromName)) return fromName;

  switch ((mimeType ?? '').trim().toLowerCase()) {
    case 'application/pdf':
      return '.pdf';
    case 'image/jpeg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'image/svg+xml':
      return '.svg';
  }

  switch ((type ?? '').trim().toLowerCase()) {
    case 'pdf':
      return '.pdf';
    case 'image':
      return '.jpg';
  }

  return '.bin';
}

String _ensureExtension(String rawName, String extension) {
  final safeName = _cleanFileName(rawName);
  final fallbackName = safeName.isEmpty ? 'document' : safeName;
  if (p.extension(fallbackName).isNotEmpty) return fallbackName;
  return '$fallbackName$extension';
}

String _cleanFileName(String value) {
  return value
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^\.+|\.+$'), '')
      .trim();
}

bool _isSafeExtension(String extension) {
  if (extension.isEmpty) return false;
  return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension);
}
