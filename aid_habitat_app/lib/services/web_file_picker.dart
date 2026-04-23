import 'dart:async';

import 'web_file_picker_web.dart'
    if (dart.library.io) 'web_file_picker_io.dart';

/// A file picked through the web helper. [bytes] is always populated on
/// web (no filesystem), [name] is the original filename.
class WebPickedFile {
  final String name;
  final List<int> bytes;
  const WebPickedFile({required this.name, required this.bytes});
}

/// Opens a native OS picker on the web platform only.
///
/// On native targets this returns null — callers should use `image_picker`
/// or `file_picker` directly.
///
/// [accept] is a MIME hint like `image/*` (Photothèque iOS) or `*/*`
/// (Fichiers iOS / Files). [capture] forces the camera when true.
///
/// This goes through raw `dart:html` DOM manipulation because
/// `file_picker` on iPad PWA standalone sometimes drops the picker click
/// (user-activation lost between the tap and the async FilePicker call).
/// A direct `<input>.click()` inside the user gesture frame works.
Future<WebPickedFile?> pickWebFile({
  required String accept,
  bool capture = false,
}) async {
  return pickWebFileImpl(accept: accept, capture: capture);
}
