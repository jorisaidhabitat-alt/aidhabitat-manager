import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'components/brand_colors.dart';
import 'components/soft_transitions.dart';
import 'models/types.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'screens/note_window_screen.dart';
import 'services/app_config.dart';
import 'services/auth_service.dart';
import 'services/connectivity_service.dart';
import 'services/data_service.dart';
import 'services/file_drop_listener.dart';
import 'services/references_service.dart';
import 'services/sync_engine.dart';
// Web-only helpers pour la fenêtre détachée des notes (cf.
// `note_window_web.dart` pour le rationale). Sur natif, le stub fait
// passer la compilation.
import 'services/note_window_web_stub.dart'
    if (dart.library.html) 'services/note_window_web.dart'
    as note_window_web;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Handlers d'erreurs globaux (fix 2026-05-15) ─────────────────
  // Avant : les uncaught errors arrivaient dans la console web minifiée
  // sans message ni stack lisible → impossible de diagnostiquer (« Uncaught
  // Error\n  at Object.d (main.dart.js:4239:20)\n  ... »).
  //
  // Maintenant : on intercepte 2 sources :
  //  1. `FlutterError.onError`     → erreurs du framework (build/paint/
  //     gesture/setState). Inclut le widget responsable + library.
  //  2. `PlatformDispatcher.instance.onError` → erreurs async non capturées
  //     (Future qui rejette sans catchError, listener Stream qui throw).
  //
  // Les deux loguent en clair avec le `exception.toString()` Dart (qui
  // préserve le message même en build minifié) + la stack. Retournent
  // `true` pour signaler que l'erreur a été « handled » et ne doit pas
  // remonter au navigateur en uncaught.
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      debugPrint('[flutter-error] ${details.exception}');
      if (details.library != null) debugPrint('  library: ${details.library}');
      if (details.context != null) debugPrint('  context: ${details.context}');
      debugPrint(details.stack?.toString());
    } else {
      debugPrint('[flutter-error] ${details.exception.runtimeType}');
    }
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[async-error] $error');
      // ignore: avoid_print
      print(stack);
    } else {
      // ignore: avoid_print
      print('[async-error] ${error.runtimeType}');
    }
    return true; // marqué comme handled → pas de propagation uncaught
  };

  // Sur web : bascule sqflite sur le backend WASM+IndexedDB pour que les
  // appels existants (`sqflite.openDatabase`, `Database.query`, …)
  // fonctionnent tels quels dans le navigateur.
  //
  // `databaseFactoryFfiWebNoWebWorker` garde tout le SQL sur le thread
  // principal (pas de SharedWorker). Un peu plus lent mais évite les
  // incompats de version entre `sqflite_sw.js` pré-généré et la build
  // Flutter en cours, qui produisaient un init silencieux et bloquaient
  // `LocalDatabase.instance.database` pour toujours (page blanche sur
  // la PWA Vercel).
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWebNoWebWorker;
  }

  // Secondary OS windows (opened via DesktopMultiWindow.createWindow) start
  // the same binary with args = ['multi_window', <windowId>, <payload>]. We
  // branch early and render the dedicated Note editor window — WITHOUT
  // initializing the main DataService / AuthService / sync engine (they
  // are already running in the main process; the note window just reads
  // and writes the shared SQLite file).
  //
  // Ce chemin ne s'exécute jamais sur web (le navigateur ne peut pas
  // relancer le binaire avec des args).
  if (!kIsWeb && args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.parse(args[1]);
    final payload = jsonDecode(args[2]) as Map<String, dynamic>;
    await initializeDateFormatting('fr_FR', null);
    runApp(
      NoteWindowApp(
        windowId: windowId,
        patientId: payload['patientId'] as String,
        tabKey: payload['tabKey'] as String,
        title: payload['title'] as String? ?? 'Note',
        initialText: payload['initialText'] as String? ?? '',
        // 'text' (défaut) ou 'drawing' (cf. NoteWindowApp).
        mode: payload['mode'] as String? ?? 'text',
      ),
    );
    return;
  }

  // Web equivalent : quand on ouvre la fenêtre détachée via
  // `window.open(url, '_blank', 'popup,...')` (cf. note_window_web.dart),
  // le navigateur lance la même app à l'URL passée. On détecte la
  // query param `note_window=1` et on branche sur NoteWindowApp AVANT
  // d'initialiser la stack complète (DataService / AuthService) — le
  // SQLite (IndexedDB) est partagé entre les fenêtres du même origin,
  // donc la NoteWindowScreen y a accès directement sans repasser par
  // un AuthService duplicate.
  if (kIsWeb) {
    final params = note_window_web.readUrlNoteParams();
    if (params['note_window'] == '1') {
      final mode = params['mode'] ?? 'text';
      // Boot léger pour la fenêtre détachée :
      //   - mode='text' (défaut) : aucune init SQLite, persistance via
      //     IPC BroadcastChannel → la fenêtre principale fait le write
      //     SQLite + enqueue NocoDB. La 2e fenêtre n'est qu'un éditeur
      //     de texte qui broadcast chaque keystroke. Pas de SyncEngine
      //     duplicate, pas de double push NocoDB.
      //
      //   - mode='drawing' (Résumé canvas — demande utilisateur
      //     2026-05-04) : init databaseFactory pour que NotesWidget
      //     puisse appeler DataService.fetch/saveNoteDrawingJson
      //     directement. IndexedDB est partagé même origin → la
      //     fenêtre principale voit les changements au prochain reload
      //     du dossier. PAS d'init SyncEngine ici (la fenêtre
      //     principale s'occupe du push NocoDB au switch d'onglet).
      if (mode == 'drawing') {
        databaseFactory = databaseFactoryFfiWebNoWebWorker;
      }
      // Bootstrap auth déposé par la fenêtre parent (one-shot
      // localStorage) — fix audit 2026-05-04 : sans ça, la popup
      // mode `drawing` bootait avec AppConfig vide et tout call API
      // échouait en 401 silencieux (Safari iPad PWA isole parfois
      // IndexedDB entre fenêtres, donc on ne peut pas se reposer
      // dessus). La clé est consommée (effacée) à la lecture.
      final bootstrap = note_window_web.consumePopupBootstrap();
      if (bootstrap != null) {
        if (bootstrap.apiBaseUrl.isNotEmpty) {
          AppConfig.setApiBaseUrl(bootstrap.apiBaseUrl);
        }
        if (bootstrap.appSessionToken.isNotEmpty) {
          AppConfig.setAppSessionToken(bootstrap.appSessionToken);
        }
      }
      await initializeDateFormatting('fr_FR', null);
      runApp(
        NoteWindowApp(
          // windowId : 0 sur web — on n'utilise pas DesktopMultiWindow.
          // L'IPC passe par BroadcastChannel, sans besoin d'identifiant.
          windowId: 0,
          patientId: params['patientId'] ?? '',
          tabKey: params['tabKey'] ?? '',
          title: params['title'] ?? 'Note',
          initialText: params['initialText'] ?? '',
          mode: mode,
        ),
      );
      return;
    }
  }

  // Run each bootstrap step with a timeout + try/catch. On web, any
  // step could hang silently (sqflite shared worker, a slow HTTP call,
  // a connectivity plugin quirk). Without these guards, a single hung
  // await keeps runApp() from ever being called → the user sees a
  // permanent blank page with no error. With them, the app always
  // reaches runApp and the offline-first DataService can paper over
  // whatever failed.
  Future<void> bootStep(
    String name,
    Future<void> future, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      await future.timeout(timeout);
    } catch (e, st) {
      // ignore: avoid_print
      print('[bootstrap] step "$name" failed or timed out: $e');
      // ignore: avoid_print
      print(st);
    }
  }

  await bootStep('DataService.initialize', DataService().initialize());
  // Drop stale sync operations that pre-date the current app version —
  // otherwise their frozen payloads would be pushed to NocoDB at startup
  // and overwrite fresh remote data with obsolete values.
  await bootStep(
    'purgeStaleSyncOperations',
    DataService().purgeStaleSyncOperations(),
  );
  await bootStep('AuthService.initialize', AuthService().initialize());
  // Restore any Express API session token persisted from a previous login
  // before making remote calls.
  await bootStep(
    'AuthService.restoreRemoteSession',
    AuthService().restoreRemoteSession(),
  );
  // 401 / network failures here are normal (fresh device, offline, etc.);
  // the refresh is best-effort.
  await bootStep(
    'refreshLocalAuthStateFromRemote',
    DataService().refreshLocalAuthStateFromRemote(),
    timeout: const Duration(seconds: 5),
  );
  await bootStep(
    'ConnectivityService.initialize',
    ConnectivityService().initialize(),
  );
  // Lance le fetch des références (communes, EPCIs, barèmes ANAH) tout
  // de suite — sans `await`, pour ne pas bloquer le boot. Le service
  // hydrate d'abord depuis SQLite (instantané sur les sessions
  // suivantes), puis refresh réseau en arrière-plan. Ça démarre la
  // requête réseau pendant que `AuthService` finit son chargement,
  // donc à l'ouverture du premier dossier les communes sont déjà là
  // (ou très près d'arriver).
  // ignore: discarded_futures
  ReferencesService().ensureLoaded();
  // Connecte le ConnectivityService au SyncEngine : quand la connexion
  // revient, le SyncEngine lance automatiquement un push des opérations
  // en attente (notes, documents, dossiers…) vers NocoDB.
  ConnectivityService().bindSyncEngine(SyncEngine());
  // Active l'écoute des drops OS → Flutter (web uniquement). Permet à
  // l'ergo de glisser un fichier depuis le Finder Mac vers une section
  // Photos du VAD ou vers l'espace Documents. Sur natif (iPad
  // standalone), le service est un no-op — le file_picker reste la
  // seule voie d'import.
  FileDropListener.instance.activate();
  await bootStep(
    'initializeDateFormatting',
    initializeDateFormatting('fr_FR', null),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.home});

  /// Test seam: production uses [AuthRoot], while widget tests can mount the
  /// app shell without booting SQLite/auth/sync side effects.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "App'Ergo",
      debugShowCheckedModeBanner: false,
      // Localisation française — nécessaire pour que showDatePicker soit
      // en français dans l'onglet Bénéficiaire (champ date de naissance).
      locale: const Locale('fr', 'FR'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('fr', 'FR'), Locale('en', 'US')],
      theme: ThemeData(
        // Refonte 2026-05-13 :
        //  - scaffoldBackground passé à paper #FDFCFB (warm white du
        //    design system, au lieu de slate-50 #F7F7FA)
        //  - primary à mauve-500 #8B6FA0 (au lieu de #7C6DAA)
        scaffoldBackgroundColor: const Color(0xFFFDFCFB), // paper
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandPurple, // mauve-500
          primary: kBrandPurple,
          secondary: const Color(0xFFC5D2D8),
          surface: Colors.white,
        ),
        // ----- Typographie Aid'Habitat (2026-05-13) -----
        // Refonte du design system : Quicksand (500) pour body/labels,
        // Nunito (700) pour tous les titres (display / headline / grands
        // titres serif comme « Bonjour, X. », nom bénéficiaire, heure
        // de visite). Fraunces a été tenté puis retiré sur demande
        // utilisateur 2026-05-13.
        //
        // GoogleFonts.quicksandTextTheme() applique Quicksand sur
        // toutes les variantes (body/label/title), puis on surcharge
        // display/headline pour utiliser Nunito.
        textTheme: _buildAppTextTheme(),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          // Charte "Équilibrée" — coins 16 px (au lieu de 24) pour un
          // équilibre densité/respiration sur les cartes principales.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        // Force white backgrounds on dialogs and dropdown menus —
        // Material 3's tinted surfaceContainer gives them a pink/lavender
        // tint that clashes with the rest of the UI.
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        menuTheme: const MenuThemeData(
          style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(Colors.white),
            surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
        dropdownMenuTheme: const DropdownMenuThemeData(
          menuStyle: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(Colors.white),
            surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        // Transitions "soft" identiques sur toutes les plateformes :
        // fade 220 ms + glissement vertical subtil (8 px). Même ressenti
        // sur macOS, iPadOS web PWA, Android, iOS.
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.iOS: SoftPageTransitionsBuilder(),
            TargetPlatform.android: SoftPageTransitionsBuilder(),
            TargetPlatform.macOS: SoftPageTransitionsBuilder(),
            TargetPlatform.windows: SoftPageTransitionsBuilder(),
            TargetPlatform.linux: SoftPageTransitionsBuilder(),
            TargetPlatform.fuchsia: SoftPageTransitionsBuilder(),
          },
        ),
        useMaterial3: true,
      ),
      home: home ?? const AuthRoot(),
    );
  }
}

