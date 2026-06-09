import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/auth_service.dart';
import 'account_dialog.dart';
import 'brand_colors.dart';
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
    if (_userOverride != null && oldWidget.currentUser != widget.currentUser) {
      // Parent a poussé une nouvelle instance → trust it.
      _userOverride = null;
    }
  }

  List<Map<String, dynamic>> get _menuItems => [
    {'id': 'dashboard', 'label': 'Accueil', 'icon': LucideIcons.home},
    // Refonte 2026-05-13 : icônes fermées (folder/book) au lieu de
    // folderOpen/bookOpen pour matcher la maquette Refonte.html l.870-871.
    {'id': 'dossiers', 'label': 'Dossiers', 'icon': LucideIcons.folder},
    {'id': 'wiki', 'label': 'Bibliothèque', 'icon': LucideIcons.book},
    // Item « Caisses » unifié — la page interne propose un switch
    // Complémentaires ↔ Principales (cf.
    // RetirementFundsCombinedScreen). Demande utilisateur 2026-05-12 :
    // 1 seul item avec icône cœur, mode par défaut Complémentaires.
    {'id': 'precos', 'label': 'Caisses', 'icon': LucideIcons.heart},
    // Item ANAH : icône Lucide `coins` (refonte 2026-05-13). Avant on
    // utilisait l'asset `assets/logos/anah.png` pour préserver la charte,
    // mais la maquette du design system aligne ANAH avec les autres
    // items (icône stylisée uniforme).
    {'id': 'anah', 'label': 'Anah', 'icon': LucideIcons.coins},
    // Page "Admin" retirée : la gestion des accès se fait sur NocoDB
    // directement (source de vérité unique → pas de conflit de sync).
  ];

  @override
  Widget build(BuildContext context) {
    // Refonte 2026-05-13 (design system Refonte.html `.rail`) :
    //  - Background warm-cream #F8F6F3 (au lieu du blanc)
    //  - Border-right ink-200 droit (plus de rounded-r 2rem)
    //  - Top mark : carré 36×36 rounded-10 noir + mauve-500 dot top-right
    //  - Nav items : 48×48 rounded-12 carrés, fond ink-100 au hover,
    //    fond mauve-100 + icône mauve-700 quand actif, indicator stripe
    //    mauve-500 3px à gauche
    //  - Avatar bottom : 36×36 rounded-10 mauve-200
    return Container(
      width: 72,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFFF8F6F3), // warm cream
        border: Border(
          right: BorderSide(color: Color(0xFFE4E7EB), width: 1), // ink-200
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // App'Ergo mark — square noir avec mauve dot, retour dashboard
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: Tooltip(
                        message: 'Accueil',
                        preferBelow: false,
                        margin: const EdgeInsets.only(left: 60),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        textStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        child: InkWell(
                          onTap: () => widget.onNavigate('dashboard'),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0E1116), // ink-900
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Cercle blanc outline — signature App'Ergo
                                // (cf. favicon.svg : cercle 5px stroke autour du
                                // centre + dot top-right). Ici en négatif sur
                                // fond noir.
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                // Mauve-500 dot top-right.
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: kBrandPurple, // mauve-500
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

                    // Navigation — items carrés rounded-12 + indicator stripe à gauche.
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _menuItems.map((item) {
                        final bool isActive =
                            widget.currentView == item['id'] ||
                            (widget.currentView == 'visit' &&
                                item['id'] == 'dossiers');

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Tooltip(
                            message: item['label'],
                            preferBelow: false,
                            margin: const EdgeInsets.only(left: 60),
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            textStyle: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                            child: SoftTapScale(
                              onTap: () => widget.onNavigate(item['id']),
                              // Stack pour superposer l'indicator stripe gauche
                              // mauve-500 (visible quand actif) au bouton carré.
                              child: SizedBox(
                                width: 60,
                                height: 48,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    // Indicator stripe gauche (3px × 32px) — mauve-500
                                    // visible quand l'item est actif, sinon invisible
                                    // via alpha 0 (interpolation propre, cf. note
                                    // 2026-04-29 sur le « flash gris »).
                                    Positioned(
                                      left: 0,
                                      top: 8,
                                      bottom: 8,
                                      child: AnimatedContainer(
                                        duration: kSoftMedium,
                                        curve: kSoftCurve,
                                        width: 3,
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? kBrandPurple // mauve-500
                                              : const Color(
                                                  0x008B6FA0,
                                                ), // alpha 0
                                          borderRadius: const BorderRadius.only(
                                            topRight: Radius.circular(3),
                                            bottomRight: Radius.circular(3),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Bouton carré rounded-12 (uniforme pour tous
                                    // les items, y compris ANAH depuis refonte
                                    // 2026-05-13).
                                    AnimatedContainer(
                                      duration: kSoftMedium,
                                      curve: kSoftCurve,
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        // mauve-100 si actif, transparent (alpha 0
                                        // du mauve-100 pour éviter le flash gris
                                        // pendant l'interpolation) si inactif.
                                        color: isActive
                                            ? const Color(
                                                0xFFF2ECF5,
                                              ) // mauve-100
                                            : const Color(0x00F2ECF5),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        item['icon'],
                                        size: 20,
                                        color: isActive
                                            ? const Color(
                                                0xFF554265,
                                              ) // mauve-700
                                            : const Color(
                                                0xFF8A939D,
                                              ), // ink-400
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    // Profile / Bottom — avatar 36×36 rounded-10 mauve-200 bg
                    // (Refonte.html `.rail .avatar`). Ouvre l'AccountDialog au tap.
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Tooltip(
                        message:
                            "${widget.currentUser.displayName} • ${widget.currentUser.role.label}",
                        preferBelow: false,
                        margin: const EdgeInsets.only(left: 60),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        textStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        child: InkWell(
                          onTap: _openAccountDialog,
                          // Refonte 2026-05-15 : avatar rond complet (demande
                          // user : « pour la photo de profil en bas à gauche
                          // augmente les radius pour avoir un format rond »).
                          // 36×36 + radius 999 = cercle parfait.
                          borderRadius: BorderRadius.circular(999),
                          child: Builder(
                            builder: (_) {
                              // Source vérité avatar : `_effectiveUser` (override
                              // post-dialog → fallback widget.currentUser). Permet
                              // au carré de refléter immédiatement une nouvelle
                              // photo après l'AccountDialog sans attendre que le
                              // parent re-propage le user.
                              final user = _effectiveUser;
                              return Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  // Sans photo : fond mauve-200 + texte mauve-700
                                  // (initiales). Avec photo : la photo prend toute
                                  // la place (le fond mauve-200 ne se voit pas).
                                  color: const Color(0xFFE3D9EA), // mauve-200
                                ),
                                clipBehavior: Clip.antiAlias,
                                child:
                                    (user.profilePhotoUrl.isNotEmpty ||
                                        user
                                            .pendingProfilePhotoDataUrl
                                            .isNotEmpty)
                                    ? CachedRemoteImage(
                                        url: user.profilePhotoUrl,
                                        pendingDataUrl:
                                            user.pendingProfilePhotoDataUrl,
                                        fit: BoxFit.cover,
                                        width: 36,
                                        height: 36,
                                        errorWidget: Center(
                                          child: Text(
                                            _initials(user.displayName),
                                            style: const TextStyle(
                                              color: Color(
                                                0xFF554265,
                                              ), // mauve-700
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      )
                                    : Center(
                                        child: Text(
                                          _initials(user.displayName),
                                          style: const TextStyle(
                                            color: Color(
                                              0xFF554265,
                                            ), // mauve-700
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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

// _CaissesSubMenuButton retiré le 2026-05-12 — l'utilisateur préfère
// 2 boutons distincts directs dans la sidebar (cf. _menuItems) plutôt
// qu'un sous-menu Popup. Plus de double-clic, navigation immédiate.
