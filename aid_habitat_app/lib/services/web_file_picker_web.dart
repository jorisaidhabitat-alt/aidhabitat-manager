// This file is only picked up by the web target (see conditional import
// in `web_file_picker.dart`).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'web_file_picker.dart';

/// Opens a native OS picker on the web platform.
///
/// On iPad PWA standalone, `file_picker` sometimes fails to open the
/// picker because the user activation is lost between the tap and the
/// async FilePicker call. Doing a **synchronous** `<input>.click()` inside
/// the same gesture frame is the only reliable pattern.
Future<WebPickedFile?> pickWebFileImpl({
  required String accept,
  bool capture = false,
}) async {
  final completer = Completer<WebPickedFile?>();
  final input = html.FileUploadInputElement()
    ..accept = accept
    ..multiple = false
    // Must be attached to the DOM on iOS for the click to fire the
    // picker (a pure in-memory element is ignored in PWA standalone).
    ..style.position = 'fixed'
    ..style.left = '-9999px'
    ..style.top = '-9999px';
  if (capture) {
    // `capture="environment"` → iOS opens the rear camera directly.
    input.setAttribute('capture', 'environment');
  }

  html.document.body?.append(input);

  StreamSubscription? changeSub;
  StreamSubscription? cancelSub;

  void cleanup() {
    changeSub?.cancel();
    cancelSub?.cancel();
    input.remove();
  }

  changeSub = input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoadEnd.first;
    final bytes = reader.result;
    cleanup();
    if (!completer.isCompleted) {
      if (bytes is Uint8List) {
        completer.complete(WebPickedFile(name: file.name, bytes: bytes));
      } else if (bytes is List<int>) {
        completer.complete(
          WebPickedFile(name: file.name, bytes: Uint8List.fromList(bytes)),
        );
      } else {
        completer.complete(null);
      }
    }
  });

  // Safari on iOS fires `cancel` (iOS 18+) when the user dismisses the
  // picker. Older versions just never fire `change`; in that case the
  // completer stays open and the caller never awaits — we accept that,
  // because the caller disables its button for the duration and resets
  // on the next tap.
  cancelSub = input.on['cancel'].listen((_) {
    cleanup();
    if (!completer.isCompleted) completer.complete(null);
  });

  // Fire click within the synchronous gesture frame.
  input.click();

  return completer.future;
}
