import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';

class AccountDialog extends StatefulWidget {
  const AccountDialog({
    super.key,
    required this.currentUser,
    this.onLogout,
    this.onOpenAdmin,
  });

  final LocalAppUser currentUser;

  /// Called when the user taps "Se déconnecter". The dialog pops itself
  /// first, then invokes the callback so navigation can happen safely.
  final Future<void> Function()? onLogout;

  /// Called when the user taps "Gérer les accès". Admin-only shortcut that
  /// navigates to the admin members screen. If null, the button is hidden.
  final VoidCallback? onOpenAdmin;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final AuthService _authService = AuthService();
  final DataService _dataService = DataService();
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _nextPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _isBootstrapPasswordActive = false;
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isUploadingPhoto = false;
  String? _error;
  String? _photoError;
  late String _photoUrl;

  @override
  void initState() {
    super.initState();
    _photoUrl = widget.currentUser.profilePhotoUrl;
    _loadState();
  }

  Future<void> _pickAndUploadPhoto() async {
    setState(() {
      _photoError = null;
      _isUploadingPhoto = true;
    });

    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        imageQuality: 85,
      );
      if (picked == null) {
        setState(() => _isUploadingPhoto = false);
        return;
      }

      final photoUrl = await _dataService.uploadProfilePhoto(File(picked.path));
      if (!mounted) return;
      setState(() {
        _photoUrl = photoUrl;
        _isUploadingPhoto = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _photoError = 'Envoi impossible : $err';
        _isUploadingPhoto = false;
      });
    }
  }

  String _initials() {
    final name = widget.currentUser.displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
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
                  // ---- Photo de profil (centrée en haut) ----
                  Center(
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            Container(
                              width: 88,
                              height: 88,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFFF3F0F5),
                                image: _photoUrl.isNotEmpty
                                    ? DecorationImage(
                                        image: NetworkImage(_photoUrl),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: _photoUrl.isNotEmpty
                                  ? null
                                  : Center(
                                      child: Text(
                                        _initials(),
                                        style: const TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF554A63),
                                        ),
                                      ),
                                    ),
                            ),
                            Positioned(
                              right: -4,
                              bottom: -4,
                              child: Material(
                                color: const Color(0xFF907CA1),
                                shape: const CircleBorder(),
                                elevation: 2,
                                child: InkWell(
                                  onTap: _isUploadingPhoto
                                      ? null
                                      : _pickAndUploadPhoto,
                                  customBorder: const CircleBorder(),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: _isUploadingPhoto
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(
                                            LucideIcons.camera,
                                            size: 14,
                                            color: Colors.white,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed:
                              _isUploadingPhoto ? null : _pickAndUploadPhoto,
                          child: Text(
                            _photoUrl.isEmpty
                                ? 'Ajouter une photo'
                                : 'Changer la photo',
                            style: const TextStyle(
                              color: Color(0xFF907CA1),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_photoError != null)
                          Text(
                            _photoError!,
                            style: const TextStyle(
                              color: Color(0xFFB91C1C),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 18),
                  // Quick actions: Admin access (if admin) + Logout
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (widget.onOpenAdmin != null)
                        OutlinedButton.icon(
                          onPressed: _isSubmitting
                              ? null
                              : () {
                                  Navigator.of(context).pop();
                                  widget.onOpenAdmin!();
                                },
                          icon: const Icon(LucideIcons.shieldCheck, size: 16),
                          label: const Text('Gérer les accès'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF334155),
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                          ),
                        ),
                      if (widget.onLogout != null)
                        OutlinedButton.icon(
                          onPressed: _isSubmitting
                              ? null
                              : () async {
                                  Navigator.of(context).pop();
                                  await widget.onLogout!();
                                },
                          icon: const Icon(LucideIcons.logOut, size: 16),
                          label: const Text('Se déconnecter'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFB91C1C),
                            side: const BorderSide(color: Color(0xFFFCA5A5)),
                          ),
                        ),
                    ],
                  ),
                  if (_isBootstrapPasswordActive) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(18),
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
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    );
  }
}
