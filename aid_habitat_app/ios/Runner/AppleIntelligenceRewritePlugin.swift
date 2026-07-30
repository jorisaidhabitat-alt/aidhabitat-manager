import Flutter
import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppleIntelligenceRewritePlugin: NSObject, FlutterPlugin {
  private static let channelName = "aidhabitat/apple_intelligence_rewrite"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = AppleIntelligenceRewritePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(Self.isAvailable)
    case "rewrite":
      handleRewrite(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleRewrite(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let text = arguments["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "La note à reformuler est manquante.",
          details: nil
        )
      )
      return
    }

    let mode = arguments["mode"] as? String ?? "professional"

    guard #available(iOS 26.0, *) else {
      result(Self.unavailableError())
      return
    }

    #if canImport(FoundationModels)
    let model = Self.rewriteModel
    guard model.isAvailable, model.supportsLocale(Locale(identifier: "fr_FR")) else {
      result(Self.unavailableError(for: model.availability))
      return
    }

    Task { @MainActor in
      do {
        let rewrittenText = try await Self.rewrite(
          text: text,
          mode: mode,
          model: model
        )
        result(rewrittenText)
      } catch {
        result(
          FlutterError(
            code: "rewrite_failed",
            message: Self.userMessage(for: error),
            details: nil
          )
        )
      }
    }
    #else
    result(Self.unavailableError())
    #endif
  }

  private static var isAvailable: Bool {
    guard #available(iOS 26.0, *) else { return false }
    #if canImport(FoundationModels)
    return rewriteModel.isAvailable
      && rewriteModel.supportsLocale(Locale(identifier: "fr_FR"))
    #else
    return false
    #endif
  }

  private static func unavailableError() -> FlutterError {
    FlutterError(
      code: "model_unavailable",
      message: "La reformulation Apple n'est pas disponible sur cet iPad.",
      details: nil
    )
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, *)
  private static var rewriteModel: SystemLanguageModel {
    SystemLanguageModel(
      useCase: .general,
      guardrails: .permissiveContentTransformations
    )
  }

  @available(iOS 26.0, *)
  private static func rewrite(
    text: String,
    mode: String,
    model: SystemLanguageModel
  ) async throws -> String {
    let session = LanguageModelSession(
      model: model,
      instructions: instructions(for: mode)
    )
    let response = try await session.respond(
      to: text,
      options: GenerationOptions(
        temperature: 0,
        maximumResponseTokens: 2_048
      )
    )
    let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      throw RewriteError.emptyResponse
    }
    return output
  }

  @available(iOS 26.0, *)
  private static func unavailableError(
    for availability: SystemLanguageModel.Availability
  ) -> FlutterError {
    let message: String
    switch availability {
    case .available:
      message = "La reformulation en français n'est pas disponible sur cet iPad."
    case .unavailable(.deviceNotEligible):
      message = "Cet iPad n'est pas compatible avec la reformulation Apple."
    case .unavailable(.appleIntelligenceNotEnabled):
      message = "Activez Apple Intelligence dans les réglages de l'iPad."
    case .unavailable(.modelNotReady):
      message = "Apple Intelligence est encore en cours de préparation."
    }
    return FlutterError(code: "model_unavailable", message: message, details: nil)
  }

  @available(iOS 26.0, *)
  private static func instructions(for mode: String) -> String {
    let modeInstruction: String
    switch mode {
    case "concise":
      modeInstruction =
        "Rends la note plus concise tout en conservant chaque information utile."
    case "correct":
      modeInstruction =
        "Corrige uniquement l'orthographe, la grammaire et la ponctuation."
    default:
      modeInstruction =
        "Améliore la clarté et la fluidité avec les modifications les plus petites possible."
    }

    return """
    Tu aides des ergothérapeutes à rédiger des notes professionnelles en français.
    Reformule uniquement le texte fourni pour un rapport d'ergothérapie.
    N'ajoute aucune information, aucun diagnostic, aucune interprétation et aucun conseil.
    Ne supprime aucun fait, souhait ou réserve exprimée.
    Conserve exactement tous les identifiants qui commencent par AIDHABITAT_DATA_.
    Ne traduis, ne modifie, ne déplace et ne supprime aucun de ces identifiants.
    Si une formulation est ambiguë, conserve son sens sans la compléter.
    \(modeInstruction)
    Réponds uniquement avec la note finale, sans titre, commentaire, guillemets ni Markdown.
    """
  }

  @available(iOS 26.0, *)
  private static func userMessage(for error: Error) -> String {
    if let rewriteError = error as? RewriteError {
      return rewriteError.localizedDescription
    }
    if let generationError = error as? LanguageModelSession.GenerationError {
      switch generationError {
      case .exceededContextWindowSize:
        return "La note est trop longue pour être reformulée sur l'iPad."
      case .assetsUnavailable:
        return "Le modèle Apple n'est pas encore prêt. Réessayez plus tard."
      case .guardrailViolation:
        return "Apple Intelligence n'a pas pu reformuler cette note."
      case .unsupportedLanguageOrLocale:
        return "La reformulation en français n'est pas disponible."
      case .rateLimited:
        return "Apple Intelligence est momentanément occupé. Réessayez dans un instant."
      default:
        return "La reformulation locale a échoué. La note originale est conservée."
      }
    }
    return "La reformulation locale a échoué. La note originale est conservée."
  }

  @available(iOS 26.0, *)
  private enum RewriteError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
      "Apple Intelligence n'a renvoyé aucun texte."
    }
  }
  #endif
}
