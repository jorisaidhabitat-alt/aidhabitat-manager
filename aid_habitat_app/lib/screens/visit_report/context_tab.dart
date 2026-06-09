import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../components/brand_colors.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';
import '../../components/two_threshold_swipe.dart';

/// Contexte de vie tab — parité 1:1 avec la version React (`ContextForm`).
///
/// Sous-sections : Médical + Autonomie.
/// Gère un état "par occupant" (chaque personne du foyer a ses propres
/// pathologies, suivi, sensoriel, mesures, autonomie et besoins d'aide
/// humaine). La section Autonomie peut être verrouillée via le bouton ✓
/// pour signifier "autonome sur l'ensemble".
class ContextTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  /// Called when the user toggles a numbered medical flag (1 = Pathologie,
  /// 2 = Suivi médical, 3 = Sensoriel). `checked` is the new state. Le
  /// parent met à jour les flags de la PAGE COURANTE de la note Médical
  /// (les numéros sont désormais par-page, plus globaux — un onglet
  /// Médical peut afficher {1} sur page 1 et {2, 3} sur page 2).
  final Future<void> Function(int flagNumber, bool checked)?
  onMedicalFlagToggled;

  /// Flags médicaux actuellement visibles sur la PAGE COURANTE de la
  /// note "Contexte de vie > Médical". Source unique de vérité pour
  /// l'état coché des cases Pathologie / Suivi / Sensoriel. Poussé par
  /// le parent à chaque changement de page dans NotesWidget.
  final Set<int>? currentMedicalFlags;

  /// Callback invoqué quand l'ergo bascule entre les sous-sections
  /// internes (0 = Médical, 1 = Autonomie). Utilisé par
  /// `VisitReportScreen` pour resynchroniser le panneau notes de
  /// droite avec la sous-section active — sans ça, le panneau
  /// affichait toujours la note Médicale même après avoir cliqué sur
  /// Autonomie (bug reporté 2026-04-29 : « Habitudes de vie est vide
  /// alors que la note de Autonomie n'est pas vide »). Demande
  /// utilisateur 2026-04-30 : "celle de habitudes de vie doit être
  /// celle de autonomie".
  final ValueChanged<int>? onSubSectionChanged;

  /// Sous-section initiale (0 = Médical, 1 = Autonomie). Permet au
  /// parent de restaurer la dernière section visitée quand l'ergo
  /// revient sur cet onglet.
  final int initialSubSection;

  const ContextTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onMedicalFlagToggled,
    this.currentMedicalFlags,
    this.onSubSectionChanged,
    this.initialSubSection = 0,
  });

  @override
  State<ContextTab> createState() => _ContextTabState();
}

