import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/references_service.dart';
import '../../components/commune_autocomplete.dart';
import '../../components/form_widgets.dart';
import '../../components/occupants_editor.dart';

class BeneficiaryTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const BeneficiaryTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<BeneficiaryTab> createState() => _BeneficiaryTabState();
}

class _BeneficiaryTabState extends State<BeneficiaryTab> {
  static const _kSubSections = ['Profil', 'Finance', 'Sant\u00e9', 'Admin'];

  int _subSectionIndex = 0;
  bool _saving = false;
  Timer? _saveTimer;

  // -- Profil fields --
  late String _lastName;
  late String _firstName;
  late String _birthDate;
  late String _address;
  late String _city;
  late String _zipCode;
  late String _cityId;
  late String _phone;
  late String _email;

  // -- Finance fields --
  late String _familySituation;
  String _occupationStatus = ''; // no DB column yet
  late String _incomeCategory;
  late double? _fiscalRevenue;
  late int _numberPeople;
  late List<Occupant> _occupants;

  final ReferencesService _references = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refSub;

  // -- Sant\u00e9 fields --
  late bool _apa;
  late bool _invalidity;
  late String _invalidityTxt;
  late bool _homeHelp;
  late String _homeHelpTxt;
  late String _dependenceTxt;
  late String _trustedName;
  late String _trustedPhone;
  late String _trustedEmail;

  // -- Admin fields --
  late String _compteAnah;
  late String _envoiRapport;
  late String _personnesPresentesVisite;
  String _numeroSecuriteSociale = ''; // placeholder, not on Patient model
  late String _caisseRetraitePrincipale;
  late String _caissesRetraiteComplementaires;

  @override
  void initState() {
    super.initState();
    _loadFromDossier();

    // Kick off the references fetch (no-op if already cached) and listen
    // for the first load so the income category can auto-refresh once the
    // barèmes arrive.
    _references.ensureLoaded();
    _refSub = _references.onLoaded.listen((_) {
      if (!mounted) return;
      _recomputeIncomeCategory();
    });
  }

  void _loadFromDossier() {
    final p = widget.dossier.patient;
    _lastName = p.lastName;
    _firstName = p.firstName;
    _birthDate = p.birthDate;
    _address = p.address;
    _city = p.city;
    _zipCode = p.zipCode;
    _cityId = p.cityId;
    _phone = p.phone;
    _email = p.email;

    _familySituation = p.familySituation;
    _incomeCategory = p.incomeCategory;
    _fiscalRevenue = p.fiscalRevenue;
    _numberPeople = p.numberPeople != null && p.numberPeople! > 0
        ? p.numberPeople!
        : 1;
    _occupants = List<Occupant>.from(p.occupants);

    _apa = p.apa;
    _invalidity = p.invalidity;
    _invalidityTxt = p.invalidityTxt;
    _homeHelp = p.homeHelp;
    _homeHelpTxt = p.homeHelpTxt;
    _dependenceTxt = p.dependenceTxt;
    _trustedName = p.trustedPerson.name;
    _trustedPhone = p.trustedPerson.phone;
    _trustedEmail = p.trustedPerson.email;

    _compteAnah = widget.dossier.compteAnah;
    _envoiRapport = widget.dossier.envoiRapport;
    _personnesPresentesVisite = widget.dossier.personnesPresentesVisite;
    _caisseRetraitePrincipale = p.caisseRetraitePrincipale;
    _caissesRetraiteComplementaires = p.caissesRetraiteComplementaires;
  }

  @override
  void dispose() {
    _refSub?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }

