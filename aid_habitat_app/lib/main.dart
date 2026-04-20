import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
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
  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
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

  await DataService().initialize();
  // Drop stale sync operations that pre-date the current app version —
  // otherwise their frozen payloads would be pushed to NocoDB at startup
  // and overwrite fresh remote data with obsolete values.
  await DataService().purgeStaleSyncOperations();
  await AuthService().initialize();
  // Restore any Express API session token persisted from a previous login
  // before making remote calls.
  await AuthService().restoreRemoteSession();
  await DataService().refreshLocalAuthStateFromRemote();
  await ConnectivityService().initialize();
  // Connecte le ConnectivityService au SyncEngine : quand la connexion
  // revient, le SyncEngine lance automatiquement un push des opérations
  // en attente (notes, documents, dossiers…) vers NocoDB.
  ConnectivityService().bindSyncEngine(SyncEngine());
  await initializeDateFormatting('fr_FR', null);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Aid'Habitat Manager",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8FAFC), // Slate-50
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF907CA1),
          primary: const Color(0xFF907CA1),
          secondary: const Color(0xFFC5D2D8), // Accent color
          surface: Colors.white,
          background: const Color(0xFFF8FAFC),
        ),
        textTheme: GoogleFonts.interTextTheme(),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
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

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final user = await _authService.getCurrentUser();
    if (!mounted) return;
    setState(() {
      _currentUser = user;
      _isLoading = false;
    });
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
