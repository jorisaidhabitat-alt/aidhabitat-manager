import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/auth_service.dart';
import 'account_dialog.dart';
import 'cached_remote_image.dart';
import 'soft_transitions.dart';

class Sidebar extends StatefulWidget {
  final String currentView;
  final Function(String) onNavigate;
  final LocalAppUser currentUser;
  final Future<void> Function() onLogout;
  final int pendingSyncCount;
  final bool isSyncing;
  final VoidCallback? onSyncTap;

  const Sidebar({
    super.key,
    required this.currentView,
    required this.onNavigate,
    required this.currentUser,
    required this.onLogout,
    this.pendingSyncCount = 0,
    this.isSyncing = false,
    this.onSyncTap,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  /// Override local du user — utilisé après que l'`AccountDialog` ait
  /// modifié la photo de profil, pour refresh l'avatar sans attendre
  /// que le parent re-propage un nouveau `currentUser`. Reset à null
  /// quand le parent envoie un user différent (cf. `didUpdateWidget`).
  LocalAppUser? _userOverride;

  /// User effectif à afficher : override si présent, sinon le user
  /// du widget parent.
  LocalAppUser get _effectiveUser => _userOverride ?? widget.currentUser;

  @override
  void didUpdateWidget(covariant Sidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si le parent push un user fraîchement chargé qui contient déjà
    // les nouveaux champs photo, on jette l'override pour revenir à
    // la source de vérité du parent.
    if (_userOverride != null &&
        oldWidget.currentUser != widget.currentUser) {
      // Parent a poussé une nouvelle instance → trust it.
      _userOverride = null;
    }
  }

  List<Map<String, dynamic>> get _menuItems => [
    {
      'id': 'dashboard',
      'label': 'Accueil',
      'icon': LucideIcons.home,
    },
    {'id': 'dossiers', 'label': 'Dossiers', 'icon': LucideIcons.folderOpen},
    {'id': 'wiki', 'label': 'Bibliothèque', 'icon': LucideIcons.bookOpen},
    {'id': 'precos', 'label': 'Caisses', 'icon': LucideIcons.heart},
    // Item ANAH : on n'utilise plus une icône Lucide mais le vrai logo
    // de l'Anah (asset embarqué `assets/logos/anah.png` → toujours
    // disponible offline). Le rendu est géré dans le `build` ci-dessous
    // via la clé `assetLogo`.
    {
      'id': 'anah',
      'label': 'Anah',
      'icon': LucideIcons.coins, // fallback si l'asset ne charge pas
      'assetLogo': 'assets/logos/anah.png',
    },
    // Page "Admin" retirée : la gestion des accès se fait sur NocoDB
    // directement (source de vérité unique → pas de conflit de sync).
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96, // w-24
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(32), // rounded-r-[2rem]
          bottomRight: Radius.circular(32),
        ),
// border-slate-100
      ),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height,
          ),
          child: IntrinsicHeight(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
          // Logo Area — click to return to dashboard
          Padding(
            padding: const EdgeInsets.only(top: 32.0),
            child: Tooltip(
              message: 'Accueil',
              preferBelow: false,
              margin: const EdgeInsets.only(left: 80),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              child: InkWell(
                onTap: () => widget.onNavigate('dashboard'),
                borderRadius: BorderRadius.circular(50),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFCBD5E1), // slate-300
                      width: 1.5,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Colors.black,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Navigation
          Column(
            mainAxisSize: MainAxisSize.min,
            children: _menuItems.map((item) {
              // L'item "Caisses" (precos) reste actif visuellement
              // lorsque la sous-page Principales ou Complémentaires est
              // ouverte (cf. sous-menu plus bas).
              final bool isActive =
                  widget.currentView == item['id'] ||
                  (widget.currentView == 'visit' && item['id'] == 'dossiers') ||
                  (item['id'] == 'precos' &&
                      widget.currentView == 'precos_principal');

              // Cas "precos" : sous-menu au lieu de navigation directe.
              // PopupMenuButton ouvre 2 options (Principales /
              // Complémentaires) cf. demande utilisateur 2026-05-12.
              if (item['id'] == 'precos') {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: _CaissesSubMenuButton(
                    isActive: isActive,
                    onSelect: widget.onNavigate,
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0),
                child: Tooltip(
                  message: item['label'],
                  preferBelow: false,
                  margin: const EdgeInsets.only(left: 80),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  textStyle: const TextStyle(color: Colors.white, fontSize: 12),
                  child: SoftTapScale(
                    onTap: () => widget.onNavigate(item['id']),
                    // Un seul rond : pas d'InkWell autour pour éviter
                    // le halo/splash Material qui dessinait un 2e fond
                    // circulaire par-dessus l'AnimatedContainer.
                    //   • Actif   : fond violet clair #EDE8F5 + icône
                    //     violet foncé #7C6DAA.
                    //   • Inactif : violet clair en alpha 0 (= invisible
                    //     visuellement, identique au fond blanc).
                    //
                    // Subtilité (demande utilisateur 2026-04-29) : on
                    // utilise `Color(0x00EDE8F5)` (alpha=0 du violet
                    // actif) plutôt que `Colors.transparent` parce que
                    // ce dernier est en réalité un NOIR transparent
                    // (#00000000). Pendant l'animation
                    // `AnimatedContainer` qui interpole entre les deux
                    // états, le passage noir-transparent → violet-opaque
                    // traverse des gris foncés visibles à l'œil — d'où
                    // le « flash gris rapide » remonté par l'ergo. En
                    // partant du même hue (violet) avec juste une
                    // variation d'alpha, l'interpolation reste violet
                    // tout au long → pas de flash.
                    child: AnimatedContainer(
                      duration: kSoftMedium,
                      curve: kSoftCurve,
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        // Pour les logos de marque (ex. ANAH), fond
                        // blanc constant pour respecter la charte du
                        // logo (pas de halo coloré qui vient salir
                        // l'image officielle).
                        color: item['assetLogo'] != null
                            ? Colors.white
                            : (isActive
                                ? const Color(0xFFEDE8F5)
                                : const Color(0x00EDE8F5)),
                        shape: BoxShape.circle,
                        // Léger contour gris quand l'item logo n'est
                        // pas actif, sinon le rond blanc disparaît dans
                        // la sidebar blanche.
                        border: item['assetLogo'] != null
                            ? Border.all(
                                color: isActive
                                    ? const Color(0xFF7C6DAA)
                                    : const Color(0xFFDDE1E8),
                                width: 1.5,
                              )
                            : null,
                      ),
                      // Pour les items "logo de marque" (ex. ANAH), on
                      // affiche l'image embarquée à la place de l'icône
                      // Lucide. L'image conserve ses couleurs d'origine
                      // (pas de teinte) pour que la charte de l'Anah
                      // reste reconnaissable. Disponible offline (asset
                      // empaqueté dans le bundle).
                      //
                      // Netteté : le PNG source est en 1190×1024 mais
                      // l'emplacement final fait ~32 px (48 - 2×8 px de
                      // padding). Sans hint, Flutter applique un
                      // resampling « low quality » → effet pixelisé. On
                      // force `FilterQuality.high` (bicubique) +
                      // `cacheWidth: 96` (≈ 32 × 3 pour les écrans HiDPI
                      // type Retina) pour que le décodage donne une
                      // vignette pré-resamplée propre, sans pomper la
                      // RAM avec le 1190×1024 plein.
                      child: item['assetLogo'] != null
                          ? Padding(
                              padding: const EdgeInsets.all(8),
                              child: Image.asset(
                                item['assetLogo'] as String,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                cacheWidth: 96,
                                isAntiAlias: true,
                                errorBuilder: (_, __, ___) => Icon(
                                  item['icon'],
                                  size: 22,
                                  color: isActive
                                      ? const Color(0xFF7C6DAA)
                                      : const Color(0xFF8D94A3),
                                ),
                              ),
                            )
                          : Icon(
                              item['icon'],
                              size: 22,
                              color: isActive
                                  ? const Color(0xFF7C6DAA)
                                  : const Color(0xFF8D94A3),
                            ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),


          // Profile / Bottom — single avatar button that opens the account
          // dialog (profile photo, password, logout, admin access).
          Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: Tooltip(
              message:
                  "${widget.currentUser.displayName} • ${widget.currentUser.role.label}",
              preferBelow: false,
              margin: const EdgeInsets.only(left: 80),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              textStyle: const TextStyle(color: Colors.white, fontSize: 12),
              child: InkWell(
                onTap: _openAccountDialog,
                customBorder: const CircleBorder(),
                child: Builder(builder: (_) {
                  // Source vérité avatar : `_effectiveUser` (override
                  // post-dialog → fallback widget.currentUser). Permet
                  // au rond de refléter immédiatement une nouvelle
                  // photo après l'AccountDialog sans attendre que le
                  // parent re-propage le user.
                  final user = _effectiveUser;
                  return Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF7C6DAA),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (user.profilePhotoUrl.isNotEmpty ||
                          user.pendingProfilePhotoDataUrl.isNotEmpty)
                      ? CachedRemoteImage(
                          url: user.profilePhotoUrl,
                          pendingDataUrl:
                              user.pendingProfilePhotoDataUrl,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          errorWidget: Center(
                            child: Text(
                              _initials(user.displayName),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Text(
                            _initials(user.displayName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                );
                }),
              ),
            ),
          ),
        ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAccountDialog() async {
    // `showSoftDialog` = fade + scale doux (mêmes sensations que la
    // navigation entre vues, cf. `soft_transitions.dart`).
    await showSoftDialog<bool>(
      context: context,
      builder: (_) => AccountDialog(
        currentUser: _effectiveUser,
        onLogout: widget.onLogout,
        // `onOpenAdmin` retiré avec la page Admin — la gestion des accès
        // est désormais pilotée uniquement depuis NocoDB.
      ),
    );
    // Après fermeture du dialog, on refresh le user depuis la SQLite
    // locale (qui a déjà la nouvelle photo via
    // `app_users.pending_photo_data_url`). Sans ça, le rond avatar
    // de la sidebar conservait l'ancienne valeur — l'utilisateur
    // voyait sa nouvelle photo dans le dialog mais pas dans le rond
    // après fermeture (signalé 2026-04-29).
    if (!mounted) return;
    try {
      final fresh = await AuthService().getCurrentUser();
      if (!mounted || fresh == null) return;
      setState(() => _userOverride = fresh);
    } catch (_) {
      // Best-effort : si la lecture SQLite échoue, on garde
      // l'ancien avatar — pas de crash.
    }
  }

  String _initials(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'AH';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }
}

/// Bouton sidebar « Caisses » avec sous-menu déroulant (demande
/// utilisateur 2026-05-12, Q2c regroupement). Au tap, ouvre un
/// PopupMenu Material qui propose :
///   - Caisses principales   (vue `precos_principal`)
///   - Caisses complémentaires (vue `precos`)
///
/// Reproduit visuellement le SoftTapScale + AnimatedContainer rond
/// des autres items pour rester homogène avec le reste de la sidebar.
class _CaissesSubMenuButton extends StatelessWidget {
  final bool isActive;
  final ValueChanged<String> onSelect;

  const _CaissesSubMenuButton({
    required this.isActive,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Caisses',
      preferBelow: false,
      margin: const EdgeInsets.only(left: 80),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      child: PopupMenuButton<String>(
        tooltip: '',
        position: PopupMenuPosition.under,
        offset: const Offset(56, -16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        onSelected: onSelect,
        itemBuilder: (context) => const [
          PopupMenuItem<String>(
            value: 'precos_principal',
            child: Row(
              children: [
                Icon(LucideIcons.building,
                    size: 18, color: Color(0xFF7C6DAA)),
                SizedBox(width: 10),
                Text('Caisses principales'),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'precos',
            child: Row(
              children: [
                Icon(LucideIcons.heart,
                    size: 18, color: Color(0xFF7C6DAA)),
                SizedBox(width: 10),
                Text('Caisses complémentaires'),
              ],
            ),
          ),
        ],
        child: AnimatedContainer(
          duration: kSoftMedium,
          curve: kSoftCurve,
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFFEDE8F5)
                : const Color(0x00EDE8F5),
            shape: BoxShape.circle,
          ),
          child: Icon(
            LucideIcons.heart,
            size: 22,
            color: isActive
                ? const Color(0xFF7C6DAA)
                : const Color(0xFF8D94A3),
          ),
        ),
      ),
    );
  }
}
