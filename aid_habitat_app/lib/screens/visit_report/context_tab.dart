import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';

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

  const ContextTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onMedicalFlagToggled,
    this.currentMedicalFlags,
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
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  late List<OccupantAutonomy> _contextOccupants;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ContextTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the parent pushes a refreshed dossier (e.g. after the user
    // changed a name in the Bénéficiaire tab), re-derive the context
    // occupants so the pills and names shown here track the new values.
    final oldP = oldWidget.dossier.patient;
    final newP = widget.dossier.patient;
    final nameChanged = oldP.firstName != newP.firstName ||
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
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final data =
        await widget.repository.fetchContexteDeVie(widget.dossier.id);

    AutonomyData autonomy = const AutonomyData();
    MedicalContext medical = const MedicalContext();
    if (data != null) {
      if (data['medicalContext'] != null) {
        medical = MedicalContext.fromJson(
            data['medicalContext'] as Map<String, dynamic>);
      }
      if (data['autonomy'] != null) {
        autonomy =
            AutonomyData.fromJson(data['autonomy'] as Map<String, dynamic>);
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
      final existing =
          i < autonomy.occupants.length ? autonomy.occupants[i] : null;

      final homeHelpTxt = _occupantHomeHelpText(i);

      if (existing != null) {
        out.add(OccupantAutonomy(
          medical: existing.medical,
          autonomyDone: existing.autonomyDone,
          autonomy: _mergeAutonomyItems(existing.autonomy),
          humanHelp: _mergeHumanHelpItems(existing.humanHelp, homeHelpTxt),
          attention: _mergeAutonomyItems(existing.attention),
        ));
      } else {
        out.add(OccupantAutonomy(
          medical: i == 0 ? medical : const MedicalContext(),
          autonomyDone: i == 0 ? autonomy.done : false,
          autonomy: _mergeAutonomyItems(i == 0 ? autonomy.checklist : const []),
          humanHelp: _mergeHumanHelpItems(const [], homeHelpTxt),
          attention: _mergeAutonomyItems(const []),
        ));
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
        .map((name) =>
            map[name] ?? AutonomyItem(name: name))
        .toList();
  }

  /// Reconstitue la liste des 11 items humanHelp à partir d'un texte
  /// séparé par virgules (comme React `parseHumanHelpItems`).
  List<AutonomyItem> _mergeHumanHelpItems(
      List<AutonomyItem> existing, String rawHomeHelpTxt) {
    if (existing.isNotEmpty) {
      final map = {for (final e in existing) e.name: e};
      return kAutonomyItemNames
          .map((name) => map[name] ?? AutonomyItem(name: name))
          .toList();
    }
    final normalized = rawHomeHelpTxt.toLowerCase();
    return kAutonomyItemNames
        .map((name) => AutonomyItem(
              name: name,
              checked: normalized.contains(name.toLowerCase()),
            ))
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

  void _updateMedical(
      {String? pathology,
      String? followUp,
      String? sensory,
      String? heightCm,
      String? weightKg}) {
    final occ = _active;
    final m = occ.medical;
    _updateActive(OccupantAutonomy(
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
    ));
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

  /// Détermine l'état courant d'un item d'autonomie (mutuellement
  /// exclusif entre les 3 listes : autonomous / attention / humanHelp).
  _AutonomyItemState _itemState(int index) {
    final occ = _active;
    if (index < occ.autonomy.length && occ.autonomy[index].checked) {
      return _AutonomyItemState.autonomous;
    }
    if (index < occ.attention.length && occ.attention[index].checked) {
      return _AutonomyItemState.attention;
    }
    if (index < occ.humanHelp.length && occ.humanHelp[index].checked) {
      return _AutonomyItemState.humanHelp;
    }
    return _AutonomyItemState.none;
  }

  /// Pose un état pour l'item `index` en garantissant la mutex : les
  /// deux autres listes sont forcées à `checked=false` à cet index.
  /// Met aussi à jour `autonomyDone` automatiquement : true ssi tous
  /// les items sont marqués `autonomous` (✓).
  void _setAutonomyItemState(int index, _AutonomyItemState state) {
    final occ = _active;
    final auto = List<AutonomyItem>.from(occ.autonomy);
    final help = List<AutonomyItem>.from(occ.humanHelp);
    final att = List<AutonomyItem>.from(occ.attention);
    if (index < auto.length) {
      auto[index] = AutonomyItem(
        name: auto[index].name,
        checked: state == _AutonomyItemState.autonomous,
      );
    }
    if (index < att.length) {
      att[index] = AutonomyItem(
        name: att[index].name,
        checked: state == _AutonomyItemState.attention,
      );
    }
    if (index < help.length) {
      help[index] = AutonomyItem(
        name: help[index].name,
        checked: state == _AutonomyItemState.humanHelp,
      );
    }
    // Autonomy "done" dérivé : vrai uniquement quand TOUS les items
    // sont marqués `autonomous` (le texte "profil considéré comme
    // autonome" apparaîtra dans le résumé en bas de section).
    final allAutonomous =
        auto.length == kAutonomyItemNames.length && auto.every((i) => i.checked);
    _updateActive(OccupantAutonomy(
      medical: occ.medical,
      autonomyDone: allAutonomous,
      autonomy: auto,
      humanHelp: help,
      attention: att,
    ));
  }

  void _toggleAutonomyItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      current == _AutonomyItemState.autonomous
          ? _AutonomyItemState.none
          : _AutonomyItemState.autonomous,
    );
  }

  void _toggleAttentionItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      current == _AutonomyItemState.attention
          ? _AutonomyItemState.none
          : _AutonomyItemState.attention,
    );
  }

  void _toggleHumanHelpItem(int index) {
    final current = _itemState(index);
    _setAutonomyItemState(
      index,
      current == _AutonomyItemState.humanHelp
          ? _AutonomyItemState.none
          : _AutonomyItemState.humanHelp,
    );
  }

  // ---------------------------------------------------------------------------
  // Save (debounced)
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);
    final primary = _contextOccupants.isNotEmpty
        ? _contextOccupants.first
        : const OccupantAutonomy();
    final autonomy = AutonomyData(
      done: primary.autonomyDone,
      checklist: primary.autonomy,
      occupants: _contextOccupants,
    );
    try {
      await widget.repository.upsertContexteDeVie(
        widget.dossier.id,
        widget.dossier.patient.id,
        medicalContext: primary.medical,
        autonomy: autonomy,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  int get _safeIndex {
    if (_contextOccupants.isEmpty) return 0;
    return _activeOccupantIndex
        .clamp(0, _contextOccupants.length - 1)
        .toInt();
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
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Swipe horizontal pour changer d'occupant (parité avec
            // l'onglet Bénéficiaire). Désactivé quand il n'y a qu'une
            // seule personne dans le foyer.
            onHorizontalDragEnd: !hasMultiple
                ? null
                : (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity.abs() < 200) return;
                    setState(() {
                      if (velocity < 0) {
                        _activeOccupantIndex =
                            (idx + 1) % _contextOccupants.length;
                      } else {
                        _activeOccupantIndex = (idx - 1 +
                                _contextOccupants.length) %
                            _contextOccupants.length;
                      }
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
                            padding:
                                const EdgeInsets.fromLTRB(20, 16, 20, 12),
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
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

  /// Header affichant Prénom + NOM de l'occupant courant (violet foncé).
  /// Mis à jour à chaque swipe / tap sur un point.
  Widget _buildOccupantHeader(int idx) {
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
        : [first, last.toUpperCase()]
            .where((s) => s.isNotEmpty)
            .join(' ');
    return Text(
      display,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: Color(0xFF0F172A),
        letterSpacing: -0.2,
      ),
    );
  }

  /// Rangée de points centrée — un point par occupant, le courant en
  /// violet plein, les autres en gris lilas.
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_contextOccupants.length, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _activeOccupantIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: isActive ? 10 : 8,
              height: isActive ? 10 : 8,
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0xFF7C6DAA)
                    : const Color(0xFFD8CFE0),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildQuickNav() {
    return Container(
      // Padding horizontal retiré : chaque zone cliquable s'étend
      // bord à bord (demande utilisateur — 50 % Médical / 50 % Autonomie
      // sans marge intermédiaire).
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: const Color(0xFFEDE8F5),
      child: Row(
        children: [
          Expanded(
            child: _buildNavBtn(LucideIcons.heart, 'Médicale', 0),
          ),
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
    // Sur fond violet clair (#EDE8F5), texte + trait actifs passent en
    // violet foncé (#7C6DAA) pour contraster sans être agressif. Inactif
    // : pastel lilas #AE9DB3. Layout vertical (icône au-dessus du texte)
    // pour parité visuelle avec les sous-sections de Bénéficiaire.
    const activeColor = Color(0xFF7C6DAA);
    const inactiveColor = Color(0xFFAE9DB3);
    // SoftTapScale → zoom/dezoom à l'appui, même effet que les boutons
    // de la sidebar et des tabs du relevé de visite.
    return SoftTapScale(
      onTap: () => setState(() => _subSection = index),
      child: Container(
        // Fond transparent garanti sur toute la largeur de l'Expanded
        // pour que la zone de tap reste identique au GestureDetector
        // précédent (HitTestBehavior.opaque).
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: active ? activeColor : inactiveColor,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: active ? activeColor : inactiveColor,
              ),
            ),
            // Trait fin centré sous le texte, visible uniquement pour la
            // sous-section active.
            const SizedBox(height: 6),
            Container(
              height: 1.5,
              width: 28,
              decoration: BoxDecoration(
                color: active ? activeColor : Colors.transparent,
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
          completed: pageFlags.contains(1)),
      _MedicalFlag(
          key: 'followUp',
          label: 'Suivi médical',
          completed: pageFlags.contains(2)),
      _MedicalFlag(
          key: 'sensory',
          label: 'Sensoriel',
          completed: pageFlags.contains(3)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sélecteur d'occupant retiré : l'occupant courant est désormais
        // identifié par le header du cadre + les points de pagination en
        // bas, avec navigation par swipe horizontal (parité Bénéficiaire).
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(16),
          ),
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
                    occ.medical.heightCm.replaceAll(',', '.')),
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
                    occ.medical.weightKg.replaceAll(',', '.')),
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

  Widget _buildAutonomy() {
    final occ = _active;
    final homeHelpEnabled = _occupantHomeHelpEnabled(_safeIndex);
    // Statuts dérivés :
    //   • tous les items ont une coche (quelle qu'elle soit) → diagnostic complet
    //   • tous les items sont spécifiquement en "autonomous" (✓) → profil autonome
    final total = kAutonomyItemNames.length;
    var allFilled = occ.autonomy.length == total;
    var allAutonomous = allFilled;
    for (var i = 0; i < total; i++) {
      final state = _itemState(i);
      if (state == _AutonomyItemState.none) {
        allFilled = false;
        allAutonomous = false;
        break;
      }
      if (state != _AutonomyItemState.autonomous) {
        allAutonomous = false;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pills occupants retirées — navigation désormais via le
        // header + les points de pagination en bas du cadre.
        // Badge "Aide humaine" conservé comme indicateur de statut.
        if (homeHelpEnabled)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'Aide humaine',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFB45309),
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        if (homeHelpEnabled) const SizedBox(height: 12),
        // Liste des 11 items avec 2 ou 3 boutons par ligne (✓ / ! / 👥).
        // Un seul état possible par ligne (mutex). Quand 👥 (aide humaine)
        // est coché pour une ligne, les boutons ✓ et ! sont désactivés.
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: List.generate(occ.autonomy.length, (i) {
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
          ),
        ),
        // Texte de synthèse : "diagnostic complet" dès que chaque ligne
        // a reçu une coche ; devient "profil considéré comme autonome"
        // quand TOUTES les coches sont du type ✓.
        if (allFilled) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: allAutonomous
                  ? const Color(0xFF7C6DAA).withValues(alpha: 0.10)
                  : const Color(0xFFEDE8F5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              allAutonomous
                  ? 'Profil considéré comme autonome !'
                  : 'Diagnostic complet !',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF554A63),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// États mutuellement exclusifs possibles pour une ligne d'autonomie.
enum _AutonomyItemState { none, autonomous, attention, humanHelp }

// =============================================================================
// Sub-widgets
// =============================================================================

class _MedicalFlag {
  final String key;
  final String label;
  final bool completed;
  const _MedicalFlag(
      {required this.key, required this.label, required this.completed});
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
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            // Square checkbox with visible border
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color:
                    completed ? const Color(0xFF7C6DAA) : Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: completed
                      ? const Color(0xFF7C6DAA)
                      : const Color(0xFFCBD5E1),
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.check,
                size: 12,
                color: completed ? Colors.white : Colors.transparent,
              ),
            ),
            const SizedBox(width: 10),
            // Numbered circle
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: completed
                    ? const Color(0xFFE9DFF0)
                    : const Color(0xFFEDE8F5),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                index.toString().padLeft(2, '0'),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF554A63),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: completed ? FontWeight.w500 : FontWeight.w600,
                  color: completed
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF334155),
                  decoration:
                      completed ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'autonomie — numéro + libellé + 2 ou 3 boutons d'action
/// mutuellement exclusifs (✓ autonome, ! à revoir, 👥 aide humaine).
///
/// Règles :
///   • Un seul bouton peut être coché par ligne (mutex).
///   • Le bouton 👥 n'apparaît que si `showHumanHelp=true` (lié à
///     "Aide à domicile" dans Bénéficiaire > Santé).
///   • Quand l'état est `humanHelp`, les boutons ✓ et ! sont affichés
///     désactivés (non cliquables).
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
    final isAutonomous = state == _AutonomyItemState.autonomous;
    final isAttention = state == _AutonomyItemState.attention;
    final isHumanHelp = state == _AutonomyItemState.humanHelp;
    final lockedByHumanHelp = isHumanHelp;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          // Numéro dans un cercle lilas.
          Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              color: Color(0xFFEDE8F5),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              index.toString(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Color(0xFF554A63),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Libellé de l'item (prend l'espace restant).
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF334155),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Bouton ✓ "autonome".
          _ActionButton(
            kind: _ActionButtonKind.autonomous,
            active: isAutonomous,
            disabled: lockedByHumanHelp,
            onTap: onToggleAutonomous,
          ),
          const SizedBox(width: 6),
          // Bouton ! "à revoir".
          _ActionButton(
            kind: _ActionButtonKind.attention,
            active: isAttention,
            disabled: lockedByHumanHelp,
            onTap: onToggleAttention,
          ),
          // Bouton 👥 "aide humaine" — visible uniquement quand "Aide
          // à domicile" est activée pour cet occupant.
          if (showHumanHelp) ...[
            const SizedBox(width: 6),
            _ActionButton(
              kind: _ActionButtonKind.humanHelp,
              active: isHumanHelp,
              disabled: false,
              onTap: onToggleHumanHelp,
            ),
          ],
        ],
      ),
    );
  }
}

