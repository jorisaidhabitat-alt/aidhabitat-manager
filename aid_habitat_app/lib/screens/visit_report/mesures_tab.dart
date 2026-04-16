import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

class MesuresTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const MesuresTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<MesuresTab> createState() => _MesuresTabState();
}

class _MesuresTabState extends State<MesuresTab> {
  MesuresAnthropometriques? _mesures;
  bool _saving = false;
  Timer? _saveTimer;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadMesures();
  }

  Future<void> _loadMesures() async {
    final result = await widget.repository.fetchMesures(widget.dossier.id);
    if (!mounted) return;
    setState(() {
      _mesures = result ??
          MesuresAnthropometriques(dossierId: widget.dossier.id);
      _loaded = true;
    });
  }

  void _onFieldChanged(MesuresAnthropometriques updated) {
    setState(() => _mesures = updated);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (_mesures == null) return;
    setState(() => _saving = true);
    await widget.repository.upsertMesures(widget.dossier.id, _mesures!);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final mesures = _mesures!;

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- Position debout ---
              Text(
                'Position debout',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              FormNumberField(
                label: 'Hauteur coude fl\u00e9chi',
                value: mesures.deboutHauteurCoude,
                unit: 'cm',
                onChanged: (v) => _onFieldChanged(
                  MesuresAnthropometriques(
                    dossierId: mesures.dossierId,
                    deboutHauteurCoude: v,
                    assisHauteurAssise: mesures.assisHauteurAssise,
                    assisProfondeurGenoux: mesures.assisProfondeurGenoux,
                    assisHauteurCoudes: mesures.assisHauteurCoudes,
                    observations: mesures.observations,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // --- Position assise ---
              Text(
                'Position assise',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              FormNumberField(
                label: "Hauteur d'assise",
                value: mesures.assisHauteurAssise,
                unit: 'cm',
                onChanged: (v) => _onFieldChanged(
                  MesuresAnthropometriques(
                    dossierId: mesures.dossierId,
                    deboutHauteurCoude: mesures.deboutHauteurCoude,
                    assisHauteurAssise: v,
                    assisProfondeurGenoux: mesures.assisProfondeurGenoux,
                    assisHauteurCoudes: mesures.assisHauteurCoudes,
                    observations: mesures.observations,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FormNumberField(
                label: 'Profondeur genoux',
                value: mesures.assisProfondeurGenoux,
                unit: 'cm',
                onChanged: (v) => _onFieldChanged(
                  MesuresAnthropometriques(
                    dossierId: mesures.dossierId,
                    deboutHauteurCoude: mesures.deboutHauteurCoude,
                    assisHauteurAssise: mesures.assisHauteurAssise,
                    assisProfondeurGenoux: v,
                    assisHauteurCoudes: mesures.assisHauteurCoudes,
                    observations: mesures.observations,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FormNumberField(
                label: 'Hauteur coudes assis',
                value: mesures.assisHauteurCoudes,
                unit: 'cm',
                onChanged: (v) => _onFieldChanged(
                  MesuresAnthropometriques(
                    dossierId: mesures.dossierId,
                    deboutHauteurCoude: mesures.deboutHauteurCoude,
                    assisHauteurAssise: mesures.assisHauteurAssise,
                    assisProfondeurGenoux: mesures.assisProfondeurGenoux,
                    assisHauteurCoudes: v,
                    observations: mesures.observations,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // --- Observations ---
              Text(
                'Observations',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              FormTextField(
                label: 'Observations',
                value: mesures.observations,
                maxLines: 4,
                onChanged: (v) => _onFieldChanged(
                  MesuresAnthropometriques(
                    dossierId: mesures.dossierId,
                    deboutHauteurCoude: mesures.deboutHauteurCoude,
                    assisHauteurAssise: mesures.assisHauteurAssise,
                    assisProfondeurGenoux: mesures.assisProfondeurGenoux,
                    assisHauteurCoudes: mesures.assisHauteurCoudes,
                    observations: v,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_saving)
          const Positioned(
            top: 8,
            right: 8,
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}
