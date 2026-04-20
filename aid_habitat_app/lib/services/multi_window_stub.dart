// Stub no-op de `package:desktop_multi_window/desktop_multi_window.dart`
// utilisé uniquement sur les plateformes où ce package n'est pas
// supporté (web, iOS, Android). Permet de laisser les mêmes imports
// dans le code partagé — les appels ne font rien en silence.
//
// Les vraies APIs (createWindow, invokeMethod, setMethodHandler,
// WindowController.close, …) sont exposées avec la même signature que
// le package officiel mais retournent des valeurs factices. Les écrans
// qui dépendent réellement du multi-fenêtre sont gardés par `kIsWeb`
// avant d'être rendus, donc ce stub n'est jamais utilisé à chaud sur
// web.

import 'package:flutter/services.dart' show MethodCall;

typedef MultiWindowMethodHandler = Future<dynamic> Function(
    MethodCall call, int fromWindowId);

class DesktopMultiWindow {
  DesktopMultiWindow._();

  static Future<WindowController> createWindow([String? arguments]) async {
    return WindowController._(0);
  }

  static Future<dynamic> invokeMethod(
      int targetWindowId, String method, [dynamic arguments]) async {
    return null;
  }

  static void setMethodHandler(MultiWindowMethodHandler? handler) {}
}

class WindowController {
  final int windowId;
  WindowController._(this.windowId);

  static WindowController fromWindowId(int id) => WindowController._(id);

  Future<void> show() async {}
  Future<void> hide() async {}
  Future<void> close() async {}
  Future<void> setFrame(dynamic frame) async {}
  Future<void> setTitle(String title) async {}
}
