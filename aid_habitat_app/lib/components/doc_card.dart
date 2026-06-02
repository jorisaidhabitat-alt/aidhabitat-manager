import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import 'brand_colors.dart';
import 'doc_thumbnails.dart';

// =============================================================================
// SyncBadge — petite pastille colorée (vert/orange/rouge selon SyncState)
// avec tooltip qui affiche le label. Extraite de documents_screen.dart
// 2026-05-15 (audit P0 #9 suite).
// =============================================================================

/// Couleur d'un badge selon l'état de sync.
Color syncStateColor(SyncState syncState) {
  switch (syncState) {
    case SyncState.synced:
      return Colors.green.shade700;
    case SyncState.pendingSync:
    case SyncState.localOnly:
    case SyncState.syncing:
      return Colors.orange.shade700;
    case SyncState.syncError:
    case SyncState.conflict:
      return Colors.red.shade700;
  }
}

class SyncBadge extends StatelessWidget {
  final SyncState syncState;
  const SyncBadge({super.key, required this.syncState});

  @override
  Widget build(BuildContext context) {
    final color = syncStateColor(syncState);
    // Refonte 2026-05-13 : on garde uniquement la petite pastille
    // colorée (suppression du label texte). Tooltip ajouté pour ne pas
    // perdre l'info d'état au survol.
    return Tooltip(
      message: syncState.label,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

// =============================================================================
// DocCard — vignette de document dans la grille avec :
//   - thumbnail (DocThumbnail)
//   - badge sync (SyncBadge) en haut-droite
//   - checkbox sélection (apparaît au survol, en mode sélection, ou si
//     déjà sélectionnée)
//   - bandeau blanc en bas : titre éditable inline + date + menu kebab
//     (Télécharger / Supprimer)
//
// Extraite de documents_screen.dart 2026-05-15.
// =============================================================================

class DocCard extends StatefulWidget {
  final DocItem doc;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final Future<void> Function(String newTitle) onTitleChanged;

  const DocCard({
    super.key,
    required this.doc,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelect,
    required this.onDelete,
    required this.onDownload,
    required this.onTitleChanged,
  });

  @override
  State<DocCard> createState() => _DocCardState();
}

class _DocCardState extends State<DocCard> {
  bool _isEditingTitle = false;
  bool _hovering = false;
  late TextEditingController _titleCtrl;
  late FocusNode _titleFocus;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.doc.title);
    _titleFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant DocCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditingTitle && widget.doc.title != _titleCtrl.text) {
      _titleCtrl.text = widget.doc.title;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<void> _commitRename() async {
    final newTitle = _titleCtrl.text.trim();
    setState(() => _isEditingTitle = false);
    if (newTitle.isEmpty || newTitle == widget.doc.title) {
      _titleCtrl.text = widget.doc.title;
      return;
    }
    await widget.onTitleChanged(newTitle);
  }

  void _startEditing() {
    setState(() => _isEditingTitle = true);
    _titleCtrl.text = widget.doc.title;
    Future.microtask(() {
      _titleFocus.requestFocus();
      _titleCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _titleCtrl.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final createdAt = DateTime.tryParse(doc.date)?.toLocal();
    final dateLabel = createdAt == null
        ? doc.date
        : DateFormat('dd/MM/yyyy').format(createdAt);
    final selMode = widget.selectionMode;
    final selected = widget.selected;

    // La checkbox est visible au survol souris, quand la card est sélectionnée,
    // ou quand on est en mode sélection global (long-press ou checkbox activée).
    final showCheckbox = _hovering || selected || selMode;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: _hovering
            ? (Matrix4.identity()..translateByDouble(0.0, -3.0, 0.0, 1.0))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? kBrandPurple.withValues(alpha: 0.72)
                : _hovering
                ? kBrandPurple.withValues(alpha: 0.34)
                : const Color(0xFFDADDE3),
            width: selected ? 1.8 : 1.2,
          ),
          boxShadow: _hovering
              ? [
                  BoxShadow(
                    color: kBrandPurple.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 14,
                    offset: const Offset(0, 3),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          borderRadius: BorderRadius.circular(16),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thumbnail / preview area
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                        child: DocThumbnail(doc: doc),
                      ),
                    ),
                    // Selection overlay
                    if (selMode)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
                          child: Container(
                            color: selected
                                ? kBrandPurple.withValues(alpha: 0.35)
                                : Colors.black.withValues(alpha: 0.08),
                          ),
                        ),
                      ),
                    // Tag overlay supprimé (demande utilisateur
                    // 2026-04-29) — le système de tags a été retiré côté
                    // import (plus de modale de choix de type) et côté
                    // affichage (pas de badge noir en haut-gauche).
                    // Checkbox de sélection (top-left). Apparaît au survol
                    // souris, quand la card est sélectionnée, ou pendant le
                    // mode sélection. Carré à coins arrondis, sans contour
                    // violet — violet seulement quand coché.
                    if (showCheckbox)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onToggleSelect,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: selected ? kBrandPurple : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: selected
                                  ? const Icon(
                                      LucideIcons.check,
                                      size: 14,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    // Sync badge (top-right) — hidden in selection mode.
                    // Les actions « Télécharger » et « Supprimer » sont
                    // déplacées dans le menu kebab (3 points) sur le
                    // bandeau blanc en bas de la card — plus d'icônes
                    // flottantes sur la vignette.
                    if (!selMode)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: SyncBadge(syncState: doc.syncState),
                      ),
                  ],
                ),
              ),
              // Title + date (gauche) + menu actions kebab (droite).
              // Le bandeau blanc accueille à la fois le titre éditable
              // et un bouton 3 points qui ouvre un menu avec « Télécharger »
              // / « Supprimer » — choix design utilisateur pour libérer
              // la vignette de toute icône flottante.
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Inline editable title — Nunito (parité avec
                          // les autres titres de l'app, demande user
                          // 2026-05-13). Taille bumpée 13 → 16, weight
                          // allégé bold (w700) → w500 (demande user
                          // 2026-05-13 : « augmente la taille et reduis
                          // l'epaisseur »).
                          _isEditingTitle
                              ? TextField(
                                  controller: _titleCtrl,
                                  focusNode: _titleFocus,
                                  maxLines: 1,
                                  textInputAction: TextInputAction.done,
                                  style: GoogleFonts.nunito(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 16,
                                    color: Colors.black87,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 4,
                                    ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                  ),
                                  onSubmitted: (_) => _commitRename(),
                                  onTapOutside: (_) => _commitRename(),
                                )
                              : GestureDetector(
                                  onTap: selMode ? null : _startEditing,
                                  behavior: HitTestBehavior.opaque,
                                  child: Text(
                                    doc.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.nunito(
                                      fontWeight: FontWeight.w500,
                                      fontSize: 16,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                          const SizedBox(height: 2),
                          // Date : 10 → 13, weight light (w300) — discret
                          // et lisible avec un peu plus d'air sous le titre.
                          Text(
                            dateLabel,
                            style: GoogleFonts.nunito(
                              fontSize: 13,
                              fontWeight: FontWeight.w300,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Menu kebab (3 points) — caché en mode sélection,
                    // sinon expose Télécharger + Supprimer.
                    if (!selMode)
                      PopupMenuButton<String>(
                        tooltip: 'Actions',
                        icon: const Icon(
                          LucideIcons.moreVertical,
                          size: 18,
                          color: Color(0xFF8A939D),
                        ),
                        padding: EdgeInsets.zero,
                        splashRadius: 18,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSelected: (value) {
                          if (value == 'download') {
                            widget.onDownload();
                          } else if (value == 'delete') {
                            widget.onDelete();
                          }
                        },
                        itemBuilder: (ctx) => const [
                          PopupMenuItem<String>(
                            value: 'download',
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.download,
                                  size: 16,
                                  color: kBrandDarkPurple,
                                ),
                                SizedBox(width: 10),
                                Text('Télécharger'),
                              ],
                            ),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  LucideIcons.trash2,
                                  size: 16,
                                  color: Colors.red,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Supprimer',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
