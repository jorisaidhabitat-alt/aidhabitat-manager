// Web-only impl du bridge "fenêtre détachée" pour les notes du VAD.
//
// Sur Mac (Safari/Chrome PWA), on veut ouvrir un VRAIE seconde fenêtre
// browser — avec les 3 pastilles rouge/jaune/vert + drag/resize gérés
// par macOS — et pas un modal Flutter dans la même fenêtre. C'est
// `window.open(url, '_blank', 'popup,width=…')` qui produit ce résultat
// (Chrome 115+ et Safari 17+ honorent `popup=yes` et créent une fenêtre
// indépendante avec sa chrome native).
//
// Sur iPad PWA, `window.open` échoue silencieusement (Safari ne supporte
// pas le multi-window pour les PWA installées) ; on retourne `false` et
// l'appelant retombe sur le modal in-app. La détection iPad-vs-Mac se
// fait via `navigator.maxTouchPoints` car l'user-agent iPadOS spoofe Mac.
//
// IPC entre les deux fenêtres :
//   - texte tapé (live) : BroadcastChannel('aidhabitat-note-ipc')
//     → la fenêtre principale écoute et persiste en SQLite (debounced)
//   - taille / origine reportée : localStorage clés `aidhabitat-note-frame.*`
//     → relue par la fenêtre principale au prochain open pour restituer
//       la même taille/position
//
// SQLite : les deux fenêtres partagent IndexedDB (même origin), donc
// elles voient la même base. Le polling toutes les 1 s côté
// NoteWindowScreen suffit à propager les écritures.

// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

const _kIpcChannelName = 'aidhabitat-note-ipc';
const _kFrameStoragePrefix = 'aidhabitat-note-frame';

/// Clé localStorage utilisée par la fenêtre parent pour transmettre
/// `apiBaseUrl` + `appSessionToken` à la popup AVANT son boot.
/// Chrome / Firefox / Safari macOS partagent localStorage entre
/// fenêtres de même origine, donc la popup peut lire ces valeurs au
/// premier `main()` puis les effacer (one-shot, valeur jetable).
///
/// Demande audit 2026-05-04 : avant ce mécanisme, la popup mode
/// `drawing` bootait avec un AppConfig vide → tout appel API échouait
/// en 401 silencieux. URL params auraient exposé le token dans
/// l'history du browser, donc localStorage est plus propre.
const String kPopupBootstrapStorageKey = 'aidhabitat-popup-bootstrap';

/// Détecte si on est dans un navigateur desktop (Mac/PC) ET PAS dans
/// une PWA iPad (qui spoofe l'user-agent Mac mais a `maxTouchPoints > 1`).
/// Sur tablette/téléphone tactile, on retombe sur le modal in-app
/// (cf. `_openNoteModalFallback` côté `visit_report_screen.dart`).
bool isDesktopBrowser() {
  try {
    final nav = html.window.navigator;
    final touchPoints = nav.maxTouchPoints ?? 0;
    // iPad : 5+ touch points. iPhone : idem. Mac : 0 ou 1 (trackpad
    // multi-finger ne compte pas comme touchscreen).
    if (touchPoints > 1) return false;
    return true;
  } catch (_) {
    return false;
  }
}

