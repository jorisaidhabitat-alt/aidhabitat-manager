import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/connectivity_service.dart';
import '../services/data_service.dart';
import 'cached_remote_image.dart';

class AccountDialog extends StatefulWidget {
  const AccountDialog({
    super.key,
    required this.currentUser,
    this.onLogout,
  });

  final LocalAppUser currentUser;

  /// Called when the user taps "Se déconnecter". The dialog pops itself
  /// first, then invokes the callback so navigation can happen safely.
  final Future<void> Function()? onLogout;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final DataService _dataService = DataService();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isUploadingPhoto = false;
  String? _photoError;
  late String _photoUrl;

  @override
  void initState() {
    super.initState();
    _photoUrl = widget.currentUser.profilePhotoUrl;
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

      // Offline-first: [uploadProfilePhoto] stores the data URL locally
      // (`app_users.pending_photo_data_url`) and enqueues a `profile_photo`
      // sync op — no network call is made here. The returned value is the
      // freshly-built base64 data URL, which we use to paint the avatar
      // immediately.
      final photoDataUrl =
          await _dataService.uploadProfilePhoto(File(picked.path));
      if (!mounted) return;
      setState(() {
        _photoUrl = photoDataUrl;
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


  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      // Titre "Compte local" + pill offline aligné à droite sur la même
      // ligne. Le pill n'apparaît que quand ConnectivityService détecte
      // une perte de réseau — nulle part ailleurs dans l'app.
      title: Row(
        children: [
          const Expanded(
            child: Text(
              'Compte local',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          StreamBuilder<bool>(
            stream: ConnectivityService().offlineStream,
            initialData: ConnectivityService().isOffline,
            builder: (ctx, snapshot) {
              if (snapshot.data != true) return const SizedBox.shrink();
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFFDBA74)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 13,
                      color: Color(0xFFC2410C),
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Mode hors-ligne',
                      style: TextStyle(
                        color: Color(0xFFC2410C),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
                child: Column(
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
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFF3F0F5),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: _photoUrl.isNotEmpty
                                  ? CachedRemoteImage(
                                      url: _photoUrl.startsWith('data:')
                                          ? ''
                                          : _photoUrl,
                                      pendingDataUrl:
                                          _photoUrl.startsWith('data:')
                                              ? _photoUrl
                                              : null,
                                      fit: BoxFit.cover,
                                      width: 88,
                                      height: 88,
                                      errorWidget: Center(
                                        child: Text(
                                          _initials(),
                                          style: const TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF554A63),
                                          ),
                                        ),
                                      ),
                                    )
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
                  // Quick actions: Logout (la gestion des accès se fait
                  // désormais directement sur NocoDB, pas dans l'app).
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (widget.onLogout != null)
                        OutlinedButton.icon(
                          onPressed: _isUploadingPhoto
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
                ],
              ),
              ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

}
