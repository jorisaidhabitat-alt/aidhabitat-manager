// Picked up by the web target via the conditional import in
// `web_file_saver.dart`. `dart:html` is safe here.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

Future<bool> triggerWebFileDownloadImpl({
  required Uint8List bytes,
  required String fileName,
  String mimeType = 'application/octet-stream',
}) async {
  if (bytes.isEmpty) return false;
  // Crée un Blob → URL temporaire → click programmatique sur un anchor
  // `<a download>`. C'est le pattern web standard ; iOS Safari standalone
  // accepte le téléchargement à condition que le click reste dans la même
  // frame d'activation utilisateur que le tap initial.
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    final anchor = html.AnchorElement(href: url)
      ..download = fileName
      ..rel = 'noopener noreferrer';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } finally {
    // Libère l'URL après que le navigateur a démarré le téléchargement —
    // 100 ms suffisent largement.
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      html.Url.revokeObjectUrl(url);
    });
  }
}