  void _recomputeIncomeCategory() {
    final next = _references.computeIncomeCategory(
      _numberPeople,
      _fiscalRevenue,
    );
    if (next.isNotEmpty && next != _incomeCategory) {
      setState(() => _incomeCategory = next);
      _scheduleSave();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.repository.updatePatient(widget.dossier.patient.id, {
        'first_name': _firstName,
        'last_name': _lastName,
        'birth_date': _birthDate,
        'address': _address,
        'city': _city,
        'zip_code': _zipCode,
        'city_id': _cityId,
        'phone': _phone,
        'email': _email,
        'family_situation': _familySituation,
        'income_category': _incomeCategory,
        'fiscal_revenue': _fiscalRevenue,
        'number_people': _numberPeople,
        'occupants_json':
            jsonEncode(_occupants.map((o) => o.toJson()).toList()),
        'apa': _apa ? 1 : 0,
        'invalidity': _invalidity ? 1 : 0,
        'invalidity_txt': _invalidityTxt,
        'home_help': _homeHelp ? 1 : 0,
        'home_help_txt': _homeHelpTxt,
        'dependence_txt': _dependenceTxt,
        'trusted_person_json': jsonEncode({
          'name': _trustedName,
          'phone': _trustedPhone,
          'email': _trustedEmail,
        }),
        'caisse_retraite_principale': _caisseRetraitePrincipale,
        'caisses_retraite_complementaires': _caissesRetraiteComplementaires,
      });
      await widget.repository.updateDossierFields(widget.dossier.id, {
        'compte_anah': _compteAnah,
        'envoi_rapport': _envoiRapport,
        'personnes_presentes_visite': _personnesPresentesVisite,
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _onChanged() {
    setState(() {});
    _scheduleSave();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Save indicator
          Align(
            alignment: Alignment.topRight,
            child: SaveStatusIndicator(saving: _saving),
          ),
          const SizedBox(height: 4),

          // Sub-section chips
          FormSubSectionChips(
            labels: _kSubSections,
            selectedIndex: _subSectionIndex,
            onChanged: (i) => setState(() => _subSectionIndex = i),
          ),

          // Active sub-section
          _buildActiveSection(),
        ],
      ),
    );
  }

  Widget _buildActiveSection() {
    switch (_subSectionIndex) {
      case 0:
        return _buildProfilSection();
      case 1:
        return _buildFinanceSection();
      case 2:
        return _buildSanteSection();
      case 3:
        return _buildAdminSection();
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Sub-section 1: Profil
  // ---------------------------------------------------------------------------

  Widget _buildProfilSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormTextField(
          label: 'Nom',
          value: _lastName,
          readOnly: true,
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Pr\u00e9nom',
          value: _firstName,
          readOnly: true,
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: FormTextField(
                label: 'Date de naissance',
                value: _birthDate,
                onChanged: (v) {
                  _birthDate = v;
                  _onChanged();
                },
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                _computeAgeLabel(_birthDate),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF554A63),
                ),
              ),
            ),
          ],
        ),
        const _SectionDivider(),
        FormTextField(
          label: 'Adresse',
          value: _address,
          onChanged: (v) {
            _address = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        CommuneAutocomplete(
          city: _city,
          zipCode: _zipCode,
          cityId: _cityId,
          onSelected: (city, zip, id) {
            setState(() {
              _city = city;
              _zipCode = zip;
              _cityId = id;
            });
            _scheduleSave();
          },
          onCityTextChanged: (v) {
            _city = v;
            _cityId = '';
            _onChanged();
          },
          onZipTextChanged: (v) {
            _zipCode = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormTextField(
          label: 'T\u00e9l\u00e9phone',
          value: _phone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            _phone = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Email',
          value: _email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            _email = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 2: Finance
  // ---------------------------------------------------------------------------

  Widget _buildFinanceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormToggleGroup(
          label: 'Situation familiale',
          options: const [
            'Mari\u00e9',
            'C\u00e9libataire',
            'Divorc\u00e9',
            'Veuf(ve)',
            'Concubinage',
          ],
          selected: _familySituation,
          onChanged: (v) {
            _familySituation = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormToggleGroup(
          label: "Statut d'occupation",
          options: const ['Propri\u00e9taire', 'Locataire', 'Usufruitier'],
          selected: _occupationStatus,
          onChanged: (v) {
            _occupationStatus = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormToggleGroup(
          label: "Nombre d'occupants",
          options: const ['1', '2', '3', '4', '5'],
          selected: _numberPeople.toString(),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n == null) return;
            setState(() {
              _numberPeople = n;
              // Resize occupants list to match
              if (_occupants.length < n) {
                _occupants = [
                  ..._occupants,
                  ...List.generate(n - _occupants.length, (_) => const Occupant()),
                ];
              } else if (_occupants.length > n) {
                _occupants = _occupants.sublist(0, n);
              }
            });
            _recomputeIncomeCategory();
            _scheduleSave();
          },
        ),
        const SizedBox(height: 14),
        FormNumberField(
          label: 'Revenu fiscal de r\u00e9f\u00e9rence',
          value: _fiscalRevenue,
          unit: '\u20ac',
          onChanged: (v) {
            _fiscalRevenue = v;
            _recomputeIncomeCategory();
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Cat\u00e9gorie revenus (auto-calcul\u00e9)',
          value: _incomeCategory,
          readOnly: true,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 3: Sant\u00e9
  // ---------------------------------------------------------------------------

  Widget _buildSanteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OccupantsEditor(
          numberPeople: _numberPeople,
          occupants: _occupants,
          onChanged: (n, list) {
            setState(() {
              _numberPeople = n;
              _occupants = list;
              // Mirror the first occupant onto the primary beneficiary
              // fields so the existing patient DB columns stay in sync.
              if (list.isNotEmpty) {
                final first = list.first;
                _apa = first.apa;
                _invalidity = first.invalidity;
                _invalidityTxt = first.invalidityTxt;
                _homeHelp = first.homeHelp;
                _homeHelpTxt = first.homeHelpTxt;
                _dependenceTxt = first.dependenceTxt;
                _caisseRetraitePrincipale = first.caisseRetraitePrincipale;
                _caissesRetraiteComplementaires =
                    first.caissesRetraiteComplementaires;
              }
            });
            _recomputeIncomeCategory();
            _scheduleSave();
          },
        ),
        const _SectionDivider(),
        const FormSectionHeader(
          title: 'Personne de confiance',
          icon: Icons.person_outline,
        ),
        FormTextField(
          label: 'Nom',
          value: _trustedName,
          onChanged: (v) {
            _trustedName = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'T\u00e9l\u00e9phone',
          value: _trustedPhone,
          keyboardType: TextInputType.phone,
          onChanged: (v) {
            _trustedPhone = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Email',
          value: _trustedEmail,
          keyboardType: TextInputType.emailAddress,
          onChanged: (v) {
            _trustedEmail = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 4: Admin
  // ---------------------------------------------------------------------------

  Widget _buildAdminSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormToggleGroup(
          label: 'Cr\u00e9ation compte Anah',
          options: const [
            'D\u00e9j\u00e0 fait',
            'A v\u00e9rifier',
            'A faire',
            'Mandat',
          ],
          selected: _compteAnah,
          onChanged: (v) {
            _compteAnah = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormToggleGroup(
          label: 'Envoi du rapport',
          options: const ['Mail', 'Courrier'],
          selected: _envoiRapport,
          onChanged: (v) {
            _envoiRapport = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormTextField(
          label: 'Personnes pr\u00e9sentes',
          value: _personnesPresentesVisite,
          maxLines: 3,
          onChanged: (v) {
            _personnesPresentesVisite = v;
            _onChanged();
          },
        ),
        const _SectionDivider(),
        FormTextField(
          label: 'N\u00b0 S\u00e9curit\u00e9 Sociale',
          value: _numeroSecuriteSociale,
          onChanged: (v) {
            _numeroSecuriteSociale = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Caisse retraite principale',
          value: _caisseRetraitePrincipale,
          onChanged: (v) {
            _caisseRetraitePrincipale = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextField(
          label: 'Caisses compl\u00e9mentaires',
          value: _caissesRetraiteComplementaires,
          onChanged: (v) {
            _caissesRetraiteComplementaires = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Retourne une étiquette courte type "78 !" pour un affichage compact
  /// (équivalent du rendu React : âge en violet foncé, sans label).
  String _computeAgeLabel(String birthDate) {
    final parsed = DateTime.tryParse(birthDate);
    if (parsed == null) return '';
    final now = DateTime.now();
    var age = now.year - parsed.year;
    final hadBirthday = (now.month > parsed.month) ||
        (now.month == parsed.month && now.day >= parsed.day);
    if (!hadBirthday) age -= 1;
    if (age <= 0) return '';
    return '$age !';
  }
}

// -----------------------------------------------------------------------------
// Small helper widget for dividers between logical groups
// -----------------------------------------------------------------------------

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Divider(color: Colors.grey.shade200, height: 1),
    );
  }
}
