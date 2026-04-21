import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Plugin local pour exposer la frame de la fenêtre (position + taille).
    WindowFramePlugin.register(
      with: flutterViewController.registrar(forPlugin: "WindowFramePlugin"),
      viewController: flutterViewController
    )

    super.awakeFromNib()
  }
}
