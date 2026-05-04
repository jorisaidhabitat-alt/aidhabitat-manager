import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service Dart qui écoute le double-tap Apple Pencil 2 / Pencil Pro
/// et expose un Stream que les widgets de prise de notes peuvent
/// consommer pour switcher l'outil courant vers la gomme.
///
/// ╭───────────────────────────────────────────────────────────────╮
/// │ DISPONIBILITÉ                                                  │
/// ╰───────────────────────────────────────────────────────────────╯
///
/// - **iOS natif** (Flutter build ios via TestFlight/App Store) : actif.
///   Reçoit les events depuis `PencilDoubleTapPlugin.swift`.
/// - **Web / PWA** : no-op silencieux. Apple ne forwarde pas le double-tap
///   du Pencil à Safari/WebKit, donc le service ne reçoit jamais d'event.
///   `start()` retourne sans erreur, le Stream reste vide.
/// - **Android / macOS / Linux / Windows** : no-op (les autres stylets
///   n'ont pas de geste équivalent côté hardware).
///
/// ╭───────────────────────────────────────────────────────────────╮
/// │ USAGE                                                          │
/// ╰───────────────────────────────────────────────────────────────╯
///
/// 1. Au boot de l'app (ex: dans `main()` ou un widget root) :
///
///    ```dart
///    PencilInteractionService.instance.start();
///    ```
///
/// 2. Dans n'importe quel widget de prise de notes (notes_widget.dart,
///    plan_canvas.dart, le PDF annotator de documents_screen.dart) :
///
///    ```dart
///    @override
///    void initState() {
///      super.initState();
///      _doubleTapSub = PencilInteractionService.instance.onDoubleTap.listen((_) {
///        if (mounted) {
///          setState(() => _currentTool = Tool.eraser);
///        }
///      });
///    }
///
///    @override
///    void dispose() {
///      _doubleTapSub?.cancel();
///      super.dispose();
///    }
///    ```
///
/// Le service est un singleton — `instance` rend le même objet partout.
/// Plusieurs widgets peuvent écouter en même temps, chacun reçoit chaque
/// double-tap (broadcast stream).
class PencilInteractionService {
  PencilInteractionService._();

  static final PencilInteractionService instance =
      PencilInteractionService._();

  /// Channel name MUST match `PencilDoubleTapPlugin.channelName` côté Swift.
  static const _channel = MethodChannel('aidhabitat/pencil_interaction');

  /// Broadcast stream — supporte plusieurs listeners simultanés (utile
  /// quand plusieurs zones de notes coexistent à l'écran : panneau
  /// lateral + tab bottom + dialog modal d'annotation PDF).
  final _doubleTapController = StreamController<PencilDoubleTapEvent>.broadcast();

  /// Stream que les widgets écoutent pour réagir au double-tap.
  Stream<PencilDoubleTapEvent> get onDoubleTap =>
      _doubleTapController.stream;

  bool _started = false;

  /// Démarre l'écoute. Idempotent — appeler plusieurs fois est sans effet.
  /// Sur Web/Android/desktop, retourne immédiatement (no-op).
  void start() {
    if (_started) return;
    _started = true;

    // Plateformes hors iOS : on ne branche même pas le handler. La
    // MethodChannel resterait silencieuse de toute façon, mais évite
    // un warning console "no implementation found" sur Android.
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'doubleTap') return null;
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      final preferredAction = args?['preferredAction']?.toString() ?? 'unknown';
      _doubleTapController.add(
        PencilDoubleTapEvent(preferredAction: preferredAction),
      );
      return null;
    });
  }

  /// Lit la préférence iOS configurée par l'utilisateur dans Réglages
  /// → Apple Pencil → Double-tap. Renvoie l'une des valeurs documentées
  /// dans [PencilPreferredAction], ou null si non disponible (Web,
  /// Android, plugin pas encore activé côté natif).
  ///
  /// Pour la v1, on n'utilise pas cette préférence — on force toujours
  /// le switch vers la gomme. Mais l'API est exposée pour préparer
  /// d'éventuels modes "respect des prefs système" plus tard.
  Future<String?> getPreferredTapAction() async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      final result = await _channel.invokeMethod<String>('getPreferredTapAction');
      return result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Plugin pas encore activé côté AppDelegate.swift — silencieux.
      return null;
    }
  }
}

/// Payload émis par [PencilInteractionService.onDoubleTap].
class PencilDoubleTapEvent {
  const PencilDoubleTapEvent({required this.preferredAction});

  /// Préférence système iOS à l'instant du tap, parmi les valeurs de
  /// [PencilPreferredAction]. Permet aux consumers de respecter ou
  /// outrepasser la prefs utilisateur si besoin. Pour v1, on ignore
  /// et on force la gomme dans tous les cas (demande utilisateur).
  final String preferredAction;
}

/// Constantes des valeurs possibles pour `preferredAction`. Miroir de
/// l'enum `UIPencilInteraction.PreferredTapAction` côté Swift.
abstract class PencilPreferredAction {
  static const ignore = 'ignore';
  static const switchEraser = 'switchEraser';
  static const switchPrevious = 'switchPrevious';
  static const showColorPalette = 'showColorPalette';
  static const showInkAttributes = 'showInkAttributes';
  static const runSystemShortcut = 'runSystemShortcut';
  static const unknown = 'unknown';
}
