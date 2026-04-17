import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/form_widgets.dart';
import '../components/notes_widget.dart';
import '../models/types.dart';
import '../services/dossier_repository.dart';
import 'conflict_resolution_screen.dart';
import 'documents_screen.dart';
import 'start_visit_screen.dart';

class DossierScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;
  final DossierRepository? repository;

  const DossierScreen({
    super.key,
    required this.dossier,
    required this.onBack,
    this.repository,
  });

  @override
  State<DossierScreen> createState() => _DossierScreenState();
}

class _DossierScreenState extends State<DossierScreen> {
  late final DossierRepository _repository;

  Timer? _saveTimer;
  bool _saving = false;

  // -- Identité --
  late String _firstName;
  late String _lastName;
  late String _birthDate;

  // -- Contact --
  late String _phone;
  late String _email;
  late String _address;
  late String _city;
  late String _zipCode;

  // -- Santé --
  late bool _apa;
  late bool _invalidity;
  late bool _homeHelp;
  late String _dependenceTxt;
  late String _autonomyNotes;

  // -- Situation familiale --
  late String _familySituation;
  late String _trustedName;
  late String _trustedPhone;
  late String _trustedEmail;

  // -- Revenus --
  late String _incomeCategory;
  late double? _fiscalRevenue;
  late String _caisseRetraitePrincipale;
  late String _caissesRetraiteComplementaires;

