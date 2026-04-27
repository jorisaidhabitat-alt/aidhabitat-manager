import 'dart:typed_data';

import 'web_file_saver_web.dart'
    if (dart.library.io) 'web_file_saver_io.dart';

/// Cross-platform helper to trigger a file download.
///
/// On web : creates a `Blob` URL from [bytes] + [mimeType] and synthesises a
/// click on a hidden `<a download>` anchor — iOS Safari + standalone PWA
/// safe. Returns `true` on success.
///
/// On native : returns `false` so the caller falls back to `FilePicker.
/// platform.saveFile` (which gives a native save dialog).
Future<bool> triggerWebFileDownload({
  required Uint8List bytes,
  required String fileName,
  String mimeType = 'application/octet-stream',
}) async {
  return triggerWebFileDownloadImpl(
    bytes: bytes,
    fileName: fileName,
    mimeType: mimeType,
  );
}
