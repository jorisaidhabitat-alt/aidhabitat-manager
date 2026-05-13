import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/account_dialog.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';

// Local profile photo manager — stores the picked image on disk at
// {app_docs}/profile_photos/{userId}.jpg. No DB involvement.
class ProfilePhotoStore {
  static Future<File?> photoFile(String userId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'profile_photos', '$userId.jpg'));
      if (await file.exists()) return file;
    } catch (_) {/* fall through */}
    return null;
  }

  static Future<File> savePhoto(String userId, File source) async {
    final dir = await getApplicationDocumentsDirectory();
    final targetDir = Directory(p.join(dir.path, 'profile_photos'));
    await targetDir.create(recursive: true);
    final target = File(p.join(targetDir.path, '$userId.jpg'));
    await source.copy(target.path);
    return target;
  }

  static Future<void> clearPhoto(String userId) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'profile_photos', '$userId.jpg'));
    if (await file.exists()) await file.delete();
  }
}

class SettingsScreen extends StatefulWidget {
  final LocalAppUser user;
  final Future<void> Function() onLogout;

  const SettingsScreen({
    super.key,
    required this.user,
    required this.onLogout,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ImagePicker _imagePicker = ImagePicker();

  File? _photoFile;
  bool _isUploading = false;
  String? _feedback;
  bool _feedbackIsError = false;

  // Version chargée dynamiquement depuis le bundle (CFBundleShortVersionString
  // côté iOS, versionName Android, etc.). Vide tant que la résolution
  // package_info_plus n'a pas répondu.
  String _appVersion = '';
  String _appBuildNumber = '';

  // URLs externes pour l'écran "À propos". Apple App Store Review
  // demande une politique de confidentialité accessible publiquement
  // (Guideline 5.1.1) — la fiche App Store Connect doit aussi pointer
  // vers la même URL.
  static const String _privacyPolicyUrl =
      'https://aid-habitat.fr/privacy-policy';
  static const String _supportEmail = 'support@aid-habitat.fr';
  static const String _websiteUrl = 'https://aid-habitat.fr';

  @override
  void initState() {
    super.initState();
    _loadPhoto();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        _appBuildNumber = info.buildNumber;
      });
    } catch (_) {
      // Pas critique : on laisse les champs vides plutôt que crasher.
    }
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        setState(() {
          _feedback = 'Impossible d\'ouvrir le lien : $url';
          _feedbackIsError = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedback = 'Erreur d\'ouverture : $e';
        _feedbackIsError = true;
      });
    }
  }

  Future<void> _loadPhoto() async {
    final file = await ProfilePhotoStore.photoFile(widget.user.id);
    if (!mounted) return;
    setState(() => _photoFile = file);
  }

  Future<void> _pickPhoto() async {
    setState(() {
      _feedback = null;
      _isUploading = true;
    });
    try {
      final xfile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
      if (xfile == null) {
        setState(() => _isUploading = false);
        return;
      }
      final saved =
          await ProfilePhotoStore.savePhoto(widget.user.id, File(xfile.path));
      if (!mounted) return;
      setState(() {
        _photoFile = saved;
        _feedback = 'Photo de profil mise à jour.';
        _feedbackIsError = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _feedback = 'Enregistrement impossible: $err';
        _feedbackIsError = true;
      });
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _openPasswordDialog() async {
    final didChange = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AccountDialog(currentUser: widget.user),
    );
    if (didChange == true && mounted) {
      setState(() {
        _feedback = 'Mot de passe local mis à jour.';
        _feedbackIsError = false;
      });
    }
  }

  String get _initials {
    final parts = widget.user.displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'AH';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String get _roleLabel {
    switch (widget.user.role) {
      case LocalUserRole.admin:
        return 'Administrateur';
      case LocalUserRole.ergo:
        return 'Ergothérapeute';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paramètres du compte',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 24),
            _buildProfileCard(),
            const SizedBox(height: 16),
            _buildPhotoHint(),
            if (_feedback != null) ...[
              const SizedBox(height: 16),
              _buildFeedback(),
            ],
            const SizedBox(height: 16),
            _buildPasswordCard(),
            const SizedBox(height: 32),
            _buildAboutCard(),
          ],
        ),
      ),
    );
  }

  /// Carte « À propos » : version, lien politique de confidentialité,
  /// support, site web. Cherchée par les reviewers App Store Apple
  /// (Guideline 5.1.1 — Privacy / 5.1.2 — Data Use and Sharing).
  /// Cf. https://developer.apple.com/app-store/review/guidelines/#privacy
  Widget _buildAboutCard() {
    final versionLabel = _appVersion.isEmpty
        ? '—'
        : (_appBuildNumber.isEmpty
            ? _appVersion
            : '$_appVersion ($_appBuildNumber)');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.shade100,
                ),
                child: Icon(
                  LucideIcons.info,
                  size: 18,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  'À propos',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildAboutRow(
            label: 'Version',
            value: versionLabel,
            icon: LucideIcons.tag,
          ),
          const Divider(height: 24),
          _buildAboutRow(
            label: 'Politique de confidentialité',
            value: _privacyPolicyUrl,
            icon: LucideIcons.shield,
            onTap: () => _openExternalUrl(_privacyPolicyUrl),
            isLink: true,
          ),
          const Divider(height: 24),
          _buildAboutRow(
            label: 'Support',
            value: _supportEmail,
            icon: LucideIcons.mail,
            onTap: () => _openExternalUrl('mailto:$_supportEmail'),
            isLink: true,
          ),
          const Divider(height: 24),
          _buildAboutRow(
            label: 'Site web',
            value: _websiteUrl,
            icon: LucideIcons.globe,
            onTap: () => _openExternalUrl(_websiteUrl),
            isLink: true,
          ),
          const SizedBox(height: 16),
          Text(
            'Aid\'Habitat — application métier d\'aide à l\'évaluation '
            'd\'accessibilité du logement pour ergothérapeutes.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '© 2026 Aid\'Habitat. Tous droits réservés.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutRow({
    required String label,
    required String value,
    required IconData icon,
    VoidCallback? onTap,
    bool isLink = false,
  }) {
    final row = Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade600),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  color: isLink ? const Color(0xFF8B6FA0) : Colors.black87,
                  decoration: isLink ? TextDecoration.underline : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (onTap != null)
          Icon(LucideIcons.externalLink,
              size: 14, color: Colors.grey.shade400),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildAvatar(),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.user.displayName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.user.email,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(LucideIcons.shield,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 6),
                    Text(
                      _roleLabel.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade600,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(LucideIcons.logOut, size: 16),
            label: const Text('Se déconnecter'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(50),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF8B6FA0),
          ),
          clipBehavior: Clip.antiAlias,
          child: _photoFile != null
              ? Image.file(
                  _photoFile!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => _initialsLabel(),
                )
              : _initialsLabel(),
        ),
        Positioned(
          right: -4,
          bottom: -4,
          child: InkWell(
            onTap: _isUploading ? null : _pickPhoto,
            borderRadius: BorderRadius.circular(50),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black87,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _isUploading
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(LucideIcons.camera,
                      size: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _initialsLabel() {
    return Center(
      child: Text(
        _initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildPhotoHint() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F6FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Photo de profil',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Choisissez une image pour personnaliser votre compte. Elle sera réutilisée dans la barre latérale et dans l\'espace paramètres.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedback() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _feedbackIsError
            ? Colors.red.shade50
            : Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _feedback!,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: _feedbackIsError
              ? Colors.red.shade700
              : Colors.green.shade700,
        ),
      ),
    );
  }

  Widget _buildPasswordCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey.shade100,
            ),
            child: Icon(LucideIcons.key,
                size: 18, color: Colors.grey.shade700),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mot de passe',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Changer votre mot de passe local.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: _openPasswordDialog,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(50),
              ),
            ),
            child: const Text('Modifier'),
          ),
        ],
      ),
    );
  }
}