class AuthRoot extends StatefulWidget {
  const AuthRoot({super.key});

  @override
  State<AuthRoot> createState() => _AuthRootState();
}

class _AuthRootState extends State<AuthRoot> {
  final AuthService _authService = AuthService();
  LocalAppUser? _currentUser;
  bool _isLoading = true;
  String? _bootError;
  String? _loginNotice;

  /// Écoute les pulls workspace pour rafraîchir le `currentUser`
  /// quand un autre device a modifié son profil (notamment la photo).
  /// Demande utilisateur 2026-05-06 : « j'ai changé la photo de
  /// profil sur l'iPad, ça ne s'est pas actualisé sur le mac, ça
  /// doit être le cas de manière quasi instantané ».
  StreamSubscription<SyncEngineState>? _syncSubscription;
  StreamSubscription<void>? _sessionInvalidatedSubscription;
  DateTime? _lastObservedSyncAt;

  @override
  void initState() {
    super.initState();
    _restoreSession();
    _sessionInvalidatedSubscription = AuthService.sessionInvalidatedStream
        .listen((_) {
          if (!mounted) return;
          setState(() {
            _currentUser = null;
            _loginNotice = AuthService.consumePendingSessionNotice();
          });
        });
    _syncSubscription = SyncEngine().stateStream.listen((state) {
      if (!mounted || _currentUser == null) return;
      final at = state.lastSyncAt;
      if (at == null) return;
      if (_lastObservedSyncAt != null && at == _lastObservedSyncAt) return;
      _lastObservedSyncAt = at;
      // Re-lit l'utilisateur courant depuis SQLite (qui vient d'être
      // mis à jour par `refreshLocalAuthStateFromRemote` chaîné dans
      // refreshWorkspaceFromRemote). Si la photo a changé, MainScreen
      // rebuild avec la nouvelle URL en prop.
      // ignore: discarded_futures
      _refreshCurrentUserAfterPull();
    });
  }

