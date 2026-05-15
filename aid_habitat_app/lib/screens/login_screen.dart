import 'package:flutter/material.dart';

import '../models/types.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final ValueChanged<LocalAppUser> onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthService _authService = AuthService();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _error;
  String? _selectedEmail;
  List<LocalAppUser> _users = const [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final users = await _authService.fetchAvailableUsers();
    final selectedEmail = users.isNotEmpty ? users.first.email : null;
    if (!mounted) return;
    setState(() {
      _users = users;
      _selectedEmail = selectedEmail;
      _isLoading = false;
    });
  }

  void _handleAccountSelection(String? email) {
    if (email == null) return;
    setState(() => _selectedEmail = email);
  }

  Future<void> _submit() async {
    if (_selectedEmail == null || _selectedEmail!.isEmpty) {
      setState(() => _error = 'Aucun compte local disponible');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final result = await _authService.signIn(
      email: _selectedEmail!,
      password: _passwordController.text,
    );

    if (!mounted) return;
    if (!result.success || result.user == null) {
      setState(() {
        _isSubmitting = false;
        _error = result.error ?? 'Connexion locale impossible';
      });
      return;
    }

    // Après signIn (session remote établie), rafraîchit depuis NocoDB
    // la liste des users + leurs métadonnées (notamment profilePhotoUrl
    // du membre ergothérapeute) — la photo s'affiche ensuite directement
    // dans la sidebar sans attendre un redémarrage de l'app.
    // Best-effort : si le réseau est indisponible, on garde la valeur
    // SQLite locale et on ignore silencieusement l'erreur.
    try {
      await DataService().refreshLocalAuthStateFromRemote();
    } catch (_) {
      // offline — pas bloquant.
    }
    final refreshed = await _authService.getCurrentUser();
    if (!mounted) return;
    widget.onLoggedIn(refreshed ?? result.user!);
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE4E7EB)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 240,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Demande utilisateur 2026-05-07 : épuration de la
                        // page connexion. Plus d'icône cadenas, plus de
                        // texte de description, plus d'astuce mot de passe
                        // initial. On garde uniquement titre + 2 champs +
                        // bouton.
                        const Text(
                          "Connexion",
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0E1116),
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          "Compte local",
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _selectedEmail,
                          items: _users
                              .map(
                                (user) => DropdownMenuItem(
                                  value: user.email,
                                  child: Text(
                                    "${user.displayName} • ${user.role.label}",
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _isSubmitting
                              ? null
                              : (value) {
                                  _handleAccountSelection(value);
                                },
                          decoration: _inputDecoration(),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          "Mot de passe local",
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          enabled: !_isSubmitting,
                          decoration: _inputDecoration().copyWith(
                            hintText: "Saisir le mot de passe",
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFFECACA),
                              ),
                            ),
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Color(0xFFB91C1C)),
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _isSubmitting ? null : _submit,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF8B6FA0),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: _isSubmitting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text("Ouvrir l'application"),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFFF7F7FA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE4E7EB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE4E7EB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFF8B6FA0), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    );
  }
}