enum _ActionButtonKind { autonomous, attention, humanHelp }

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
    // Palette par type :
    //   • autonomous (✓) : violet foncé #7C6DAA
    //   • attention (!)  : pêche #F5D6B8 / #C2410C
    //   • humanHelp (👥) : ambre #F59E0B
    Color activeFill;
    Color activeBorder;
    Color activeIcon;
    Color inactiveBorder;
    Color inactiveIcon;
    IconData icon;
    switch (kind) {
      case _ActionButtonKind.autonomous:
        activeFill = const Color(0xFF7C6DAA);
        activeBorder = const Color(0xFF7C6DAA);
        activeIcon = Colors.white;
        inactiveBorder = const Color(0xFFD8CFE0);
        inactiveIcon = const Color(0xFF7C6DAA);
        icon = Icons.check;
        break;
      case _ActionButtonKind.attention:
        activeFill = const Color(0xFFF5D6B8);
        activeBorder = const Color(0xFFF5D6B8);
        activeIcon = const Color(0xFFC2410C);
        inactiveBorder = const Color(0xFFD8CFE0);
        inactiveIcon = const Color(0xFFC2410C);
        icon = Icons.priority_high;
        break;
      case _ActionButtonKind.humanHelp:
        activeFill = const Color(0xFFFEF3C7);
        activeBorder = const Color(0xFFF59E0B);
        activeIcon = const Color(0xFFB45309);
        inactiveBorder = const Color(0xFFFCD34D);
        inactiveIcon = const Color(0xFFB45309);
        icon = Icons.accessibility_new;
        break;
    }

    final bg = active ? activeFill : Colors.white;
    final border = active ? activeBorder : inactiveBorder;
    final iconColor = active ? activeIcon : inactiveIcon;
    final opacity = disabled ? 0.35 : 1.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: opacity,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border, width: 1.5),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16, color: iconColor),
        ),
      ),
    );
  }
}