class _ContextTabState extends State<ContextTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _subSection = 0; // 0 = medical, 1 = autonomy
  int _activeOccupantIndex = 0;
  final bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  late List<OccupantAutonomy> _contextOccupants;

  @override
  void initState() {
    super.initState();
    _subSection = widget.initialSubSection.clamp(0, 1);
    _load();
  }

  /// Change la sous-section active ET notifie le parent (qui resync
  /// le panneau notes à droite via `_activeSubsectionByTab`).
  void _setSubSection(int i) {
    if (i == _subSection) return;
    setState(() => _subSection = i);
    widget.onSubSectionChanged?.call(i);
  }

  @override
  void didUpdateWidget(covariant ContextTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync de la sous-section quand le parent change
    // `initialSubSection` programmatiquement — ex. navigation depuis
    // la popup « Champs manquants » du flow de génération PDF.
    // `didUpdateWidget` est suivi d'un build : assignation directe,
    // sans `setState` ni callback parent pendant la reconstruction.
    if (oldWidget.initialSubSection != widget.initialSubSection) {
      final next = widget.initialSubSection.clamp(0, 1);
      if (next != _subSection) {
        _subSection = next;
      }
    }
    // When the parent pushes a refreshed dossier (e.g. after the user
    // changed a name in the Bénéficiaire tab), re-derive the context
    // occupants so the pills and names shown here track the new values.
    final oldP = oldWidget.dossier.patient;
    final newP = widget.dossier.patient;
    final nameChanged =
        oldP.firstName != newP.firstName ||
        oldP.lastName != newP.lastName ||
        oldP.secondFirstName != newP.secondFirstName ||
        oldP.secondLastName != newP.secondLastName ||
        oldP.numberPeople != newP.numberPeople ||
        oldP.homeHelpTxt != newP.homeHelpTxt;
    if (nameChanged && _loaded) {
      _rebuildOccupantsFromNewPatient();
    }
  }

  void _rebuildOccupantsFromNewPatient() {
    if (_contextOccupants.isEmpty) return;
    final primary = _contextOccupants.first;
    final rebuilt = _buildContextOccupants(
      AutonomyData(
        done: primary.autonomyDone,
        checklist: primary.autonomy,
        occupants: _contextOccupants,
      ),
      primary.medical,
    );
    setState(() => _contextOccupants = rebuilt);
  }

  @override
  void dispose() {
    final hadPendingSave = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    if (hadPendingSave) {
      unawaited(_save());
    }
    super.dispose();
  }

  Future<void> _load() async {
    final data = await widget.repository.fetchContexteDeVie(widget.dossier.id);

    AutonomyData autonomy = const AutonomyData();
    MedicalContext medical = const MedicalContext();
    if (data != null) {
      if (data['medicalContext'] != null) {
        medical = MedicalContext.fromJson(
          data['medicalContext'] as Map<String, dynamic>,
        );
      }
      if (data['autonomy'] != null) {
        autonomy = AutonomyData.fromJson(
          data['autonomy'] as Map<String, dynamic>,
        );
      }
    }

    _contextOccupants = _buildContextOccupants(autonomy, medical);
    if (mounted) setState(() => _loaded = true);
  }

  /// Construit un tableau OccupantAutonomy pour tous les occupants du foyer,
  /// en fallbackant sur les données racines quand les sous-données
  /// per-occupant sont absentes (parité React `buildContextOccupants`).
  List<OccupantAutonomy> _buildContextOccupants(
    AutonomyData autonomy,
    MedicalContext medical,
  ) {
    final patient = widget.dossier.patient;
    final count = math.max(1, patient.numberPeople ?? 1);
    final out = <OccupantAutonomy>[];
    for (var i = 0; i < count; i++) {
      final existing = i < autonomy.occupants.length
          ? autonomy.occupants[i]
          : null;

      final homeHelpTxt = _occupantHomeHelpText(i);

      if (existing != null) {
        out.add(
          OccupantAutonomy(
            medical: existing.medical,
            autonomyDone: existing.autonomyDone,
            autonomy: _mergeAutonomyItems(existing.autonomy),
            humanHelp: _mergeHumanHelpItems(existing.humanHelp, homeHelpTxt),
            attention: _mergeAutonomyItems(existing.attention),
          ),
        );
      } else {
        out.add(
          OccupantAutonomy(
            medical: i == 0 ? medical : const MedicalContext(),
            autonomyDone: i == 0 ? autonomy.done : false,
            autonomy: _mergeAutonomyItems(
              i == 0 ? autonomy.checklist : const [],
            ),
            humanHelp: _mergeHumanHelpItems(const [], homeHelpTxt),
            attention: _mergeAutonomyItems(const []),
          ),
        );
      }
    }
    return out;
  }

  String _occupantHomeHelpText(int index) {
    final p = widget.dossier.patient;
    if (index == 0) return p.homeHelpTxt;
    if (index < p.occupants.length) return p.occupants[index].homeHelpTxt;
    return '';
  }

  bool _occupantHomeHelpEnabled(int index) {
    final p = widget.dossier.patient;
    // Prefer the per-occupant record when it exists (written by the
    // Bénéficiaire > Santé tab). Fall back to the top-level patient flag
    // for the primary occupant if no occupants array has been saved yet.
    if (index < p.occupants.length) return p.occupants[index].homeHelp;
    if (index == 0) return p.homeHelp;
    return false;
  }

  /// Garantit les 11 items dans l'ordre canonique.
  List<AutonomyItem> _mergeAutonomyItems(List<AutonomyItem> existing) {
    final map = {for (final e in existing) e.name: e};
    return kAutonomyItemNames
        .map((name) => map[name] ?? AutonomyItem(name: name))
        .toList();
  }

  /// Reconstitue la liste des 11 items humanHelp à partir d'un texte
  /// séparé par virgules (comme React `parseHumanHelpItems`).
  List<AutonomyItem> _mergeHumanHelpItems(
    List<AutonomyItem> existing,
    String rawHomeHelpTxt,
  ) {
    if (existing.isNotEmpty) {
      final map = {for (final e in existing) e.name: e};
      return kAutonomyItemNames
          .map((name) => map[name] ?? AutonomyItem(name: name))
          .toList();
    }
    final normalized = rawHomeHelpTxt.toLowerCase();
    return kAutonomyItemNames
        .map(
          (name) => AutonomyItem(
            name: name,
            checked: normalized.contains(name.toLowerCase()),
          ),
        )
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  void _updateActive(OccupantAutonomy updated) {
    setState(() {
      _contextOccupants[_safeIndex] = updated;
    });
    _scheduleSave();
  }

  void _updateMedical({
    String? pathology,
    String? followUp,
    String? sensory,
    String? heightCm,
    String? weightKg,
  }) {
    final occ = _active;
    final m = occ.medical;
    _updateActive(
      OccupantAutonomy(
        medical: MedicalContext(
          pathology: pathology ?? m.pathology,
          followUp: followUp ?? m.followUp,
          sensory: sensory ?? m.sensory,
          heightCm: heightCm ?? m.heightCm,
          weightKg: weightKg ?? m.weightKg,
        ),
        autonomyDone: occ.autonomyDone,
        autonomy: occ.autonomy,
        humanHelp: occ.humanHelp,
      ),
    );
  }

  /// Toggle d'un flag médical. Les flags sont désormais PAR PAGE de note
  /// (sauvegardés dans `drawing_json` via NotesWidget) — on ne touche
  /// plus au dossier `MedicalContext`. L'état coché vient de
  /// [widget.currentMedicalFlags].
  void _toggleMedicalFlag(String field) {
    final flagNumber = switch (field) {
      'pathology' => 1,
      'followUp' => 2,
      'sensory' => 3,
      _ => 0,
    };
    if (flagNumber == 0) return;
    final currentFlags = widget.currentMedicalFlags ?? const <int>{};
    final wasChecked = currentFlags.contains(flagNumber);
    widget.onMedicalFlagToggled?.call(flagNumber, !wasChecked);
  }

  // _toggleAutonomyDone() retiré : la validation "autonome sur l'ensemble"
  // est désormais dérivée automatiquement quand les 11 items sont tous
  // en état ✓ (`allAutonomous` dans _buildAutonomy), et le champ
  // OccupantAutonomy.autonomyDone est mis à jour par _setAutonomyItemState.

  /// État composite d'un item d'autonomie. Modèle 2026-05-04 :
  /// `humanHelp` est indépendant des deux autres (peut coexister avec
  /// `autonomous` OU `attention`). `autonomous` et `attention` restent
  /// mutuellement exclusifs entre eux. Demande utilisateur :
  /// « même s'il y a une aide humaine sélectionnée, possibilité de
  /// cocher une autre case sur la même ligne aussi ».
  _AutonomyItemState _itemState(int index) {
    final occ = _active;
    final autonomous =
        index < occ.autonomy.length && occ.autonomy[index].checked;
    final attention =
        index < occ.attention.length && occ.attention[index].checked;
    final humanHelp =
        index < occ.humanHelp.length && occ.humanHelp[index].checked;
    return _AutonomyItemState(
      autonomous: autonomous,
      attention: attention,
      humanHelp: humanHelp,
    );
  }

  /// Met à jour l'item `index` en respectant la mutex `autonomous` ↔
  /// `attention` (un seul des deux à la fois) et en laissant
  /// `humanHelp` indépendant. Recalcule `autonomyDone` (vrai ssi tous
  /// les items sont en `autonomous`, peu importe la coche aide humaine).
  void _setAutonomyItemState(int index, _AutonomyItemState state) {
    final occ = _active;
    final auto = List<AutonomyItem>.from(occ.autonomy);
    final help = List<AutonomyItem>.from(occ.humanHelp);
    final att = List<AutonomyItem>.from(occ.attention);
    // Mutex entre autonomous et attention — si l'appelant demande les
    // deux à true, on garde le dernier toggle (priorité aux passages
    // de none → autonomous/attention plutôt que l'inverse).
    var newAutonomous = state.autonomous;
    var newAttention = state.attention;
    if (newAutonomous && newAttention) {
      // Sécurité : ne devrait pas arriver via les togglers, mais on
      // garde un comportement déterministe (priorité à autonomous).
      newAttention = false;
    }
    if (index < auto.length) {
      auto[index] = AutonomyItem(
        name: auto[index].name,
        checked: newAutonomous,
      );
    }
    if (index < att.length) {
      att[index] = AutonomyItem(name: att[index].name, checked: newAttention);
    }
    if (index < help.length) {
      help[index] = AutonomyItem(
        name: help[index].name,
        checked: state.humanHelp,
      );
    }
    final allAutonomous =
        auto.length == kAutonomyItemNames.length &&
        auto.every((i) => i.checked);
    _updateActive(
      OccupantAutonomy(
        medical: occ.medical,
        autonomyDone: allAutonomous,
        autonomy: auto,
        humanHelp: help,
        attention: att,
      ),
    );
  }

  void _toggleAutonomyItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      _AutonomyItemState(
        autonomous: !current.autonomous,
        // Mutex : si on active autonomous, on désactive attention.
        // Si on désactive autonomous, attention reste comme tel.
        attention: !current.autonomous ? false : current.attention,
        humanHelp: current.humanHelp,
      ),
    );
  }

  void _toggleAttentionItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      _AutonomyItemState(
        autonomous: !current.attention ? false : current.autonomous,
        attention: !current.attention,
        humanHelp: current.humanHelp,
      ),
    );
  }

  void _toggleHumanHelpItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      _AutonomyItemState(
        autonomous: current.autonomous,
        attention: current.attention,
        humanHelp: !current.humanHelp,
      ),
    );
  }

  /// Coche / décoche TOUS les items d'autonomie d'un seul geste
  /// (demande utilisateur 2026-04-29 : « il doit être possible d'avoir
  /// une coche au dessus de la liste qui permet de tout valider direct
  /// si la personne est autonome »).
  ///
  /// - `setAll == true`  → chaque ligne passe à `autonomous` (✓), les
  ///   autres états (attention, aide humaine) sont écrasés. C'est la
  ///   raison d'être du raccourci : 1 tap = 11 items validés.
  /// - `setAll == false` → chaque ligne repasse à `none` (rien coché).
  ///   La case se décoche aussi visuellement (l'utilisateur peut
  ///   reprendre item par item ensuite).
  ///
  /// `autonomyDone` est dérivé automatiquement (true uniquement quand
  /// tous les items sont en `autonomous`).
  void _setAllAutonomyItems(bool setAll) {
    final occ = _active;
    final total = kAutonomyItemNames.length;
    final auto = List<AutonomyItem>.generate(
      total,
      (i) => AutonomyItem(
        name: i < occ.autonomy.length
            ? occ.autonomy[i].name
            : kAutonomyItemNames[i],
        checked: setAll,
      ),
    );
    final att = List<AutonomyItem>.generate(
      total,
      (i) => AutonomyItem(
        name: i < occ.attention.length
            ? occ.attention[i].name
            : kAutonomyItemNames[i],
        checked: false,
      ),
    );
    final help = List<AutonomyItem>.generate(
      total,
      (i) => AutonomyItem(
        name: i < occ.humanHelp.length
            ? occ.humanHelp[i].name
            : kAutonomyItemNames[i],
        checked: false,
      ),
    );
    _updateActive(
      OccupantAutonomy(
        medical: occ.medical,
        autonomyDone: setAll,
        autonomy: auto,
        humanHelp: help,
        attention: att,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Save (debounced)
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(kSaveDebouncePills, _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    // Pas de setState(_saving) — voir dossier_screen.dart.
    final primary = _contextOccupants.isNotEmpty
        ? _contextOccupants.first
        : const OccupantAutonomy();
    final autonomy = AutonomyData(
      done: primary.autonomyDone,
      checklist: primary.autonomy,
      occupants: _contextOccupants,
    );
    await widget.repository.upsertContexteDeVie(
      widget.dossier.id,
      widget.dossier.patient.id,
      medicalContext: primary.medical,
      autonomy: autonomy,
    );
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  int get _safeIndex {
    if (_contextOccupants.isEmpty) return 0;
    return _activeOccupantIndex.clamp(0, _contextOccupants.length - 1).toInt();
  }

  OccupantAutonomy get _active {
    if (_contextOccupants.isEmpty) return const OccupantAutonomy();
    return _contextOccupants[_safeIndex];
  }

  // _occupantLabels retiré : la navigation entre occupants utilise
  // désormais le header (nom complet) + les points de pagination — les
  // pills avec les prénoms courts ne sont plus nécessaires.

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasMultiple = _contextOccupants.length > 1;
    final idx = _safeIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Bandeau sous-menu full-width en haut de la card — parité
        // avec l'onglet Bénéficiaire.
        _buildQuickNav(),
        Expanded(
          // Swipe horizontal → toujours change d'occupant (peu importe
          // l'amplitude, léger ou large). Bascule Médical ↔ Autonomie
          // uniquement via le QuickNav (tap) (demande utilisateur
          // 2026-04-29).
          child: TwoThresholdSwipe(
            onLightSwipeLeft: !hasMultiple
                ? null
                : () {
                    setState(() {
                      _activeOccupantIndex =
                          (idx + 1) % _contextOccupants.length;
                    });
                  },
            onLightSwipeRight: !hasMultiple
                ? null
                : () {
                    setState(() {
                      _activeOccupantIndex =
                          (idx - 1 + _contextOccupants.length) %
                          _contextOccupants.length;
                    });
                  },
            onWideSwipeLeft: !hasMultiple
                ? null
                : () {
                    setState(() {
                      _activeOccupantIndex =
                          (idx + 1) % _contextOccupants.length;
                    });
                  },
            onWideSwipeRight: !hasMultiple
                ? null
                : () {
                    setState(() {
                      _activeOccupantIndex =
                          (idx - 1 + _contextOccupants.length) %
                          _contextOccupants.length;
                    });
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Tout le bloc de l'occupant (header + scroll
                // medical/autonomy) glisse en bloc quand on change
                // d'occupant. Pas d'animation entre les sous-sections
                // (Médicale ↔ Autonomie) — bascule instantanée.
                Expanded(
                  child: HorizontalSlideSwitcher(
                    index: idx,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasMultiple)
                          Container(
                            color: Colors.white,
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                            child: _buildOccupantHeader(idx),
                          ),
                        Expanded(
                          // Légère animation entre Médicale ↔ Autonomie —
                          // fade + apparition vers le haut, identique
                          // aux autres switches de sous-section.
                          child: SoftSwitcher(
                            child: KeyedSubtree(
                              key: ValueKey<int>(_subSection),
                              child: SingleChildScrollView(
                                padding: EdgeInsets.fromLTRB(
                                  20,
                                  hasMultiple ? 0 : 16,
                                  20,
                                  12,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_subSection == 0)
                                      _buildMedical()
                                    else
                                      _buildAutonomy(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Points de pagination — affichés tout en bas du cadre
                // quand le foyer a plusieurs occupants (demande
                // utilisateur : parité avec Bénéficiaire).
                if (hasMultiple)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14, top: 6),
                    child: Center(child: _buildOccupantDots(idx)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Bannière occupant (refonte 2026-05-13, visit-pages.js l.453-465) :
  ///   - Fond mauve-50 + border mauve-100 + radius 12
  ///   - Eyebrow rôle (« BÉNÉFICIAIRE PRINCIPAL » / « CONJOINT·E ») 10px
  ///     mauve-500 uppercase letter-spacing 0.1em
  ///   - Nom occupant Nunito 17px w700 ink-900 centré
  ///   - Boutons prev/next 30×30 rounded-8 (transparents, désactivés si
  ///     un seul occupant)
  Widget _buildOccupantHeader(int idx, {Widget? extra}) {
    final p = widget.dossier.patient;
    String first = '';
    String last = '';
    if (idx == 0) {
      first = p.firstName.trim();
      last = p.lastName.trim();
    } else if (idx < p.occupants.length) {
      first = p.occupants[idx].firstName.trim();
      last = p.occupants[idx].lastName.trim();
    }
    final display = (first.isEmpty && last.isEmpty)
        ? 'Occupant ${idx + 1}'
        : [first, last.toUpperCase()].where((s) => s.isNotEmpty).join(' ');
    final total = _contextOccupants.length;
    final hasNav = total > 1;
    // `role` (BÉNÉFICIAIRE PRINCIPAL / CONJOINT·E) retiré sur demande user
    // 2026-05-13 — le prénom NOM seul suffit, le rôle est redondant avec
    // la navigation prev/next + les dots de pagination.

    void prev() {
      if (!hasNav) return;
      final next = (_activeOccupantIndex - 1 + total) % total;
      setState(() => _activeOccupantIndex = next);
    }

    void next() {
      if (!hasNav) return;
      final n = (_activeOccupantIndex + 1) % total;
      setState(() => _activeOccupantIndex = n);
    }

    Widget arrow(IconData icon, VoidCallback? onTap) {
      return Opacity(
        opacity: hasNav ? 1 : 0.35,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasNav ? onTap : null,
            // Refonte 2026-05-13 : pill radius 999 uniforme.
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 16, color: const Color(0xFF2B323A)),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FB), // mauve-50
        border: Border.all(color: const Color(0xFFF2ECF5)), // mauve-100
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          arrow(LucideIcons.chevronLeft, prev),
          Expanded(
            child: Center(
              child: Text(
                display,
                style: GoogleFonts.nunito(
                  fontSize: 17,
                  // w700 → w600 (demande user 2026-05-13 : nom occupant
                  // « moins épais »).
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                  height: 1.15,
                  color: const Color(0xFF0E1116),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Slot `extra` (cf. maquette visit-pages.js l.461-462) : permet
          // d'injecter un widget compact entre le nom et le chevron next.
          // Utilisé par Autonomie pour le bouton « Tout valider ».
          if (extra != null) ...[extra, const SizedBox(width: 4)],
          arrow(LucideIcons.chevronRight, next),
        ],
      ),
    );
  }

  /// Rangée de points (refonte 2026-05-13, visit-pages.js l.435-436) :
  /// active = pill 18×5 mauve-500, inactive = dot 5×5 ink-200.
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_contextOccupants.length, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _activeOccupantIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: isActive ? 18 : 5,
              height: 5,
              decoration: BoxDecoration(
                color: isActive
                    ? kBrandPurple // mauve-500
                    : const Color(0xFFE4E7EB), // ink-200
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildQuickNav() {
    return Container(
      // Fond violet pâle restauré (demande utilisateur 2026-04-29 :
      // les changements « pas de fond + trait pleine largeur » ne
      // concernent QUE la barre de navigation principale du relevé,
      // pas les sous-sections internes des onglets).
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: const Color(0xFFF2ECF5),
      child: Row(
        children: [
          Expanded(child: _buildNavBtn(LucideIcons.heart, 'Médicale', 0)),
          Expanded(child: _buildNavBtn(LucideIcons.user, 'Autonomie', 1)),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: SaveStatusIndicator(saving: _saving),
          ),
        ],
      ),
    );
  }

  Widget _buildNavBtn(IconData icon, String label, int index) {
    final active = _subSection == index;
    // Refonte 2026-05-13 (maquette user) : icon + texte en NOIR dans
    // les 2 états. Violet (#8B6FA0) uniquement sur le trait fin sous
    // l'item actif — seul différenciateur visuel. Parité avec
    // Bénéficiaire et Accessibilité.
    const labelColor = Color(0xFF0E1116); // ink-900
    const underlineColor = kBrandPurple; // mauve-500
    return SoftTapScale(
      onTap: () => _setSubSection(index),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              // 20 → 18 → 16 (demande user 2026-05-13).
              size: 16,
              color: labelColor,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                // 10 → 12 (demande user 2026-05-13).
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: labelColor,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 1.5,
              width: 28,
              decoration: BoxDecoration(
                color: active ? underlineColor : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Medical section
  // ---------------------------------------------------------------------------

  Widget _buildSoftListSurface({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FB),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }

  Widget _buildMedical() {
    final occ = _active;
    // Les cases à cocher Pathologie / Suivi / Sensoriel représentent
    // désormais les flags de la PAGE COURANTE de la note Médical —
    // poussés par le parent via [widget.currentMedicalFlags]. Quand
    // l'utilisateur change de page dans NotesWidget, ces cases se
    // rafraîchissent automatiquement.
    final pageFlags = widget.currentMedicalFlags ?? const <int>{};
    final flags = <_MedicalFlag>[
      _MedicalFlag(
        key: 'pathology',
        label: 'Pathologie',
        completed: pageFlags.contains(1),
      ),
      _MedicalFlag(
        key: 'followUp',
        label: 'Suivi médical',
        completed: pageFlags.contains(2),
      ),
      _MedicalFlag(
        key: 'sensory',
        label: 'Sensoriel',
        completed: pageFlags.contains(3),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sélecteur d'occupant retiré : l'occupant courant est désormais
        // identifié par le header du cadre + les points de pagination en
        // bas, avec navigation par swipe horizontal (parité Bénéficiaire).
        _buildSoftListSurface(
          child: Column(
            children: [
              for (var i = 0; i < flags.length; i++)
                _MedicalFlagRow(
                  index: i + 1,
                  label: flags[i].label,
                  completed: flags[i].completed,
                  onToggle: () => _toggleMedicalFlag(flags[i].key),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Titre "Mesures" + divider retirés — on garde juste les deux
        // champs Taille / Poids côte à côte.
        Row(
          children: [
            Expanded(
              child: FormNumberField(
                label: 'Taille',
                value: double.tryParse(
                  occ.medical.heightCm.replaceAll(',', '.'),
                ),
                unit: 'cm',
                onChanged: (v) =>
                    _updateMedical(heightCm: v?.toStringAsFixed(0) ?? ''),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FormNumberField(
                label: 'Poids',
                value: double.tryParse(
                  occ.medical.weightKg.replaceAll(',', '.'),
                ),
                unit: 'kg',
                onChanged: (v) =>
                    _updateMedical(weightKg: v?.toStringAsFixed(1) ?? ''),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Autonomy section
  // ---------------------------------------------------------------------------

  /// Première ligne de la liste Autonomie : libellé + bouton ✓ aligné
  /// exactement sur la colonne des autres boutons de validation.
  Widget _buildValidateAllRow() {
    final occ = _active;
    final total = kAutonomyItemNames.length;
    var allAutonomous = occ.autonomy.length == total;
    for (var i = 0; i < total && allAutonomous; i++) {
      if (!_itemState(i).autonomous) allAutonomous = false;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setAllAutonomyItems(!allAutonomous),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: kBrandPurple,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBrandPurple, width: 1),
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Personne autonome',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.25,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _GlobalAutonomyButton(active: allAutonomous),
            const SizedBox(width: 6),
            const SizedBox(width: 28),
            if (_occupantHomeHelpEnabled(_safeIndex)) ...[
              const SizedBox(width: 6),
              const SizedBox(width: 28),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAutonomy() {
    final occ = _active;
    final homeHelpEnabled = _occupantHomeHelpEnabled(_safeIndex);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildValidateAllRow(),
        const SizedBox(height: 10),
        _buildSoftListSurface(
          child: Column(
            children: [
              ...List.generate(occ.autonomy.length, (i) {
                final state = _itemState(i);
                return _NumberedCheckRow(
                  index: i + 1,
                  label: occ.autonomy[i].name,
                  state: state,
                  showHumanHelp: homeHelpEnabled,
                  onToggleAutonomous: () => _toggleAutonomyItem(i),
                  onToggleAttention: () => _toggleAttentionItem(i),
                  onToggleHumanHelp: () => _toggleHumanHelpItem(i),
                );
              }),
            ],
          ),
        ),
        // Texte de synthèse retiré 2026-05-13 sur demande utilisateur —
        // « Profil considéré comme autonome ! » / « Diagnostic complet ! »
        // n'apparait plus en bas de la liste (la maquette ne l'a pas).
      ],
    );
  }
}

/// État composite d'une ligne d'autonomie (modèle 2026-05-04).
/// `autonomous` et `attention` sont mutuellement exclusifs entre eux
/// (un seul des deux à la fois). `humanHelp` est indépendant et peut
/// coexister avec n'importe quel autre état.
///
/// `none` = `autonomous: false, attention: false, humanHelp: false`.
class _AutonomyItemState {
  final bool autonomous;
  final bool attention;
  final bool humanHelp;

  const _AutonomyItemState({
    this.autonomous = false,
    this.attention = false,
    this.humanHelp = false,
  });

  /// Vrai si aucune des trois coches n'est posée — utile pour
  /// `allFilled` dans `_buildAutonomy`.
  bool get isEmpty => !autonomous && !attention && !humanHelp;
}

// `_AutonomyValidateAllRow` retiré 2026-05-13 puis réintroduit en version
// alignée sur la liste le 2026-06-09 : libellé "personne autonome" +
// bouton ✓ dans la même colonne que les autres validations.

// =============================================================================
// Sub-widgets
// =============================================================================

class _MedicalFlag {
  final String key;
  final String label;
  final bool completed;
  const _MedicalFlag({
    required this.key,
    required this.label,
    required this.completed,
  });
}

class _MedicalFlagRow extends StatelessWidget {
  final int index;
  final String label;
  final bool completed;
  final VoidCallback onToggle;

  const _MedicalFlagRow({
    required this.index,
    required this.label,
    required this.completed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final rowBg = completed ? const Color(0xFFF2EDF5) : null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: rowBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                index.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6E5583),
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.25,
                  color: Color(0xFF1A1E24),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            _ActionButton(
              kind: _ActionButtonKind.autonomous,
              active: completed,
              disabled: false,
              onTap: onToggle,
            ),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'autonomie — numéro + libellé + 2 ou 3 boutons d'action.
///
/// Règles 2026-05-04 :
///   • `autonomous` (✓) et `attention` (!) sont mutuellement exclusifs
///     entre eux — un seul des deux à la fois.
///   • `humanHelp` (👥) est indépendant — peut être coché en plus
///     de `autonomous` ou `attention` sur la même ligne (demande
///     utilisateur : « même s'il y a une aide humaine sélectionnée,
///     possibilité de cocher une autre case sur la même ligne aussi »).
///   • Le bouton 👥 n'apparaît que si `showHumanHelp=true` (lié à
///     "Aide à domicile" dans Bénéficiaire > Santé).
///
/// Plus aucun bouton n'est désactivé : les 3 sont toujours cliquables
/// quand visibles.
class _NumberedCheckRow extends StatelessWidget {
  final int index;
  final String label;
  final _AutonomyItemState state;
  final bool showHumanHelp;
  final VoidCallback onToggleAutonomous;
  final VoidCallback onToggleAttention;
  final VoidCallback onToggleHumanHelp;

  const _NumberedCheckRow({
    required this.index,
    required this.label,
    required this.state,
    required this.showHumanHelp,
    required this.onToggleAutonomous,
    required this.onToggleAttention,
    required this.onToggleHumanHelp,
  });

  @override
  Widget build(BuildContext context) {
    // Refonte 2026-05-13 (visit-pages.js l.629-634) :
    //  - Plus de cercle lilas autour du numéro : juste un Text 12px
    //    mauve-600 tabular-nums centré sur 22 pt
    //  - Label 13.5px ink-800 prend l'espace restant
    //  - Boutons ✓ / ! ronds 28×28 (border-radius 9999)
    //  - Tint du row quand actif : mauve-tint si ok, red-tint si warn
    // Refonte 2026-05-15 (demande user) : priorité de tint sur le row :
    //   1. autonomous (✓)    → tint mauve, peu importe les autres
    //   2. attention (!)     → tint rouge, peu importe les autres
    //   3. humanHelp (👥) SEUL → tint jaune ambre (#FDF6E3, ambre saturé 8%)
    //   4. sinon (rien coché, ou combinaisons sans ✓/!) → pas de tint
    Color? rowBg;
    if (state.autonomous) {
      rowBg = const Color(0xFFF2EDF5); // mauve-50 saturé
    } else if (state.attention) {
      rowBg = const Color(0xFFFDEFEA); // red-50 saturé
    } else if (state.humanHelp) {
      rowBg = const Color(0xFFFDF6E3); // ambre saturé 8%
    }

    // Refonte 2026-05-13 (visit-pages.js l.1451-1456) : tap sur la ligne
    // entière = toggle ✓ « ok ». Les boutons internes (✓/!/👥) ont leur
    // propre GestureDetector qui intercepte le tap avant qu'il remonte.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggleAutonomous,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: rowBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            // Numéro sans pastille — juste du texte mauve-600 12px.
            SizedBox(
              width: 22,
              child: Text(
                index.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6E5583), // mauve-600
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Libellé de l'item.
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.25,
                  color: Color(0xFF1A1E24), // ink-800
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // Bouton ✓ rond — mauve-500 quand actif, blanc avec border ink-200 sinon.
            _ActionButton(
              kind: _ActionButtonKind.autonomous,
              active: state.autonomous,
              disabled: false,
              onTap: onToggleAutonomous,
            ),
            const SizedBox(width: 6),
            // Bouton ! rond — red #D85C42 quand actif.
            _ActionButton(
              kind: _ActionButtonKind.attention,
              active: state.attention,
              disabled: false,
              onTap: onToggleAttention,
            ),
            // Bouton 👥 "aide humaine" — feature legacy de l'app, non présente
            // dans la maquette. Affiché uniquement si Aide à domicile activée.
            if (showHumanHelp) ...[
              const SizedBox(width: 6),
              _ActionButton(
                kind: _ActionButtonKind.humanHelp,
                active: state.humanHelp,
                disabled: false,
                onTap: onToggleHumanHelp,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _ActionButtonKind { autonomous, attention, humanHelp }

class _GlobalAutonomyButton extends StatelessWidget {
  final bool active;

  const _GlobalAutonomyButton({required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: active ? Colors.white : Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.check,
        size: 14,
        color: active ? kBrandPurple : Colors.white,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final _ActionButtonKind kind;
  final bool active;
  final bool disabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.kind,
    required this.active,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Refonte 2026-05-13 (visit-pages.js l.632-633) :
    //   • Boutons ronds 28×28 (border-radius 9999, plus 8)
    //   • autonomous (✓) : actif mauve-500 #8B6FA0 / blanc avec border ink-200
    //   • attention (!) : actif red #D85C42 / blanc avec border ink-200,
    //     texte ! red foncé quand inactif
    //   • humanHelp (👥) : feature legacy hors-maquette, gardé en ambre
    Color activeFill;
    Color activeBorder;
    Color activeIcon;
    Color inactiveBg;
    Color inactiveBorder;
    Color inactiveIcon;
    IconData? icon;
    String? labelChar; // pour le ! (rendu en texte plutôt qu'icône)
    switch (kind) {
      case _ActionButtonKind.autonomous:
        activeFill = kBrandPurple;
        activeBorder = kBrandPurple;
        activeIcon = Colors.white;
        inactiveBg = Colors.white;
        inactiveBorder = const Color(0xFFE4E7EB); // ink-200
        inactiveIcon = const Color(0xFF8A939D); // ink-400
        icon = Icons.check;
        break;
      case _ActionButtonKind.attention:
        activeFill = const Color(0xFFD85C42);
        activeBorder = const Color(0xFFD85C42);
        activeIcon = Colors.white;
        inactiveBg = Colors.white;
        inactiveBorder = const Color(0xFFE4E7EB);
        inactiveIcon = const Color(0xFFD85C42);
        labelChar = '!';
        break;
      case _ActionButtonKind.humanHelp:
        // Refonte 2026-05-15 (demande user) : aligné sur ✓/! — border
        // ink-200 quand inactif, fond ambre saturé + icône blanche
        // quand actif. Plus de cerclage jaune permanent autour du
        // bouton — il a la même apparence visuelle « plate » que les
        // autres pour ne pas attirer l'œil quand il n'est pas coché.
        activeFill = const Color(0xFFF5C449); // ambre saturé
        activeBorder = const Color(0xFFF5C449);
        activeIcon = Colors.white;
        inactiveBg = Colors.white;
        inactiveBorder = const Color(0xFFE4E7EB); // ink-200
        inactiveIcon = const Color(0xFF8A939D); // ink-400
        icon = Icons.accessibility_new;
        break;
    }

    final bg = active ? activeFill : inactiveBg;
    final border = active ? activeBorder : inactiveBorder;
    final iconColor = active ? activeIcon : inactiveIcon;
    final opacity = disabled ? 0.35 : 1.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: opacity,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 1),
          ),
          alignment: Alignment.center,
          child: labelChar != null
              ? Text(
                  labelChar,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: iconColor,
                    height: 1,
                  ),
                )
              : Icon(icon!, size: 14, color: iconColor),
        ),
      ),
    );
  }
}

// _AnimatedSquareCheckbox retiré 2026-05-13 — promu en `VpCheckboxSquare`
// partagé dans `lib/components/form_widgets.dart` pour pouvoir être
// réutilisé dans les autres tabs du relevé.
