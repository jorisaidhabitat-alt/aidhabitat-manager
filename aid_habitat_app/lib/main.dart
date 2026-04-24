import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'models/types.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'screens/note_window_screen.dart';
import 'services/auth_service.dart';
import 'services/connectivity_service.dart';
import 'services/data_service.dart';
import 'services/sync_engine.dart';
// Desktop-only : charge `desktop_multi_window` uniquement sur une
// plateforme qui le supporte. Sur web, un stub vide est importé à la
// place pour que la compilation passe.
import 'services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

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
    runApp(NoteWindowApp(
      windowId: windowId,
      patientId: payload['patientId'] as String,
      tabKey: payload['tabKey'] as String,
      title: payload['title'] as String? ?? 'Note',
      initialText: payload['initialText'] as String? ?? '',
    ));
    return;
  }

  // Run each bootstrap step with a timeout + try/catch. On web, any
  // step could hang silently (sqflite shared worker, a slow HTTP call,
  // a connectivity plugin quirk). Without these guards, a single hung
  // await keeps runApp() from ever being called → the user sees a
  // permanent blank page with no error. With them, the app always
  // reaches runApp and the offline-first DataService can paper over
  // whatever failed.
  Future<void> bootStep(String name, Future<void> future,
      {Duration timeout = const Duration(seconds: 8)}) async {
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
      'purgeStaleSyncOperations', DataService().purgeStaleSyncOperations());
  await bootStep('AuthService.initialize', AuthService().initialize());
  // Restore any Express API session token persisted from a previous login
  // before making remote calls.
  await bootStep(
      'AuthService.restoreRemoteSession', AuthService().restoreRemoteSession());
  // 401 / network failures here are normal (fresh device, offline, etc.);
  // the refresh is best-effort.
  await bootStep(
      'refreshLocalAuthStateFromRemote',
      DataService().refreshLocalAuthStateFromRemote(),
      timeout: const Duration(seconds: 5));
  await bootStep(
      'ConnectivityService.initialize', ConnectivityService().initialize());
  // Connecte le ConnectivityService au SyncEngine : quand la connexion
  // revient, le SyncEngine lance automatiquement un push des opérations
  // en attente (notes, documents, dossiers…) vers NocoDB.
  ConnectivityService().bindSyncEngine(SyncEngine());
  await bootStep(
      'initializeDateFormatting', initializeDateFormatting('fr_FR', null));

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Aid'Habitat Manager",
      debugShowCheckedModeBanner: false,
      // Localisation française — nécessaire pour que showDatePicker soit
      // en français dans l'onglet Bénéficiaire (champ date de naissance).
      locale: const Locale('fr', 'FR'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('fr', 'FR'),
        Locale('en', 'US'),
      ],
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF7F7FA), // Slate-50
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C6DAA),
          primary: const Color(0xFF7C6DAA),
          secondary: const Color(0xFFC5D2D8), // Accent color
          surface: Colors.white,
          background: const Color(0xFFF7F7FA),
        ),
        textTheme: GoogleFonts.interTextTheme(),
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
        useMaterial3: true,
      ),
      home: const AuthRoot(),
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

  @override
  void initState() {
    super.initState();
    _restoreSession();
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
      await _authService.restoreRemoteSession()
          .timeout(const Duration(seconds: 8));
      // ignore: avoid_print
      print('[auth-root] getCurrentUser…');
      final user = await _authService.getCurrentUser()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _currentUser = user;
        _isLoading = false;
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
                const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
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
        onLoggedIn: (user) {
          setState(() {
            _currentUser = user;
          });
        },
      );
    }

    return MainScreen(currentUser: _currentUser!, onLogout: _handleLogout);
  }
}
