import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class BeneficiaryTab extends StatefulWidget {
  final Dossier dossier;
  final ValueChanged<Dossier> onDossierChanged;

  const BeneficiaryTab({
    super.key,
    required this.dossier,
    required this.onDossierChanged,
  });

  @override
  State<BeneficiaryTab> createState() => _BeneficiaryTabState();
}

class _BeneficiaryTabState extends State<BeneficiaryTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  int _subSection = 0;
  Timer? _saveTimer;
  bool _loaded = false;
  List<String> _principalFundNames = const [];

  static const _sections = ['Identit\u00e9', 'Revenus', 'Sant\u00e9', 'Administratif'];

  Patient get _patient => widget.dossier.patient;
  String get _patientId => _patient.id;

  @override
  void initState() {
    super.initState();
    _loadFormData();
    _loadPrincipalFundNames();
  }

  Future<void> _loadPrincipalFundNames() async {
    try {
      final names = await _dataService.fetchPrincipalRetirementFundNames();
      if (!mounted) return;
      setState(() {
        _principalFundNames = names.toList()..sort();
      });
    } catch (_) {
      // silent
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFormData() async {
    final data = await _dataService.fetchFormData(_patientId, 'beneficiaire');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onFormChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'beneficiaire', _formData);
    });
  }

  void _updatePatient(Patient updated) {
    widget.onDossierChanged(widget.dossier.copyWith(patient: updated));
  }

  void _savePatientField(String column, String value) {
    _dataService.updatePatientFields(_patientId, {column: value});
  }

  void _saveTrustedPerson(TrustedPerson tp) {
    _dataService.updatePatientFields(_patientId, {
      'trusted_person_json': jsonEncode({
        'name': tp.name,
        'phone': tp.phone,
        'email': tp.email,
      }),
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VSubSectionBar(
          sections: _sections,
          selected: _subSection,
          onChanged: (i) => setState(() => _subSection = i),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 16),
            child: _buildSubSection(),
          ),
        ),
      ],
    );
  }

  Widget _buildSubSection() {
    switch (_subSection) {
      case 0:
        return _buildProfile();
      case 1:
        return _buildFinance();
      case 2:
        return _buildHealth();
      case 3:
        return _buildAdmin();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildProfile() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Identit\u00e9'),
        VTextField(
          label: 'Nom',
          initialValue: _patient.lastName,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(lastName: v));
            _savePatientField('last_name', v);
          },
        ),
        VTextField(
          label: 'Pr\u00e9nom',
          initialValue: _patient.firstName,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(firstName: v));
            _savePatientField('first_name', v);
          },
        ),
        VTextField(
          label: 'Date de naissance',
          initialValue: _patient.birthDate,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(birthDate: v));
            _savePatientField('birth_date', v);
          },
        ),
        VTextField(
          label: 'Adresse',
          initialValue: _patient.address,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(address: v));
            _savePatientField('address', v);
          },
        ),
        VTextField(
          label: 'Ville',
          initialValue: _patient.city,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(city: v));
            _savePatientField('city', v);
          },
        ),
        VTextField(
          label: 'Code postal',
          initialValue: _patient.zipCode,
          keyboardType: TextInputType.number,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(zipCode: v));
            _savePatientField('zip_code', v);
          },
        ),
        VTextField(
          label: 'T\u00e9l\u00e9phone',
          initialValue: _patient.phone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(phone: v));
            _savePatientField('phone', v);
          },
        ),
        VTextField(
          label: 'E-mail',
          initialValue: _patient.email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(email: v));
            _savePatientField('email', v);
          },
        ),
      ],
    );
  }

  Widget _buildFinance() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Revenus'),
        VToggleGroup(
          label: 'Situation familiale',
          options: const ['Seul(e)', 'En couple', 'Famille'],
          selected: _patient.familySituation,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(familySituation: v));
            _savePatientField('family_situation', v);
          },
        ),
        VToggleGroup(
          label: 'Statut d\u2019occupation',
          options: const ['Propri\u00e9taire', 'Locataire', 'Usufruitier'],
          selected: _formData['occupationStatus']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('occupationStatus', v),
        ),
        VTextField(
          label: 'Cat\u00e9gorie de revenus',
          initialValue: _patient.incomeCategory,
          onChanged: (v) {
            _updatePatient(_patient.copyWith(incomeCategory: v));
            _savePatientField('income_category', v);
          },
        ),
        VNumberField(
          label: 'Revenu fiscal de r\u00e9f\u00e9rence',
          initialValue: _formData['fiscalRevenue']?.toString() ?? '',
          suffix: '\u20ac',
          onChanged: (v) => _onFormChanged('fiscalRevenue', v),
        ),
        VDropdown(
          label: 'Nombre de personnes au foyer',
          options: const ['1', '2', '3', '4', '5+'],
          selected: _formData['numberPeople']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('numberPeople', v),
        ),
      ],
    );
  }

  Widget _buildHealth() {
    final tp = _patient.trustedPerson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Sant\u00e9 / Autonomie'),
        VCheckbox(
          label: 'B\u00e9n\u00e9ficiaire APA',
          value: _formData['apa'] == true,
          onChanged: (v) => _onFormChanged('apa', v),
        ),
        VCheckbox(
          label: 'Invalidit\u00e9',
          value: _formData['invalidity'] == true,
          onChanged: (v) => _onFormChanged('invalidity', v),
        ),
        if (_formData['invalidity'] == true)
          VTextField(
            label: 'Pr\u00e9cision invalidit\u00e9',
            initialValue: _formData['invalidityTxt']?.toString() ?? '',
            onChanged: (v) => _onFormChanged('invalidityTxt', v),
          ),
        VCheckbox(
          label: 'Aide \u00e0 domicile',
          value: _formData['homeHelp'] == true,
          onChanged: (v) => _onFormChanged('homeHelp', v),
        ),
        if (_formData['homeHelp'] == true)
          VTextField(
            label: 'Pr\u00e9cision aide \u00e0 domicile',
            initialValue: _formData['homeHelpTxt']?.toString() ?? '',
            onChanged: (v) => _onFormChanged('homeHelpTxt', v),
          ),
        VTextField(
          label: 'GIR / D\u00e9pendance',
          initialValue: _formData['dependenceTxt']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('dependenceTxt', v),
        ),
        const VSectionHeader('Personne de confiance'),
        VTextField(
          label: 'Nom',
          initialValue: tp.name,
          onChanged: (v) {
            final updated = tp.copyWith(name: v);
            _updatePatient(_patient.copyWith(trustedPerson: updated));
            _saveTrustedPerson(updated);
          },
        ),
        VTextField(
          label: 'T\u00e9l\u00e9phone',
          initialValue: tp.phone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            final updated = tp.copyWith(phone: v);
            _updatePatient(_patient.copyWith(trustedPerson: updated));
            _saveTrustedPerson(updated);
          },
        ),
        VTextField(
          label: 'E-mail',
          initialValue: tp.email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            final updated = tp.copyWith(email: v);
            _updatePatient(_patient.copyWith(trustedPerson: updated));
            _saveTrustedPerson(updated);
          },
        ),
      ],
    );
  }

  Widget _buildAdmin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Informations administratives'),
        VToggleGroup(
          label: 'Compte ANAH',
          options: const ['D\u00e9j\u00e0 fait', 'A v\u00e9rifier', 'A faire', 'Mandat'],
          selected: _formData['compteAnah']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('compteAnah', v),
        ),
        VTextField(
          label: 'N\u00b0 de s\u00e9curit\u00e9 sociale',
          initialValue: _formData['numeroSecuriteSociale']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('numeroSecuriteSociale', v),
        ),
        VDropdown(
          label: 'Caisse de retraite principale',
          options: _principalFundNames,
          selected: _formData['caisseRetraitePrincipale']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('caisseRetraitePrincipale', v),
        ),
        VTextField(
          label: 'Caisses de retraite compl\u00e9mentaires',
          initialValue:
              _formData['caissesRetraiteComplementaires']?.toString() ?? '',
          onChanged: (v) =>
              _onFormChanged('caissesRetraiteComplementaires', v),
        ),
        VToggleGroup(
          label: 'Envoi du rapport',
          options: const ['Mail', 'Courrier'],
          selected: _formData['envoiRapport']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('envoiRapport', v),
        ),
        VTextField(
          label: 'Personnes pr\u00e9sentes lors de la visite',
          initialValue:
              _formData['personnesPresentesVisite']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('personnesPresentesVisite', v),
        ),
      ],
    );
  }
}