/// Tente d'ouvrir le NoteWindowScreen dans une nouvelle fenêtre browser.
/// Renvoie `true` si la fenêtre a bien été créée, `false` sinon (popup
/// bloqué, plateforme non supportée…). L'appelant doit retomber sur le
/// modal in-app si le retour est false.
///
/// Le payload est encodé dans l'URL via query params — la nouvelle
/// fenêtre lit `Uri.base.queryParameters` au boot et branche sur
/// `NoteWindowApp` au lieu de l'app principale (cf. `main.dart`).
bool tryOpenNoteWindow({
  required String patientId,
  required String tabKey,
  required String title,
  required String initialText,
  required double defaultWidth,
  required double defaultHeight,
  /// Base URL de l'API (`AppConfig.apiBaseUrl`) — transmis à la popup
  /// pour qu'elle puisse appeler le backend en mode `drawing`.
  required String apiBaseUrl,
  /// Session token de l'utilisateur (`AppConfig.appSessionToken`) —
  /// idem, transmis via localStorage one-shot. Chaîne vide acceptée
  /// (mode anonyme, ne pas appeler l'API).
  required String appSessionToken,
  /// Mode d'édition de la fenêtre détachée :
  ///   - 'text' (défaut) → TextField simple, sync via IPC sur chaque
  ///     keystroke. La fenêtre principale écrit en SQLite.
  ///   - 'drawing' → NotesWidget canvas (toolset advanced + freeform +
  ///     pagination). La 2e fenêtre init databaseFactory + DataService
  ///     pour écrire directement dans l'IndexedDB partagé. Pas d'IPC
  ///     stroke (volume trop élevé). Demande utilisateur 2026-05-04 :
  ///     uniquement pour l'onglet Résumé du relevé de visite.
  String mode = 'text',
}) {
  if (!isDesktopBrowser()) return false;

  // Dépose le bootstrap (apiBaseUrl + token) AVANT d'ouvrir la popup.
  // La popup `main.dart` (branche `kIsWeb && note_window=1`) lira ces
  // valeurs au boot puis effacera la clé. Si plusieurs popups
  // s'ouvrent en parallèle, la dernière écriture gagne — pas critique
  // car les valeurs sont les mêmes (apiBaseUrl + token de l'utilisateur
  // courant).
  try {
    html.window.localStorage[kPopupBootstrapStorageKey] = jsonEncode({
      'apiBaseUrl': apiBaseUrl,
      'appSessionToken': appSessionToken,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  } catch (_) {/* localStorage indisponible : la popup utilisera l'IndexedDB partagé en fallback */}

  // Restitue la dernière taille/position connue (clés par tabKey pour
  // que les notes Médical / Autonomie / Accessibilité gardent chacune
  // leurs préférences).
  final stored = _loadStoredFrame(tabKey);
  final width = stored?.width ?? defaultWidth;
  final height = stored?.height ?? defaultHeight;
  // Si on n'a pas de position mémorisée, on centre vaguement à l'écran
  // — sinon le browser place la popup en (0,0) ce qui chevauche la
  // titlebar macOS et est laid.
  final left = stored?.left ??
      ((html.window.screen?.available.width ?? 1440) - width) / 2;
  final top = stored?.top ??
      ((html.window.screen?.available.height ?? 900) - height) / 2;

  final origin = html.window.location.origin;
  final params = {
    'note_window': '1',
    'patientId': patientId,
    'tabKey': tabKey,
    'title': title,
    // initialText peut être long — on le passe quand même via URL pour
    // éviter une race avec le bootstrap. Encoded via Uri.encodeComponent.
    'initialText': initialText,
    // 'text' (défaut) ou 'drawing' (cf. NoteWindowApp). Lu côté
    // main.dart dans la branche `kIsWeb`.
    'mode': mode,
  };
  final query = params.entries
      .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('&');
  final url = '$origin/?$query';

  // `popup=yes` force une fenêtre détachée (vs un nouvel onglet) —
  // nécessite Chrome 115+ et Safari 17+. Demande utilisateur 2026-05-04 :
  // « ça doit ouvrir une nouvelle session (ex : deux pages google chrome
  // pas deux onglets dans la même session) ».
  //
  // Important : on N'inclut PAS `noopener,noreferrer` dans la features
  // string. Ce ne sont PAS des features `window.open` standards (ce
  // sont des attributs `<a>`) — Chrome récent peut traiter la chaîne
  // comme invalide et basculer en onglet si elles sont présentes.
  // Pour la sécurité « pas d'accès au window.opener », on neutralise
  // après coup avec `win?.opener = null` (cf. plus bas).
  final features = 'popup=yes,'
      'width=${width.round()},'
      'height=${height.round()},'
      'left=${left.round()},'
      'top=${top.round()}';

  // Nom de fenêtre UNIQUE par tabKey + timestamp — sinon Chrome peut
  // réutiliser un onglet/popup déjà existant avec le même nom et
  // basculer dessus au lieu d'en créer un nouveau.
  final windowName = 'aidhabitat-note-${tabKey.replaceAll(RegExp(r"[^A-Za-z0-9]"), "_")}-${DateTime.now().millisecondsSinceEpoch}';
  // ignore: deprecated_member_use
  final win = html.window.open(url, windowName, features);
  // Sécurité : empêche la nouvelle fenêtre de remonter à la principale
  // via `window.opener` (équivalent de `noopener` qui n'est pas
  // supporté en feature). Best-effort : certaines versions de browser
  // l'ignorent silencieusement, sans casser le flow.
  try {
    // ignore: invalid_assignment
    (win as dynamic).opener = null;
  } catch (_) {}
  // `WindowBase` n'est jamais null en pratique — Safari peut toutefois
  // renvoyer un objet "fermé" en cas de popup blocker. On considère que
  // l'ouverture a tenté ; si elle est bloquée, l'utilisateur verra
  // l'icône anti-popup dans la barre du navigateur et débloquera.
  // ignore: unnecessary_null_comparison
  return win != null;
}

/// Sauvegarde la frame courante (taille + origine) dans `localStorage`
/// pour que le prochain `tryOpenNoteWindow` ouvre à la même position.
/// Appelé périodiquement par NoteWindowScreen côté web.
void persistNoteWindowFrame({
  required String tabKey,
  required double left,
  required double top,
  required double width,
  required double height,
}) {
  try {
    final payload = jsonEncode({
      'left': left,
      'top': top,
      'width': width,
      'height': height,
    });
    html.window.localStorage['$_kFrameStoragePrefix.$tabKey'] = payload;
    // Clé "shared" sans tabKey : utilisée comme défaut quand la note
    // d'un nouveau tab s'ouvre pour la 1ère fois.
    html.window.localStorage[_kFrameStoragePrefix] = payload;
  } catch (_) {/* localStorage plein ou désactivé : ignore */}
}

class _StoredFrame {
  final double? left;
  final double? top;
  final double width;
  final double height;
  _StoredFrame({this.left, this.top, required this.width, required this.height});
}

_StoredFrame? _loadStoredFrame(String tabKey) {
  try {
    final raw = html.window.localStorage['$_kFrameStoragePrefix.$tabKey']
        ?? html.window.localStorage[_kFrameStoragePrefix];
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final w = (m['width'] as num?)?.toDouble();
    final h = (m['height'] as num?)?.toDouble();
    if (w == null || h == null) return null;
    return _StoredFrame(
      left: (m['left'] as num?)?.toDouble(),
      top: (m['top'] as num?)?.toDouble(),
      width: w,
      height: h,
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// IPC via BroadcastChannel
// ---------------------------------------------------------------------------
//
// ⚠️ AVERTISSEMENT pour les futurs mainteneurs (humains ou agents IA) :
// Ce channel est partagé entre la fenêtre principale et toutes les popups
// détachées du même origin. Si tu veux tester BroadcastChannel via la
// console DevTools, **N'UTILISE JAMAIS LE NOM `aidhabitat-note-ipc`** —
// sinon ton listener de test reçoit aussi tous les messages Flutter
// internes, et un `postMessage` accidentel peut provoquer une boucle
// d'écho (le handler Flutter peut re-broadcaster sur des messages
// inconnus). Conséquences observées le 2026-05-06 : flood de plusieurs
// centaines de broadcasts en quelques secondes → DDoS Mitigation Vercel
// auto-déclenchée → IP de l'ergo bloquée pendant ~1h sur le projet
// `aid-habitat-app`.
//
// Pour tester : utilise un nom dédié (ex. `'test-debug-channel'`) qui
// n'interfère pas avec Flutter.

html.BroadcastChannel? _channel;

html.BroadcastChannel _ensureChannel() {
  return _channel ??= html.BroadcastChannel(_kIpcChannelName);
}

/// Envoie un message à toutes les autres fenêtres du même origin
/// (broadcast). Utilisé par la fenêtre détachée pour pousser le texte
/// tapé (méthode `liveNote`) vers la fenêtre principale, et inversement.
///
/// Fix audit 2026-05-06 : on sérialise désormais le payload en JSON
/// **string** avant `postMessage`. Avant ça on passait la map Dart
/// directement, ce qui en dart2js sur Mac arrivait côté receveur comme un
/// `JSObject` opaque (pas une Map Dart) → le check `data is! Map` échouait
/// et aucun message n'était propagé. Une string JSON traverse proprement
/// la frontière JS↔Dart sans conversion ambiguë.
void sendNoteIpc({required String method, required Map<String, dynamic> args}) {
  try {
    final payload = jsonEncode({'method': method, 'args': args});
    _ensureChannel().postMessage(payload);
  } catch (_) {/* ignore */}
}

/// S'abonne aux messages IPC. Le callback reçoit method + args. Retourne
/// une `StreamSubscription` que l'appelant doit cancel() au dispose.
///
/// Cf. [sendNoteIpc] pour le rationale du transport JSON string. On parse
/// ici le payload reçu — robuste aux deux variantes (string JSON nouveau
/// format, et Map Dart legacy si une ancienne fenêtre n'a pas encore
/// été reloadée — utile pendant les transitions de déploiement).
StreamSubscription<dynamic> listenNoteIpc(
    void Function(String method, Map<String, dynamic> args) callback) {
  final ch = _ensureChannel();
  return ch.onMessage.listen((event) {
    try {
      final raw = event.data;
      Map? data;
      if (raw is String) {
        // Nouveau format (2026-05-06) : JSON string. Le path standard.
        final decoded = jsonDecode(raw);
        if (decoded is Map) data = decoded;
      } else if (raw is Map) {
        // Legacy : Map Dart envoyée tel quel. Encore utilisé tant que les
        // 2 fenêtres n'ont pas reloadé après le déploiement du fix.
        data = raw;
      }
      // Note : on N'essaie PAS de gérer le cas JSObject (raw n'est ni
      // String ni Map) — c'est précisément ce qui se passait avant et
      // qui causait le bug. Avec la sérialisation JSON forcée côté
      // sendNoteIpc, ce cas ne devrait plus arriver.
      if (data == null) return;
      final method = data['method']?.toString() ?? '';
      final rawArgs = data['args'];
      final args = rawArgs is Map
          ? Map<String, dynamic>.from(
              rawArgs.map((k, v) => MapEntry(k.toString(), v)),
            )
          : <String, dynamic>{};
      callback(method, args);
    } catch (_) {/* ignore message mal formé */}
  });
}

/// Lit les query params de l'URL. Utilisé par main.dart pour décider
/// si on doit booter en mode NoteWindow vs app complète, et par
/// note_window_screen.dart pour récupérer son patientId/tabKey/etc.
Map<String, String> readUrlNoteParams() {
  try {
    return Map<String, String>.from(Uri.base.queryParameters);
  } catch (_) {
    return const {};
  }
}

/// Lit le bootstrap déposé par la fenêtre parent juste avant
/// `window.open` (cf. `tryOpenNoteWindow`). Renvoie `(apiBaseUrl,
/// appSessionToken)` ou `null` si pas de bootstrap (cas standalone
/// ou popup ouverte hors flow ergo).
///
/// La clé est EFFACÉE après lecture — bootstrap one-shot pour ne pas
/// laisser un token dormant dans localStorage si l'utilisateur ferme
/// l'onglet sans utiliser la popup. Si une nouvelle popup s'ouvre,
/// le parent dépose un nouveau bootstrap.
({String apiBaseUrl, String appSessionToken})? consumePopupBootstrap() {
  try {
    final raw = html.window.localStorage[kPopupBootstrapStorageKey];
    if (raw == null || raw.isEmpty) return null;
    html.window.localStorage.remove(kPopupBootstrapStorageKey);
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return (
      apiBaseUrl: (m['apiBaseUrl'] as String?) ?? '',
      appSessionToken: (m['appSessionToken'] as String?) ?? '',
    );
  } catch (_) {
    return null;
  }
}
