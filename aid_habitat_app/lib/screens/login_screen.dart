import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/auth_service.dart';

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
  bool _isBootstrapPasswordActive = false;
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
    final isBootstrapPasswordActive = selectedEmail == null
        ? false
        : await _authService.isBootstrapPasswordActiveForEmail(selectedEmail);
    if (!mounted) return;
    setState(() {
      _users = users;
      _selectedEmail = selectedEmail;
      _isBootstrapPasswordActive = isBootstrapPasswordActive;
      _isLoading = false;
    });
  }

  Future<void> _handleAccountSelection(String? email) async {
    if (email == null) return;
    final isBootstrapPasswordActive = await _authService
        .isBootstrapPasswordActiveForEmail(email);
    if (!mounted) return;
    setState(() {
      _selectedEmail = email;
      _isBootstrapPasswordActive = isBootstrapPasswordActive;
    });
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

    widget.onLoggedIn(result.user!);
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
                border: Border.all(color: const Color(0xFFE2E8F0)),
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
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF907CA1,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            LucideIcons.lock,
                            color: Color(0xFF907CA1),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          "Connexion locale",
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Accès bureau Flutter hors ligne. Les comptes sont lus sur ce poste.",
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            height: 1.4,
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
                        if (_isBootstrapPasswordActive) ...[
                          const SizedBox(height: 12),
                          Text(
                            "Mot de passe initial du poste: ${AuthService.bootstrapPassword}",
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                            ),
                          ),
                        ],
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
                              backgroundColor: const Color(0xFF907CA1),
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
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFF907CA1), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    );
  }
}
