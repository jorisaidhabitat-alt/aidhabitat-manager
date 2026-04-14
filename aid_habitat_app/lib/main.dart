import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'models/types.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/auth_service.dart';
import 'services/data_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DataService().initialize();
  await AuthService().initialize();
  await DataService().refreshLocalAuthStateFromRemote();
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
