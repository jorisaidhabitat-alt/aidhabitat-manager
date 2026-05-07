import 'dart:convert';

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

  /// True quand le bouton « Forcer la sync » est en cours d'exécution.
  /// Affiche un spinner + désactive les actions pour éviter les
  /// double-taps.
  bool _isResyncing = false;

  @override
  void initState() {
    super.initState();
    // Priorité au data URL pending (= photo fraîchement uploadée pas
    // encore confirmée par le serveur, mais déjà visible localement).
    // Sans ça, après un upload depuis ce dialog, on ferme/rouvre et le
    // dialog réaffiche l'ancienne photo persistée tant que le sync
    // engine n'a pas pushé la nouvelle vers NocoDB. Demande utilisateur
    // 2026-05-07. Mêmes priorités que la sidebar (cf. sidebar.dart).
    _photoUrl = widget.currentUser.pendingProfilePhotoDataUrl.isNotEmpty
        ? widget.currentUser.pendingProfilePhotoDataUrl
        : widget.currentUser.profilePhotoUrl;
  }

  @override
  void didUpdateWidget(covariant AccountDialog old) {
    super.didUpdateWidget(old);
    // Si le parent met à jour `currentUser` (ex. AuthRoot listener
    // sync stream remplace _currentUser après un pull workspace), on
    // resynchronise `_photoUrl` pour refléter la photo courante.
    final next = widget.currentUser.pendingProfilePhotoDataUrl.isNotEmpty
        ? widget.currentUser.pendingProfilePhotoDataUrl
        : widget.currentUser.profilePhotoUrl;
    if (next != _photoUrl) {
      setState(() => _photoUrl = next);
    }
  }

  /// Wipe le cache local + re-pull depuis NocoDB. Demande utilisateur
  /// 2026-05-06 : moyen de résoudre les divergences iPad ↔ Mac sans
  /// passer par Safari → Avancé → Données de sites web. Confirmation
  /// préalable car potentiellement long (recharge de tous les dossiers).
  Future<void> _handleForceResync() async {
    if (_isResyncing) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Forcer la synchronisation ?'),
        content: const Text(
          "Toutes les données locales seront supprimées et re-téléchargées "
          "depuis le serveur. Utile en cas de divergence entre vos appareils. "
          "Aucune perte — les données sont préservées dans NocoDB.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7C6DAA),
            ),
            child: const Text('Synchroniser'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _isResyncing = true);
    try {
      final n = await _dataService.wipeLocalDataForResync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Synchronisation lancée — $n entrée(s) locales effacées, '
            're-téléchargement en cours…',
          ),
          backgroundColor: const Color(0xFF7C6DAA),
          duration: const Duration(seconds: 4),
        ),
      );
      // Ferme la dialog après lancement — le pull tourne en arrière-plan,
      // l'app va se rafraîchir au prochain tick du SyncEngine (~5s).
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Synchronisation impossible : $e'),
          backgroundColor: const Color(0xFFB91C1C),
        ),
      );
    } finally {
      if (mounted) setState(() => _isResyncing = false);
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    setState(() {
      _photoError = null;
      _isUploadingPhoto = true;
    });

    try {
      // Compression aggressive — la photo profil est affichée 48×48
      // dans la sidebar et 96×96 dans le dialog. 400×400 suffit
      // largement et garantit un base64 < 70 KB (sous la limite
      // NocoDB LongText à 100 000 chars). Avant 2026-05-07 :
      // 800×800 q85 → ~130 KB → rejet NocoDB 422 → 503 côté client.
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 400,
        imageQuality: 70,
      );
      if (picked == null) {
        setState(() => _isUploadingPhoto = false);
        return;
      }

      // Lecture des bytes via XFile.readAsBytes — fonctionne uniformément
      // sur web (où `picked.path` est un blob URL non utilisable par
      // `dart:io.File`), iOS/Android et desktop. Avant ce fix, le
      // `File(picked.path).readAsBytes()` échouait silencieusement sur
      // web → l'utilisateur voyait juste un spinner indéfini ou une
      // erreur cryptique.
      final bytes = await picked.readAsBytes();
      final extension =
          picked.name.split('.').last.toLowerCase();
      final mimeType = switch (extension) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };
      final dataUrl =
          'data:$mimeType;base64,${base64Encode(bytes)}';

      // Offline-first : `uploadProfilePhotoBytes` stocke le data URL
      // localement (`app_users.pending_photo_data_url`) et enqueue un
      // sync op `profile_photo`. Renvoie le data URL pour repaint
      // immédiat. Le sync engine pousse vers `/api/profile/photo` qui
      // sauvegarde dans Vercel Blob + dans NocoDB ergotherapeutes.
      final photoDataUrl =
          await _dataService.uploadProfilePhotoBytes(dataUrl);
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
                          // Le badge appareil photo (Positioned right=-4,
                          // bottom=-4) déborde du Stack pour donner
                          // l'effet « pastille collée au bord ». Sans
                          // `Clip.none`, le badge était coupé en bas et
                          // à droite (signalé 2026-04-29).
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 88,
                              height: 88,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFEDE8F5),
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
                                color: const Color(0xFF7C6DAA),
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
                              color: Color(0xFF7C6DAA),
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
                    // Demande utilisateur 2026-04-29 : « au lieu de
                    // mettre 'Ergo' met 'Ergothérapeute chez +
                    // nom d'entreprise (Aid'habitat) ».
                    //
                    // L'établissement est aujourd'hui hardcodé sur
                    // « Aid'Habitat » côté Flutter (la base NocoDB n'a
                    // qu'un seul établissement actif). Pour rendre ça
                    // dynamique plus tard : ajouter `establishmentLabel`
                    // à `LocalAppUser` (le serveur l'envoie déjà via
                    // `establishmentLabel` dans `mapErgoToMember`),
                    // puis remplacer la chaîne ci-dessous.
                    widget.currentUser.role == LocalUserRole.ergo
                        ? "Ergothérapeute chez Aid'Habitat"
                        : widget.currentUser.role.label,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 18),
                  // Quick actions :
                  //   • Forcer la sync — wipe le cache local + re-pull
                  //     depuis NocoDB. Utile si on observe une divergence
                  //     iPad ↔ Mac sans vouloir se déconnecter (demande
                  //     utilisateur 2026-05-06).
                  //   • Se déconnecter — purge la session ET le cache
                  //     local (cf. `AuthService.signOut`).
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _isUploadingPhoto || _isResyncing
                                ? null
                                : _handleForceResync,
                        icon: _isResyncing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Color(0xFF7C6DAA),
                                  ),
                                ),
                              )
                            : const Icon(LucideIcons.refreshCcw, size: 16),
                        label: Text(_isResyncing
                            ? 'Synchronisation…'
                            : 'Forcer la sync'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF7C6DAA),
                          side: const BorderSide(color: Color(0xFFD8CFE0)),
                        ),
                      ),
                      if (widget.onLogout != null)
                        OutlinedButton.icon(
                          onPressed: _isUploadingPhoto || _isResyncing
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
