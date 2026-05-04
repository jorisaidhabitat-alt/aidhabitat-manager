// PencilDoubleTapPlugin.swift
//
// Pont natif iOS ↔ Flutter pour le geste « double-tap sur le côté de
// l'Apple Pencil 2 / Pencil Pro ». Apple ne forwarde PAS ce geste à
// Safari/WebKit (donc inutilisable depuis la PWA Vercel actuelle) ; il
// faut un binding `UIPencilInteractionDelegate` natif côté iOS.
//
// Chaque double-tap est relayé au code Dart via une MethodChannel,
// donnant à `PencilInteractionService` (lib/services/) le signal de
// switcher l'outil courant vers la gomme dans toutes les surfaces de
// prise de notes (notes_widget.dart, plan_canvas.dart, annotations PDF
// dans documents_screen.dart).
//
// ────────────────────────────────────────────────────────────────────
// COMMENT ACTIVER (à faire une seule fois, quand on bascule en natif)
// ────────────────────────────────────────────────────────────────────
// Dans `AppDelegate.swift`, ajouter UNE LIGNE après
// `GeneratedPluginRegistrant.register(with: self)` :
//
//     PencilDoubleTapPlugin.register(with: self)
//
// C'est tout. Le plugin attache automatiquement une `UIPencilInteraction`
// au root view du `FlutterViewController` et relaie les events à Dart.
// ────────────────────────────────────────────────────────────────────
//
// Pour tester : un Apple Pencil 2 ou Pencil Pro EST nécessaire, et il
// faut un device physique (le simulateur iOS n'émule pas le double-tap
// du stylet — c'est un signal Bluetooth privé du firmware Pencil).

import Flutter
import UIKit

class PencilDoubleTapPlugin: NSObject, FlutterPlugin, UIPencilInteractionDelegate {
  // Channel name partagé avec `PencilInteractionService` côté Dart.
  // Si vous le changez ici, mettez-le à jour côté Dart aussi.
  private static let channelName = "aidhabitat/pencil_interaction"

  private let channel: FlutterMethodChannel

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  // Méthode appelée par AppDelegate.swift au lancement.
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PencilDoubleTapPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Attache l'interaction Pencil au root view du Flutter controller.
    // On passe par le keyWindow plutôt que par registrar.view() (qui
    // n'est pas exposé dans tous les Flutter SDK) — robuste à tous les
    // setups single/multi-window iPadOS.
    DispatchQueue.main.async {
      let pencilInteraction = UIPencilInteraction()
      pencilInteraction.delegate = instance
      // Récupère la fenêtre principale active. iPadOS 15+ gère plusieurs
      // scènes — on prend la première foreground active, fallback sur
      // la première de la liste.
      let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
      let activeScene = scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first
      if let rootView = activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view
        ?? activeScene?.windows.first?.rootViewController?.view {
        rootView.addInteraction(pencilInteraction)
      } else {
        NSLog("[PencilDoubleTapPlugin] root view introuvable — interaction non attachée")
      }
    }
  }

  // MARK: - FlutterPlugin

  // Aucune méthode entrante côté Dart→Swift pour l'instant. On garde le
  // handler pour respecter le protocole FlutterPlugin et permettre
  // d'ajouter des appels futurs (ex: lire `UIPencilInteraction.preferredTapAction`
  // côté Dart pour respecter la préférence système).
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPreferredTapAction":
      // Permet à Dart de savoir si l'utilisateur a configuré son Pencil
      // sur "switch tools / eraser" ou "show palette" ou "ignored".
      // Renvoie une string parmi : ignore, switchEraser, switchPrevious,
      // showColorPalette, showInkAttributes, runSystemShortcut, unknown.
      result(Self.encodePreferredTapAction(UIPencilInteraction.preferredTapAction))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - UIPencilInteractionDelegate

  // Appelé par iOS quand l'utilisateur double-tape sur le côté du
  // stylet (geste matériel détecté par le firmware Pencil 2/Pro).
  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    // On envoie l'event à Dart, en incluant la préférence utilisateur
    // pour que Dart puisse choisir d'honorer (ex: ne switcher la gomme
    // QUE si la préférence iOS est sur "switch eraser") ou outrepasser
    // (forcer la gomme indépendamment de la préférence).
    let action = Self.encodePreferredTapAction(UIPencilInteraction.preferredTapAction)
    channel.invokeMethod("doubleTap", arguments: ["preferredAction": action])
  }

  // Conversion enum iOS → string portable. Évite de hardcoder des
  // entiers Swift dans le code Dart.
  private static func encodePreferredTapAction(
    _ action: UIPencilInteraction.PreferredTapAction
  ) -> String {
    switch action {
    case .ignore: return "ignore"
    case .switchEraser: return "switchEraser"
    case .switchPrevious: return "switchPrevious"
    case .showColorPalette: return "showColorPalette"
    case .showInkAttributes: return "showInkAttributes"
    case .runSystemShortcut: return "runSystemShortcut"
    @unknown default: return "unknown"
    }
  }
}
