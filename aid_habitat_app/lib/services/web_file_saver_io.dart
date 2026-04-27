import 'dart:typed_data';

/// Native targets : on retourne false pour que l'appelant utilise le
/// `FilePicker.platform.saveFile` natif (boîte de dialogue système).
Future<bool> triggerWebFileDownloadImpl({
  required Uint8List bytes,
  required String fileName,
  String mimeType = 'application/octet-stream',
}) async {
  return false;
}
