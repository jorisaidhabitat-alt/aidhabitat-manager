import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/form_widgets.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';
import '../../services/save_debounce.dart';

/// Onglet « Observations » du relevé de visite — alimente :
///   - Page 6 du PDF : « Observation sur les équipements et utilisation »
///     (champ `obs` du template)
///   - Page 7 du PDF : « Projet ou souhait de l'usager » + « Résumé des
///     préconisations »
///
/// Trois `TextField` multilignes branchés sur `observations_synthese` via
/// [DataService.upsertObservations]. Save débouncé à 400 ms — laisse les
/// pauses de frappe naturelles passer sans déclencher 50 sync_op pour
/// un seul mot tapé.
///
/// Avant cet onglet, la table `observations_synthese` n'avait AUCUN
/// chemin d'écriture utilisateur — seules les lectures fonctionnaient
/// (note rapide en haut du dossier). Conséquence visible : les pages 6
/// et 7 du rapport PDF restaient vides quoi que l'ergo écrive.
class ObservationsTab extends StatefulWidget {
  final Dossier dossier;

  const ObservationsTab({super.key, required this.dossier});

  @override
  State<ObservationsTab> createState() => _ObservationsTabState();
}

class _ObservationsTabState extends State<ObservationsTab>
    with AutomaticKeepAliveClientMixin {
  final DataService _dataService = DataService();

  bool _isLoading = true;
  Timer? _saveTimer;

  String _projetSouhaitUsage = '';
  String _resumePreconisations = '';
  String _observationEquipements = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadObservations();
  }

  @override
  void dispose() {
    // Flush des éventuelles modifs en attente du debounce — sinon
    // l'utilisateur tape, change de tab avant les 400 ms et perd sa
    // saisie. dispose synchrone donc on tente un last-shot sans
    // attendre.
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      // ignore: discarded_futures
      _save();
    } else {
      _saveTimer?.cancel();
    }
    super.dispose();
  }

  Future<void> _loadObservations() async {
    final obs = await _dataService.fetchObservations(widget.dossier.id);
    if (!mounted) return;
    setState(() {
      _projetSouhaitUsage = obs.projetSouhaitUsage;
      _resumePreconisations = obs.resumePreconisations;
      _observationEquipements = obs.observationEquipements;
      _isLoading = false;
    });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(kSaveDebounceText, _save);
  }

  Future<void> _save() async {
    await _dataService.upsertObservations(
      widget.dossier.id,
      ObservationsSynthese(
        dossierId: widget.dossier.id,
        projetSouhaitUsage: _projetSouhaitUsage,
        resumePreconisations: _resumePreconisations,
        observationEquipements: _observationEquipements,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: ListView(
        children: [
          _Section(
            title: 'Projet ou souhait de l’usager',
            subtitle:
                'Ce que le bénéficiaire souhaite obtenir grâce à la visite '
                '(maintien à domicile, aménagement spécifique, plus '
                'd’autonomie pour la toilette…). Apparaîtra page 7 du '
                'rapport.',
            child: FormTextField(
              label: '',
              value: _projetSouhaitUsage,
              maxLines: 6,
              onChanged: (v) {
                _projetSouhaitUsage = v;
                _scheduleSave();
              },
            ),
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'Résumé des préconisations',
            subtitle:
                'Synthèse rédigée des préconisations majeures à présenter en '
                'amont du détail. Apparaîtra page 7 du rapport, juste sous '
                'le projet usager.',
            child: FormTextField(
              label: '',
              value: _resumePreconisations,
              maxLines: 8,
              onChanged: (v) {
                _resumePreconisations = v;
                _scheduleSave();
              },
            ),
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'Observations sur les équipements et utilisation',
            subtitle:
                'Difficultés rencontrées, besoins non couverts par les '
                'équipements actuels (sanitaires, escalier, mobilier…). '
                'Apparaîtra page 6 du rapport, sous le tableau Portes des '
                'sanitaires.',
            child: FormTextField(
              label: '',
              value: _observationEquipements,
              maxLines: 6,
              onChanged: (v) {
                _observationEquipements = v;
                _scheduleSave();
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section helper — titre + sous-titre violet + champ
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF7C6DAA),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF64748B),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
