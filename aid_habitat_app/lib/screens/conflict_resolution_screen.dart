import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/brand_colors.dart';
import '../models/types.dart';
import '../services/data_service.dart';

class ConflictResolutionScreen extends StatefulWidget {
  final Dossier localDossier;
  final VoidCallback onResolved;

  const ConflictResolutionScreen({
    super.key,
    required this.localDossier,
    required this.onResolved,
  });

  @override
  State<ConflictResolutionScreen> createState() =>
      _ConflictResolutionScreenState();
}

class _ConflictResolutionScreenState extends State<ConflictResolutionScreen> {
  final _dataService = DataService();
  Dossier? _remoteDossier;
  bool _loading = true;
  String? _error;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _fetchRemote();
  }

  Future<void> _fetchRemote() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final remote =
        await _dataService.fetchRemoteDossierById(widget.localDossier.id);
    if (!mounted) return;
    setState(() {
      _remoteDossier = remote;
      _loading = false;
      if (remote == null) _error = 'Impossible de r\u00e9cup\u00e9rer la version distante.';
    });
  }

  Future<void> _keepLocal() async {
    setState(() => _resolving = true);
    await _dataService.resolveConflictKeepLocal(widget.localDossier);
    if (!mounted) return;
    widget.onResolved();
  }

  Future<void> _takeRemote() async {
    if (_remoteDossier == null) return;
    setState(() => _resolving = true);
    await _dataService.resolveConflictTakeRemote(_remoteDossier!);
    if (!mounted) return;
    widget.onResolved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 24),
            if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Expanded(child: _buildError())
            else
              Expanded(child: _buildComparison()),
            const SizedBox(height: 24),
            if (!_loading && _error == null) _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final patient = widget.localDossier.patient;
    return Row(
      children: [
        // Bouton retour aligné sur celui du VAD (uniformisation
        // 2026-05-13) : 44×44 transparent, chevronLeft 24px ink-700.
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _resolving ? null : () => Navigator.pop(context),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
              ),
              alignment: Alignment.center,
              child: const Icon(
                LucideIcons.chevronLeft,
                size: 24,
                color: Color(0xFF2B323A), // ink-700
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${patient.lastName.toUpperCase()} ${patient.firstName}',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Conflit de synchronisation',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: Color(0xFF8A939D)),
          const SizedBox(height: 16),
          Text(
            _error!,
            style: TextStyle(fontSize: 15, color: Color(0xFF2B323A)),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _fetchRemote,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('R\u00e9essayer'),
          ),
        ],
      ),
    );
  }

  Widget _buildComparison() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _VersionCard(
            title: 'Version locale',
            subtitle: 'Vos modifications non synchronis\u00e9es',
            color: Colors.orange,
            icon: Icons.phone_android,
            dossier: widget.localDossier,
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: _VersionCard(
            title: 'Version distante',
            subtitle: 'Derni\u00e8re version sur le serveur',
            color: Colors.blue,
            icon: Icons.cloud,
            dossier: _remoteDossier!,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _resolving ? null : _keepLocal,
              icon: _resolving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.phone_android, size: 20),
              label: const Text('Garder ma version'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange.shade700,
                side: BorderSide(color: Colors.orange.shade300),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _resolving ? null : _takeRemote,
              icon: _resolving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_download, size: 20),
              label: const Text('Prendre la version distante'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Version card — displays one side of the diff
// ---------------------------------------------------------------------------

class _VersionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final Dossier dossier;

  const _VersionCard({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.dossier,
  });

  @override
  Widget build(BuildContext context) {
    final patient = dossier.patient;
    final housing = dossier.housing;
    final tp = patient.trustedPerson;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color.withAlpha(15),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(15),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: color.withAlpha(180),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Card body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('B\u00e9n\u00e9ficiaire'),
                  _field('Nom', '${patient.lastName} ${patient.firstName}'),
                  _field(
                    'Date de naissance',
                    _formatDate(patient.birthDate),
                  ),
                  _field(
                    'Adresse',
                    '${patient.address}, ${patient.zipCode} ${patient.city}',
                  ),
                  _field('T\u00e9l\u00e9phone', patient.phone),
                  _field('E-mail', patient.email),
                  _field('Situation familiale', patient.familySituation),
                  _field('Cat\u00e9gorie revenus', patient.incomeCategory),
                  const SizedBox(height: 16),

                  _sectionTitle('Personne de confiance'),
                  _field('Nom', tp.name.isEmpty ? '\u2014' : tp.name),
                  _field(
                    'T\u00e9l\u00e9phone',
                    tp.phone.isEmpty ? '\u2014' : tp.phone,
                  ),
                  const SizedBox(height: 16),

                  _sectionTitle('Logement'),
                  _field(
                    'Type',
                    housing.type == HousingType.APARTMENT
                        ? 'Appartement'
                        : 'Maison',
                  ),
                  _field(
                    'Ann\u00e9e',
                    housing.year?.toString() ?? '\u2014',
                  ),
                  _field(
                    'Surface',
                    housing.surface != null
                        ? '${housing.surface} m\u00b2'
                        : '\u2014',
                  ),
                  _field('Chauffage', _heatingLabel(housing.heating)),
                  if (housing.accessibilityNotes.isNotEmpty)
                    _field('Accessibilit\u00e9', housing.accessibilityNotes),
                  const SizedBox(height: 16),

                  _sectionTitle('Dossier'),
                  _field('Statut', dossier.status.label),
                  _field(
                    'Visite',
                    dossier.visitDate != null
                        ? _formatDate(dossier.visitDate!)
                        : '\u2014',
                  ),
                  if (dossier.autonomyNotes.isNotEmpty)
                    _field('Autonomie', dossier.autonomyNotes),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: kBrandDarkPurple,
        ),
      ),
    );
  }

  Widget _field(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF5C6670),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '\u2014' : value,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String raw) {
    try {
      return DateFormat('dd/MM/yyyy').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  String _heatingLabel(HeatingMode mode) {
    return switch (mode) {
      HeatingMode.ELECTRIC => '\u00c9lectrique',
      HeatingMode.GAS => 'Gaz',
      HeatingMode.WOOD => 'Bois',
      HeatingMode.OIL => 'Fioul',
      HeatingMode.OTHER => 'Autre',
    };
  }
}
