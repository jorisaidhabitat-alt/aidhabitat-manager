import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

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
        ));
      } else {
        out.add(OccupantAutonomy(
          medical: i == 0 ? medical : const MedicalContext(),
          autonomyDone: i == 0 ? autonomy.done : false,
          autonomy: _mergeAutonomyItems(i == 0 ? autonomy.checklist : const []),
          humanHelp: _mergeHumanHelpItems(const [], homeHelpTxt),
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

  void _toggleAutonomyDone() {
    final occ = _active;
    final nextDone = !occ.autonomyDone;
    final autonomyItems = occ.autonomy
        .map((i) => AutonomyItem(name: i.name, checked: nextDone ? true : i.checked))
        .toList();
    final humanHelpItems = nextDone
        ? kAutonomyItemNames.map((n) => AutonomyItem(name: n)).toList()
        : occ.humanHelp;
    _updateActive(OccupantAutonomy(
      medical: occ.medical,
      autonomyDone: nextDone,
      autonomy: autonomyItems,
      humanHelp: humanHelpItems,
    ));
  }

  void _toggleAutonomyItem(int index) {
    final occ = _active;
    final items = List<AutonomyItem>.from(occ.autonomy);
    final current = items[index];
    final nextChecked = !current.checked;
    items[index] = AutonomyItem(name: current.name, checked: nextChecked);

    // If marking as "non concerné" (checked=true), clear paired humanHelp
    final humanHelp = List<AutonomyItem>.from(occ.humanHelp);
    if (nextChecked && index < humanHelp.length) {
      humanHelp[index] =
          AutonomyItem(name: humanHelp[index].name, checked: false);
    }

    // If every item is checked, auto-set autonomyDone
    final allChecked = items.every((i) => i.checked);

    _updateActive(OccupantAutonomy(
      medical: occ.medical,
      autonomyDone: allChecked ? true : occ.autonomyDone,
      autonomy: items,
      humanHelp: humanHelp,
    ));
  }

  void _toggleHumanHelpItem(int index) {
    final occ = _active;
    if (index >= occ.humanHelp.length) return;
    final items = List<AutonomyItem>.from(occ.humanHelp);
    final current = items[index];
    items[index] = AutonomyItem(name: current.name, checked: !current.checked);
    _updateActive(OccupantAutonomy(
      medical: occ.medical,
      autonomyDone: occ.autonomyDone,
      autonomy: occ.autonomy,
      humanHelp: items,
    ));
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

  List<String> get _occupantLabels {
    final p = widget.dossier.patient;
    final names = <String>[];
    for (var i = 0; i < _contextOccupants.length; i++) {
      String first = i == 0 ? p.firstName : '';
      if (i > 0 && i < p.occupants.length) {
        first = p.occupants[i].firstName;
      }
      names.add(first.isNotEmpty
          ? first.split(' ').first
          : 'Profil ${String.fromCharCode(65 + (i % 26))}');
    }
    return names;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: SaveStatusIndicator(saving: _saving),
          ),
          const SizedBox(height: 4),
          _buildQuickNav(),
          const SizedBox(height: 16),
          if (_subSection == 0) _buildMedical() else _buildAutonomy(),
        ],
      ),
    );
  }

  Widget _buildQuickNav() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFF6EDFB),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildNavBtn(LucideIcons.heart, 'Médical', 0),
          ),
          const SizedBox(width: 4),
          Expanded(child: _buildNavBtn(LucideIcons.user, 'Autonomie', 1)),
        ],
      ),
    );
  }

  Widget _buildNavBtn(IconData icon, String label, int index) {
    final active = _subSection == index;
    return GestureDetector(
      onTap: () => setState(() => _subSection = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        // Pas de pill individuel : le fond unifié du parent _buildQuickNav
        // suffit. La sélection se voit par la couleur texte/icône.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? Colors.black : const Color(0xFFAE9DB3),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.black : const Color(0xFFAE9DB3),
                ),
                overflow: TextOverflow.ellipsis,
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
        // Titre "Médical" retiré. Sélecteur d'occupant conservé à droite
        // quand le foyer a plusieurs personnes.
        if (_occupantLabels.length > 1) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OccupantSwitcher(
                title: '',
                occupantLabels: _occupantLabels,
                activeIndex: _safeIndex,
                onChanged: (i) => setState(() => _activeOccupantIndex = i),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
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
    final locked = occ.autonomyDone;
    final homeHelpEnabled = _occupantHomeHelpEnabled(_safeIndex) && !locked;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Ligne 1 : bouton valider + titre AUTONOMIE.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _toggleAutonomyDone,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: locked ? const Color(0xFF907CA1) : Colors.white,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.check,
                  size: 14,
                  color: locked
                      ? Colors.white
                      : const Color(0xFF907CA1).withValues(alpha: 0.55),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'AUTONOMIE',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF597E8D),
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Ligne 2 : pills occupants (toujours côte à côte) + badge "Aide
        // humaine" optionnel à droite. Même quand il n'y a pas de badge, les
        // pills restent sur cette ligne.
        if (_occupantLabels.length > 1 || homeHelpEnabled)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
                if (_occupantLabels.length > 1)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_occupantLabels.length, (i) {
                      final active = i == _safeIndex;
                      return Padding(
                        padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _activeOccupantIndex = i),
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 64),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFFF6EDFB)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _occupantLabels[i],
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: active
                                    ? const Color(0xFF554A63)
                                    : const Color(0xFF94A3B8),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
              if (homeHelpEnabled) ...[
                if (_occupantLabels.length > 1) const SizedBox(width: 8),
                Container(
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
              ],
            ],
          ),
        const SizedBox(height: 12),
        Opacity(
          opacity: locked ? 0.55 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: List.generate(occ.autonomy.length, (i) {
                final item = occ.autonomy[i];
                final helpItem =
                    i < occ.humanHelp.length ? occ.humanHelp[i] : null;
                final helpIsChecked = helpItem?.checked ?? false;
                return _NumberedCheckRow(
                  index: i + 1,
                  label: item.name,
                  concernChecked: item.checked,
                  onConcernToggle: (locked || helpIsChecked)
                      ? null
                      : () => _toggleAutonomyItem(i),
                  helpChecked: !item.checked && helpIsChecked,
                  helpEnabled: homeHelpEnabled && !item.checked,
                  onHelpToggle: () => _toggleHumanHelpItem(i),
                );
              }),
            ),
          ),
        ),
        if (locked) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF907CA1).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'La personne est considérée autonome sur l’ensemble de cette section.',
              textAlign: TextAlign.center,
              style: TextStyle(
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
                    completed ? const Color(0xFF907CA1) : Colors.white,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: completed
                      ? const Color(0xFF907CA1)
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
                    : const Color(0xFFF6EDFB),
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

class _NumberedCheckRow extends StatelessWidget {
  final int index;
  final String label;
  final bool concernChecked;
  final VoidCallback? onConcernToggle;
  final bool helpChecked;
  final bool helpEnabled;
  final VoidCallback onHelpToggle;

  const _NumberedCheckRow({
    required this.index,
    required this.label,
    required this.concernChecked,
    required this.onConcernToggle,
    required this.helpChecked,
    required this.helpEnabled,
    required this.onHelpToggle,
  });

  @override
  Widget build(BuildContext context) {
    // Coche "concerné/fait" — visuel conservé, toute la zone de la
    // ligne (coche + numéro + libellé) est cliquable pour faciliter
    // le toucher sur tablette.
    final concernCheckbox = Builder(builder: (_) {
      final disabled = onConcernToggle == null;
      Color fillColor;
      Color borderColor;
      if (disabled && !concernChecked) {
        fillColor = const Color(0xFFF1F5F9);
        borderColor = const Color(0xFFE2E8F0);
      } else if (concernChecked) {
        fillColor = const Color(0xFF94A3B8);
        borderColor = const Color(0xFF94A3B8);
      } else {
        fillColor = Colors.white;
        borderColor = const Color(0xFF907CA1);
      }
      return Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.check,
          size: 12,
          color: concernChecked ? Colors.white : Colors.transparent,
        ),
      );
    });

    final rowContent = Row(
      children: [
        concernCheckbox,
        const SizedBox(width: 10),
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: concernChecked
                ? Colors.white
                : const Color(0xFFE9DFF0),
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
              color: concernChecked
                  ? const Color(0xFF94A3B8)
                  : const Color(0xFF334155),
              decoration:
                  concernChecked ? TextDecoration.lineThrough : null,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onConcernToggle,
              child: rowContent,
            ),
          ),
          if (helpEnabled)
            GestureDetector(
              onTap: onHelpToggle,
              behavior: HitTestBehavior.opaque,
              // Zone de toucher agrandie (20px réels autour de la
              // coche) pour faciliter le clic sur tablette, sans
              // grossir la coche elle-même.
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: helpChecked
                        ? const Color(0xFFFEF3C7)
                        : const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: helpChecked
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFFFCD34D),
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.check,
                    size: 12,
                    color: helpChecked
                        ? const Color(0xFFB45309)
                        : Colors.transparent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
