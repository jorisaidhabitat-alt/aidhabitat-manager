// Stub no-op pour `note_window_web.dart`. Importé sur les plateformes
// non-web (native macOS/iOS/Android) où `dart:html` n'est pas dispo.
// Les call-sites guardent toujours par `kIsWeb` avant d'appeler ces
// fonctions, donc ce stub ne sert qu'à faire passer la compilation.

import 'dart:async';

bool isDesktopBrowser() => false;

bool tryOpenNoteWindow({
  required String patientId,
  required String tabKey,
  required String title,
  required String initialText,
  required double defaultWidth,
  required double defaultHeight,
}) =>
    false;

void persistNoteWindowFrame({
  required String tabKey,
  required double left,
  required double top,
  required double width,
  required double height,
}) {}

void sendNoteIpc({required String method, required Map<String, dynamic> args}) {}

StreamSubscription<dynamic> listenNoteIpc(
    void Function(String method, Map<String, dynamic> args) callback) {
  // Stream vide — la subscription cancel() est une no-op sécuritaire.
  return const Stream<dynamic>.empty().listen((_) {});
}

Map<String, String> readUrlNoteParams() => const {};