  Future<void> _refreshCurrentUserAfterPull() async {
    try {
      final fresh = await _authService.getCurrentUser();
      if (!mounted || fresh == null) return;
      // Si rien n'a changé, on évite un setState/rebuild inutile.
      final old = _currentUser;
      if (old != null &&
          old.profilePhotoUrl == fresh.profilePhotoUrl &&
          old.pendingProfilePhotoDataUrl == fresh.pendingProfilePhotoDataUrl &&
          old.displayName == fresh.displayName) {
        return;
      }
      setState(() => _currentUser = fresh);
    } catch (_) {
      // best-effort
    }
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    _syncSubscription = null;
    _sessionInvalidatedSubscription?.cancel();
    _sessionInvalidatedSubscription = null;
    super.dispose();
  }

  Future<void> _restoreSession() async {
    // Restaure le token API serveur depuis SQLite AVANT de récupérer l'user,
    // sinon AppConfig.hasRemoteConfig reste false après un redémarrage de
    // l'app et toutes les syncs NocoDB échouent avec "Configuration NocoDB
    // absente" (y compris le relevé à domicile).
    //
    // On borne chaque appel par un timeout : si SQLite plante (sqflite web
    // worker, wasm non chargé, etc.), le spinner disparaît quand même et on
    // montre un écran d'erreur plutôt que de bloquer l'utilisateur sur un
    // loader infini.
    try {
      // ignore: avoid_print
      print('[auth-root] restoreRemoteSession…');
      await _authService.restoreRemoteSession().timeout(
        const Duration(seconds: 8),
      );
      // ignore: avoid_print
      print('[auth-root] getCurrentUser…');
      final user = await _authService.getCurrentUser().timeout(
        const Duration(seconds: 8),
      );
      if (!mounted) return;
      setState(() {
        _currentUser = user;
        _isLoading = false;
        _loginNotice = AuthService.consumePendingSessionNotice();
      });
      // ignore: avoid_print
      print('[auth-root] done. user=${user?.email ?? "(none)"}');
    } catch (e, st) {
      // ignore: avoid_print
      print('[auth-root] FAILED: $e');
      // ignore: avoid_print
      print(st);
      if (!mounted) return;
      setState(() {
        _currentUser = null;
        _isLoading = false;
        _bootError = e.toString();
      });
    }
  }

