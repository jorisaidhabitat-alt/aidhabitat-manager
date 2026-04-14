import 'package:flutter/material.dart';

import '../models/types.dart';
import '../services/auth_service.dart';

class AccountDialog extends StatefulWidget {
  const AccountDialog({super.key, required this.currentUser});

  final LocalAppUser currentUser;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final AuthService _authService = AuthService();
  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _nextPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _isBootstrapPasswordActive = false;
  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final isBootstrapPasswordActive = await _authService
        .isUsingBootstrapPassword(widget.currentUser.id);
    if (!mounted) return;
    setState(() {
      _isBootstrapPasswordActive = isBootstrapPasswordActive;
      _isLoading = false;
    });
  }

  Future<void> _submit() async {
    if (_nextPasswordController.text != _confirmPasswordController.text) {
      setState(() {
        _error = 'La confirmation ne correspond pas au nouveau mot de passe';
      });
      return;
    }

    setState(() {
      _error = null;
      _isSubmitting = true;
    });

    final result = await _authService.changePassword(
      userId: widget.currentUser.id,
      currentPassword: _currentPasswordController.text,
      nextPassword: _nextPasswordController.text,
    );

    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _isSubmitting = false;
        _error = result.error ?? 'Impossible de mettre à jour le mot de passe';
      });
      return;
    }

    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _nextPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: const Text(
        'Compte local',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 440,
        child: _isLoading
            ? const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.currentUser.displayName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.currentUser.email,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.currentUser.role.label,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  if (_isBootstrapPasswordActive) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFFDE68A)),
                      ),
                      child: const Text(
                        'Le mot de passe initial du poste est encore actif. Remplacez-le avant usage terrain.',
                        style: TextStyle(
                          color: Color(0xFF92400E),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  const Text(
                    'Mot de passe actuel',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _currentPasswordController,
                    obscureText: true,
                    enabled: !_isSubmitting,
                    decoration: _inputDecoration(
                      hintText: 'Saisir le mot de passe actuel',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Nouveau mot de passe',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nextPasswordController,
                    obscureText: true,
                    enabled: !_isSubmitting,
                    decoration: _inputDecoration(
                      hintText: '8 caractères minimum',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Confirmer le mot de passe',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _confirmPasswordController,
                    obscureText: true,
                    enabled: !_isSubmitting,
                    decoration: _inputDecoration(
                      hintText: 'Ressaisir le nouveau mot de passe',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFB91C1C)),
                    ),
                  ],
                ],
              ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
        FilledButton(
          onPressed: _isLoading || _isSubmitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF907CA1),
            foregroundColor: Colors.white,
          ),
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Mettre à jour'),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({required String hintText}) {
    return InputDecoration(
      hintText: hintText,
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
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