  static const _familyOptions = [
    'Marié',
    'Célibataire',
    'Divorcé',
    'Veuf(ve)',
    'Concubinage',
  ];

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? DossierRepository();
    _loadFromDossier();
  }

  void _loadFromDossier() {
    final p = widget.dossier.patient;

    _firstName = p.firstName;
    _lastName = p.lastName;
    _birthDate = p.birthDate;

    _phone = p.phone;
    _email = p.email;
    _address = p.address;
    _city = p.city;
    _zipCode = p.zipCode;

    _apa = p.apa;
    _invalidity = p.invalidity;
    _homeHelp = p.homeHelp;
    _dependenceTxt = p.dependenceTxt;
    _autonomyNotes = widget.dossier.autonomyNotes;

    _familySituation = p.familySituation;
    _trustedName = p.trustedPerson.name;
    _trustedPhone = p.trustedPerson.phone;
    _trustedEmail = p.trustedPerson.email;

    _incomeCategory = p.incomeCategory;
    _fiscalRevenue = p.fiscalRevenue;
    _caisseRetraitePrincipale = p.caisseRetraitePrincipale;
    _caissesRetraiteComplementaires = p.caissesRetraiteComplementaires;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await _repository.updatePatientFields(widget.dossier.patient.id, {
        'first_name': _firstName,
        'last_name': _lastName,
        'birth_date': _birthDate,
        'phone': _phone,
        'email': _email,
        'address': _address,
        'city': _city,
        'zip_code': _zipCode,
        'family_situation': _familySituation,
        'apa': _apa ? 1 : 0,
        'invalidity': _invalidity ? 1 : 0,
        'home_help': _homeHelp ? 1 : 0,
        'dependence_txt': _dependenceTxt,
        'fiscal_revenue': _fiscalRevenue,
        'caisse_retraite_principale': _caisseRetraitePrincipale,
        'caisses_retraite_complementaires': _caissesRetraiteComplementaires,
        'trusted_person_json': jsonEncode({
          'name': _trustedName,
          'phone': _trustedPhone,
          'email': _trustedEmail,
        }),
      });
      await _repository.updateDossierFields(widget.dossier.id, {
        'autonomy_notes': _autonomyNotes,
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      return DateFormat('dd/MM/yyyy').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            _buildHeader(context),
            const SizedBox(height: 32),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Column: Actions + editable info card
                  Expanded(
                    flex: 5,
                    child: Column(
                      children: [
                        _buildQuickActions(context),
                        if (widget.dossier.syncState == SyncState.conflict) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: _QuickActionButton(
                              icon: LucideIcons.gitMerge,
                              label: 'Résoudre le conflit',
                              subLabel:
                                  'Comparer les versions et choisir laquelle garder',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ConflictResolutionScreen(
                                      localDossier: widget.dossier,
                                      onResolved: () {
                                        Navigator.pop(context);
                                        widget.onBack();
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Expanded(child: _buildInfoCard()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Right Column: Notes Rapides
                  Expanded(flex: 7, child: _buildNotesColumn()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------
  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            InkWell(
              onTap: widget.onBack,
              borderRadius: BorderRadius.circular(50),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: const Icon(
                  LucideIcons.arrowLeft,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_lastName.toUpperCase()} $_firstName',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Dossier actif',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _syncBackground(widget.dossier.syncState),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        widget.dossier.syncState.label,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          color: _syncForeground(widget.dossier.syncState),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              'Créé le',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            Text(
              _formatDate(widget.dossier.createdAt),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 16,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Quick actions
  // ---------------------------------------------------------------------------
  Widget _buildQuickActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _QuickActionButton(
            icon: LucideIcons.paperclip,
            label: 'Espace Documents',
            subLabel: 'Photos, scans, plans...',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DocumentsScreen(
                    dossier: widget.dossier,
                    onBack: () => Navigator.pop(context),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _QuickActionButton(
            icon: LucideIcons.home,
            label: 'Visite Domicile',
            subLabel: 'Relevés, mesures, photos...',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StartVisitScreen(
                    dossier: widget.dossier,
                    onBack: () => Navigator.pop(context),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Info Card (editable)
  // ---------------------------------------------------------------------------
  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(LucideIcons.user, color: Colors.grey, size: 20),
                  SizedBox(width: 12),
                  Text(
                    'Informations Bénéficiaire',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              SaveStatusIndicator(saving: _saving),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildIdentiteSection(),
                  const _SectionDivider(),
                  _buildContactSection(),
                  const _SectionDivider(),
                  _buildSanteSection(),
                  const _SectionDivider(),
                  _buildSituationSection(),
                  const _SectionDivider(),
                  _buildRevenusSection(),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentiteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FormSectionHeader(title: 'Identité', icon: LucideIcons.user),
        FormTextField(
          label: 'Prénom',
          value: _firstName,
          onChanged: (v) {
            _firstName = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Nom',
          value: _lastName,
          onChanged: (v) {
            _lastName = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Date de naissance',
          value: _birthDate,
          onChanged: (v) {
            _birthDate = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  Widget _buildContactSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FormSectionHeader(title: 'Contact', icon: LucideIcons.phone),
        FormTextField(
          label: 'Téléphone',
          value: _phone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            _phone = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Email',
          value: _email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            _email = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Adresse',
          value: _address,
          onChanged: (v) {
            _address = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: FormTextField(
                label: 'Ville',
                value: _city,
                onChanged: (v) {
                  _city = v;
                  _onChanged();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 1,
              child: FormTextField(
                label: 'Code postal',
                value: _zipCode,
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  _zipCode = v;
                  _onChanged();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSanteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FormSectionHeader(title: 'Santé', icon: LucideIcons.activity),
        FormToggleGroup(
          label: 'Bénéficiaire APA',
          options: const ['Oui', 'Non'],
          selected: _apa ? 'Oui' : 'Non',
          onChanged: (v) {
            _apa = v == 'Oui';
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Reconnaissance invalidité',
          options: const ['Oui', 'Non'],
          selected: _invalidity ? 'Oui' : 'Non',
          onChanged: (v) {
            _invalidity = v == 'Oui';
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Aide à domicile',
          options: const ['Oui', 'Non'],
          selected: _homeHelp ? 'Oui' : 'Non',
          onChanged: (v) {
            _homeHelp = v == 'Oui';
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Dépendance particulière',
          value: _dependenceTxt,
          onChanged: (v) {
            _dependenceTxt = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Notes autonomie',
          value: _autonomyNotes,
          maxLines: 3,
          onChanged: (v) {
            _autonomyNotes = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  Widget _buildSituationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FormSectionHeader(
          title: 'Situation familiale',
          icon: LucideIcons.users,
        ),
        FormToggleGroup(
          label: 'Situation familiale',
          options: _familyOptions,
          selected: _familySituation,
          onChanged: (v) {
            _familySituation = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 16),
        const Text(
          'Personne de confiance',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 8),
        FormTextField(
          label: 'Nom',
          value: _trustedName,
          onChanged: (v) {
            _trustedName = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Téléphone',
          value: _trustedPhone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            _trustedPhone = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Email',
          value: _trustedEmail,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            _trustedEmail = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  Widget _buildRevenusSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FormSectionHeader(title: 'Revenus', icon: LucideIcons.euro),
        FormTextField(
          label: 'Catégorie revenus',
          value: _incomeCategory,
          readOnly: true,
        ),
        const SizedBox(height: 12),
        FormNumberField(
          label: 'Revenu fiscal de référence',
          value: _fiscalRevenue,
          unit: '€',
          onChanged: (v) {
            _fiscalRevenue = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Caisse retraite principale',
          value: _caisseRetraitePrincipale,
          onChanged: (v) {
            _caisseRetraitePrincipale = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Caisses complémentaires',
          value: _caissesRetraiteComplementaires,
          onChanged: (v) {
            _caissesRetraiteComplementaires = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right column: Notes
  // ---------------------------------------------------------------------------
  Widget _buildNotesColumn() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Notes Rapides',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: const Text(
                  'Sauvegarde auto',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: NotesWidget(
            patientId: widget.dossier.patient.id,
            tabKey: 'notes_rapides',
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Helper widgets
// -----------------------------------------------------------------------------

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Divider(height: 1, color: Color(0xFFE2E8F0)),
    );
  }
}

Color _syncBackground(SyncState syncState) {
  switch (syncState) {
    case SyncState.synced:
      return Colors.green.shade50;
    case SyncState.pendingSync:
    case SyncState.localOnly:
    case SyncState.syncing:
      return Colors.orange.shade50;
    case SyncState.syncError:
    case SyncState.conflict:
      return Colors.red.shade50;
  }
}

Color _syncForeground(SyncState syncState) {
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

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subLabel;
  final VoidCallback onTap;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.subLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F0F5),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Icon(icon, color: const Color(0xFF907CA1)),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subLabel,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
