import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileProtectionChannelName = "aidhabitat/file_protection"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let pencilRegistrar = registrar(forPlugin: "PencilDoubleTapPlugin") {
      PencilDoubleTapPlugin.register(with: pencilRegistrar)
    }
    if let scannerRegistrar = registrar(forPlugin: "DocumentScannerPlugin") {
      DocumentScannerPlugin.register(with: scannerRegistrar)
    }
    if let registrar = registrar(forPlugin: "LocalFileProtectionChannel") {
      let channel = FlutterMethodChannel(
        name: fileProtectionChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handleFileProtectionCall)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleFileProtectionCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "protectPath" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Le chemin à protéger est manquant.",
          details: nil
        )
      )
      return
    }

    let recursive = args["recursive"] as? Bool ?? false
    let excludeFromBackup = args["excludeFromBackup"] as? Bool ?? false

    do {
      try protectPath(path, recursive: recursive, excludeFromBackup: excludeFromBackup)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "file_protection_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func protectPath(
    _ path: String,
    recursive: Bool,
    excludeFromBackup: Bool
  ) throws {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard FileManager.default.fileExists(atPath: path) else { return }

    let url = URL(fileURLWithPath: path)
    try applyProtection(to: url, excludeFromBackup: excludeFromBackup)

    guard recursive else { return }
    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: nil
    )
    while let child = enumerator?.nextObject() as? URL {
      try applyProtection(to: child, excludeFromBackup: excludeFromBackup)
    }
  }

  private func applyProtection(to url: URL, excludeFromBackup: Bool) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: url.path
    )
    guard excludeFromBackup else { return }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableUrl = url
    try mutableUrl.setResourceValues(values)
  }
}
