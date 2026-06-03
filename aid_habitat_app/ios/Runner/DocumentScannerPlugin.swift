import Flutter
import UIKit
import VisionKit

class DocumentScannerPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate {
  private static let channelName = "aidhabitat/document_scanner"

  private let channel: FlutterMethodChannel
  private weak var scannerController: VNDocumentCameraViewController?
  private var pendingResult: FlutterResult?

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = DocumentScannerPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scanDocument":
      presentScanner(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentScanner(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Un scan de document est déjà en cours.",
          details: nil
        )
      )
      return
    }

    guard VNDocumentCameraViewController.isSupported else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Le scanner de documents n'est pas disponible sur cet iPad.",
          details: nil
        )
      )
      return
    }

    guard let presenter = Self.activePresenter() else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "Impossible d'ouvrir le scanner de documents.",
          details: nil
        )
      )
      return
    }

    pendingResult = result

    let controller = VNDocumentCameraViewController()
    controller.delegate = self
    scannerController = controller

    DispatchQueue.main.async {
      presenter.present(controller, animated: true)
    }
  }

  private static func activePresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    let root =
      activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? activeScene?.windows.first?.rootViewController
    return topMostViewController(from: root)
  }

  private static func topMostViewController(from root: UIViewController?) -> UIViewController? {
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }

  private func finish(result: @escaping () -> Void) {
    let controller = scannerController
    scannerController = nil
    if let controller {
      controller.dismiss(animated: true, completion: result)
    } else {
      result()
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    let flutterResult = pendingResult
    pendingResult = nil
    finish {
      flutterResult?(
        FlutterError(
          code: "cancelled",
          message: "Scan annulé.",
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    let flutterResult = pendingResult
    pendingResult = nil
    finish {
      flutterResult?(
        FlutterError(
          code: "scan_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    let flutterResult = pendingResult
    pendingResult = nil

    finish {
      guard scan.pageCount > 0 else {
        flutterResult?(
          FlutterError(
            code: "empty_scan",
            message: "Aucune page détectée.",
            details: nil
          )
        )
        return
      }

      do {
        let output = try self.writeScanAsPdf(scan)
        flutterResult?(
          [
            "path": output.path,
            "fileName": output.lastPathComponent,
            "mimeType": "application/pdf",
            "pageCount": scan.pageCount,
          ]
        )
      } catch {
        flutterResult?(
          FlutterError(
            code: "pdf_write_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func writeScanAsPdf(_ scan: VNDocumentCameraScan) throws -> URL {
    let timestamp = Int(Date().timeIntervalSince1970)
    let fileName = "scan_document_\(timestamp).pdf"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }

    let firstImage = scan.imageOfPage(at: 0)
    let firstBounds = CGRect(origin: .zero, size: firstImage.size)
    let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)

    try renderer.writePDF(to: url) { context in
      for index in 0 ..< scan.pageCount {
        autoreleasepool {
          let image = scan.imageOfPage(at: index)
          let bounds = CGRect(origin: .zero, size: image.size)
          context.beginPage(withBounds: bounds, pageInfo: [:])
          image.draw(in: bounds)
        }
      }
    }

    return url
  }
}
