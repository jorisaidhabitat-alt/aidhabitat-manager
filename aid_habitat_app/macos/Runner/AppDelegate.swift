import Cocoa
import FlutterMacOS
import desktop_multi_window

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Chaque secondary window (note détachée) est créée par
    // `desktop_multi_window` avec son propre FlutterViewController. On y
    // enregistre notre plugin local `WindowFramePlugin` pour que Dart
    // puisse lire la position de la fenêtre (et la transmettre à la main
    // window pour la conserver entre ouvertures).
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { flutterViewController in
      WindowFramePlugin.register(
        with: flutterViewController.registrar(forPlugin: "WindowFramePlugin"),
        viewController: flutterViewController
      )
    }
    super.applicationDidFinishLaunching(notification)
  }
}