  Future<void> _handleLogout() async {
    await _authService.signOut();
    if (!mounted) return;
    setState(() {
      _currentUser = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // When SQLite init failed (sqflite web worker hang, wasm not loaded,
    // OPFS disabled, …) we still want the user to see something actionable
    // instead of an infinite spinner. Login will be disabled but the error
    // is explicit so the issue can be reported.
    if (_bootError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  "Impossible d'initialiser le stockage local",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _bootError!,
                  style: const TextStyle(color: Colors.black54),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _bootError = null;
                    });
                    _restoreSession();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Réessayer'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_currentUser == null) {
      return LoginScreen(
        infoMessage: _loginNotice,
        onLoggedIn: (user) {
          setState(() {
            _currentUser = user;
            _loginNotice = null;
          });
        },
      );
    }

    return MainScreen(currentUser: _currentUser!, onLogout: _handleLogout);
  }
}

// =============================================================================
// Typographie globale Aid'Habitat — refonte 2026-05-13
// =============================================================================
//
// 2 polices Google Fonts, chargées à la volée par le package google_fonts :
//
//   - Quicksand (400/500/600/700) → body / labels / boutons / inputs
//     (signature « warm, friendly » du nouveau design system)
//   - Nunito    (700/800)         → titres display / headline + tous les
//     grands titres dans dashboard et relevé de visite (« Bonjour, X. »,
//     nom bénéficiaire, heure de visite, etc.).
//
// Fraunces (serif) a été testé puis retiré sur demande utilisateur
// 2026-05-13 — l'utilisateur préférait Nunito partout.
//
// On part de Quicksand sur toute la baseline (body + label + title),
// puis on override les niveaux display/headline pour basculer en Nunito.
// Les letter-spacing reproduisent ceux du mockup `Refonte.html`
// (-0.025em sur les grands titres, +0.018em sur le body Quicksand).
TextTheme _buildAppTextTheme() {
  final base = ThemeData.light().textTheme;
  // Quicksand sur tout — body / label / title héritent.
  final quicksand = GoogleFonts.quicksandTextTheme(base);

  // Helper Nunito avec letter-spacing négatif (typique des display).
  TextStyle nunito(TextStyle? source, {FontWeight weight = FontWeight.w700}) {
    return GoogleFonts.nunito(
      textStyle: (source ?? const TextStyle()).copyWith(
        fontWeight: weight,
        letterSpacing: -0.5,
        height: 1.1,
      ),
    );
  }

  return quicksand.copyWith(
    displayLarge: nunito(quicksand.displayLarge),
    displayMedium: nunito(quicksand.displayMedium),
    displaySmall: nunito(quicksand.displaySmall),
    headlineLarge: nunito(quicksand.headlineLarge),
    headlineMedium: nunito(quicksand.headlineMedium),
    headlineSmall: nunito(quicksand.headlineSmall),
    // titleLarge garde Quicksand (utilisé partout pour AppBar / cards).
    // bodyLarge / bodyMedium / bodySmall : Quicksand 500.
    // labelLarge / labelMedium / labelSmall : Quicksand 600.
  );
}
