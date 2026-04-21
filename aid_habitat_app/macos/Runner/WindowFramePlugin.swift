import Cocoa
import FlutterMacOS

/// Plugin local qui expose la frame (origine + taille) de la NSWindow
/// hébergeant un FlutterViewController donné.
///
/// Le plugin Flutter `desktop_multi_window` 0.2.1 n'expose que `setFrame`
/// (WindowController) mais pas `getFrame` — ce plugin comble ce manque.
/// Il est enregistré à la fois sur la main window (MainFlutterWindow) et
/// sur chaque secondary window créée via `FlutterMultiWindowPlugin`
/// (via `setOnWindowCreatedCallback` dans AppDelegate).
///
/// Canal : `aidhabitat/window_frame`
/// Méthode : `getFrame` → returns [originX, originY, width, height] ou nil.
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

  // Required by FlutterPlugin protocol — unused (we register via the
  // custom `register(with:viewController:)` signature above).
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
