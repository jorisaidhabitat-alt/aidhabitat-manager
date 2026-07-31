// PencilDoubleTapPlugin.swift
//
// Pont natif iOS ↔ Flutter pour le geste « double-tap sur le côté de
// l'Apple Pencil 2 / Pencil Pro ». Apple ne forwarde PAS ce geste à
// Safari/WebKit (donc inutilisable depuis la PWA Vercel actuelle) ; il
// faut un binding `UIPencilInteractionDelegate` natif côté iOS.
//
// Chaque double-tap est relayé au code Dart via une MethodChannel,
// donnant à `PencilInteractionService` (lib/services/) le signal de
// basculer vers l'outil précédemment utilisé dans toutes les surfaces
// de prise de notes (notes_widget.dart, plan_canvas.dart, annotations
// PDF dans documents_screen.dart).
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
import ObjectiveC.runtime
import UIKit

private extension UIResponder {
  /// Après swizzle sur FlutterTextInputView, cet appel invoque
  /// l'implémentation UIKit originale puis neutralise sa barre d'assistance.
  @objc func aidHabitatInputAssistantItem() -> UITextInputAssistantItem {
    let assistant = aidHabitatInputAssistantItem()
    assistant.leadingBarButtonGroups = []
    assistant.trailingBarButtonGroups = []
    assistant.allowsHidingShortcuts = true
    return assistant
  }
}

class PencilDoubleTapPlugin: NSObject, FlutterPlugin, UIPencilInteractionDelegate {
  // Channel name partagé avec `PencilInteractionService` côté Dart.
  // Si vous le changez ici, mettez-le à jour côté Dart aussi.
  private static let channelName = "aidhabitat/pencil_interaction"

  private let channel: FlutterMethodChannel
  private var keyboardObserverTokens: [NSObjectProtocol] = []
  private static var didInstallInputAssistantSwizzle = false

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    Self.installInputAssistantSuppression()
    startSuppressingInputAssistant()
  }

  deinit {
    keyboardObserverTokens.forEach(NotificationCenter.default.removeObserver)
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
    // pour que Dart puisse choisir d'honorer ou outrepasser la
    // préférence iOS. Le comportement app actuel imite Apple Notes :
    // outil courant <-> outil précédemment utilisé.
    let action = Self.encodePreferredTapAction(UIPencilInteraction.preferredTapAction)
    channel.invokeMethod("doubleTap", arguments: ["preferredAction": action])
  }

  // MARK: - iPad text input assistant

  // Flutter utilise une vue texte UIKit cachée pour Scribble. iPadOS lui
  // ajoute par défaut une barre avec annuler/rétablir et la langue active,
  // ce qui crée un inset bas et déplace inutilement le relevé.
  //
  // La suppression sur notification seule arrivait trop tard : Scribble
  // demande parfois l'inputAssistantItem avant toute notification clavier.
  // On intercepte donc le getter de FlutterTextInputView une seule fois.
  private static func installInputAssistantSuppression() {
    guard !didInstallInputAssistantSwizzle else { return }
    guard
      let flutterInputViewClass = NSClassFromString("FlutterTextInputView"),
      let originalMethod = class_getInstanceMethod(
        flutterInputViewClass,
        #selector(getter: UIResponder.inputAssistantItem)
      ),
      let replacementMethod = class_getInstanceMethod(
        UIResponder.self,
        #selector(UIResponder.aidHabitatInputAssistantItem)
      )
    else {
      NSLog("[PencilDoubleTapPlugin] FlutterTextInputView introuvable pour masquer l'assistant")
      return
    }

    let originalSelector = #selector(getter: UIResponder.inputAssistantItem)
    let replacementSelector = #selector(UIResponder.aidHabitatInputAssistantItem)
    // Si le getter vient de UIResponder, on en installe d'abord une copie
    // propre à FlutterTextInputView. L'échange reste ainsi strictement local
    // et ne modifie aucun autre responder UIKit.
    class_addMethod(
      flutterInputViewClass,
      originalSelector,
      method_getImplementation(originalMethod),
      method_getTypeEncoding(originalMethod)
    )
    class_addMethod(
      flutterInputViewClass,
      replacementSelector,
      method_getImplementation(replacementMethod),
      method_getTypeEncoding(replacementMethod)
    )
    guard
      let installedOriginal = class_getInstanceMethod(
        flutterInputViewClass,
        originalSelector
      ),
      let installedReplacement = class_getInstanceMethod(
        flutterInputViewClass,
        replacementSelector
      )
    else {
      return
    }

    method_exchangeImplementations(installedOriginal, installedReplacement)
    didInstallInputAssistantSwizzle = true
  }

  // Le rattrapage couvre les vues déjà créées avant l'enregistrement du
  // plugin et les changements de first responder effectués par iPadOS.
  private func startSuppressingInputAssistant() {
    let center = NotificationCenter.default
    let notifications = [
      UIResponder.keyboardWillShowNotification,
      UIResponder.keyboardDidShowNotification,
      UIResponder.keyboardWillChangeFrameNotification,
      UIResponder.keyboardDidChangeFrameNotification,
      UITextField.textDidBeginEditingNotification,
      UITextView.textDidBeginEditingNotification,
      UIApplication.didBecomeActiveNotification,
    ]

    for notification in notifications {
      let token = center.addObserver(
        forName: notification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.scheduleInputAssistantSuppression()
      }
      keyboardObserverTokens.append(token)
    }

    scheduleInputAssistantSuppression()
  }

  private func scheduleInputAssistantSuppression() {
    suppressInputAssistant()
    for delay in [0.0, 0.05, 0.2] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.suppressInputAssistant()
      }
    }
  }

  private func suppressInputAssistant() {
    for window in Self.activeWindows() {
      Self.suppressInputAssistant(in: window)
    }
  }

  private static func activeWindows() -> [UIWindow] {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter {
        $0.activationState == .foregroundActive ||
        $0.activationState == .foregroundInactive
      }
    return scenes.flatMap(\.windows)
  }

  private static func suppressInputAssistant(in view: UIView) {
    let className = NSStringFromClass(type(of: view))
    let isFlutterTextInput = className.contains("FlutterTextInputView")
    if isFlutterTextInput || view.isFirstResponder {
      let assistant = view.inputAssistantItem
      let hadShortcuts =
        !assistant.leadingBarButtonGroups.isEmpty ||
        !assistant.trailingBarButtonGroups.isEmpty
      assistant.leadingBarButtonGroups = []
      assistant.trailingBarButtonGroups = []
      assistant.allowsHidingShortcuts = true
      if hadShortcuts && view.isFirstResponder {
        view.reloadInputViews()
      }
    }
    for subview in view.subviews {
      suppressInputAssistant(in: subview)
    }
  }

  // Conversion enum iOS → string portable. Évite de hardcoder des
  // entiers Swift dans le code Dart.
  private static func encodePreferredTapAction(
    _ action: UIPencilPreferredAction
  ) -> String {
    switch action {
    case .ignore: return "ignore"
    case .switchEraser: return "switchEraser"
    case .switchPrevious: return "switchPrevious"
    case .showColorPalette: return "showColorPalette"
    case .showInkAttributes: return "showInkAttributes"
    case .showContextualPalette: return "showContextualPalette"
    case .runSystemShortcut: return "runSystemShortcut"
    @unknown default: return "unknown"
    }
  }
}
