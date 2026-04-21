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

// ---------------------------------------------------------------------------
// Plugin local qui expose la frame (origine + taille) de la NSWindow
// hébergeant un FlutterViewController donné. Le plugin Flutter
// `desktop_multi_window` 0.2.1 n'expose que `setFrame` mais pas `getFrame`
// — ce plugin comble ce manque.
//
// Défini ici (et pas dans un fichier séparé) pour éviter d'ajouter le
// fichier à `Runner.xcodeproj/project.pbxproj` manuellement.
//
// Canal : `aidhabitat/window_frame`
// Méthode : `getFrame` → returns [originX, originY, width, height] ou nil.
// ---------------------------------------------------------------------------

class WindowFramePlugin: NSObject, FlutterPlugin {
  private weak var viewController: FlutterViewController?

  init(viewController: FlutterViewController) {
    self.viewController = viewController
  }

  static func register(
    with registrar: FlutterPluginRegistrar,
    viewController: FlutterViewController
  ) {
    let channel = FlutterMethodChannel(
      name: "aidhabitat/window_frame",
      binaryMessenger: registrar.messenger
    )
    let instance = WindowFramePlugin(viewController: viewController)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  // Required by FlutterPlugin protocol — unused (we use the overload above).
  static func register(with registrar: FlutterPluginRegistrar) {}

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getFrame":
      guard let window = viewController?.view.window else {
        result(nil)
        return
      }
      let frame = window.frame
      result([
        frame.origin.x,
        frame.origin.y,
        frame.size.width,
        frame.size.height,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
