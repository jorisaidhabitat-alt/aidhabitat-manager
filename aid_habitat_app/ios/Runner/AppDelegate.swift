import Flutter
import PDFKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileProtectionChannelName = "aidhabitat/file_protection"
  private let pdfRotationChannelName = "aidhabitat/pdf_rotation"

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
    if let rewriteRegistrar = registrar(forPlugin: "AppleIntelligenceRewritePlugin") {
      AppleIntelligenceRewritePlugin.register(with: rewriteRegistrar)
    }
    if let registrar = registrar(forPlugin: "PdfRotationChannel") {
      let channel = FlutterMethodChannel(
        name: pdfRotationChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handlePdfRotationCall)
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

  private func handlePdfRotationCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "rotatePdfFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let sourcePath = args["sourcePath"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Le PDF à pivoter est manquant.",
          details: nil
        )
      )
      return
    }
    let quarterTurns = args["quarterTurns"] as? Int ?? 0

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let outputPath = try self.rotatePdfFile(
          sourcePath: sourcePath,
          quarterTurns: quarterTurns
        )
        DispatchQueue.main.async {
          result(outputPath)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "pdf_rotation_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func rotatePdfFile(sourcePath: String, quarterTurns: Int) throws -> String {
    let normalizedTurns = ((quarterTurns % 4) + 4) % 4
    guard normalizedTurns != 0 else { return sourcePath }

    let sourceUrl = URL(fileURLWithPath: sourcePath)
    guard FileManager.default.fileExists(atPath: sourceUrl.path) else {
      throw NSError(
        domain: "PdfRotation",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Fichier PDF introuvable."]
      )
    }
    guard let document = PDFDocument(url: sourceUrl), document.pageCount > 0 else {
      throw NSError(
        domain: "PdfRotation",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "PDF illisible ou vide."]
      )
    }

    let degrees = normalizedTurns * 90
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      page.rotation = normalizedPdfRotation(page.rotation + degrees)
    }

    let outputUrl = FileManager.default.temporaryDirectory
      .appendingPathComponent("rotated-\(UUID().uuidString).pdf")
    if FileManager.default.fileExists(atPath: outputUrl.path) {
      try FileManager.default.removeItem(at: outputUrl)
    }
    guard document.write(to: outputUrl) else {
      throw NSError(
        domain: "PdfRotation",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Écriture du PDF pivoté impossible."]
      )
    }
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete],
      ofItemAtPath: outputUrl.path
    )
    return outputUrl.path
  }

  private func normalizedPdfRotation(_ degrees: Int) -> Int {
    let normalized = degrees % 360
    return normalized >= 0 ? normalized : normalized + 360
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
