import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/references_service.dart';
import '../../services/retirement_funds_repository.dart';
import '../../components/commune_field_group.dart';
import '../../components/form_widgets.dart';

/// Bénéficiaire tab — parité 1:1 avec la version React (`BeneficiaryForm`).
///
/// Sous-sections : Profil • Revenus • Santé • Dossier (admin).
/// Gère plusieurs occupants : certains champs sont "par occupant" (identité,
/// santé, n° sécu, caisse retraite) avec un sélecteur d'occupant en haut de
/// la section. Les champs partagés restent sur le bénéficiaire principal
/// (adresse, téléphone, email, compte Anah, envoi rapport…).
class BeneficiaryTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  /// Called after each successful save so the parent can re-fetch the
  /// dossier and propagate fresh patient fields (name, city, …) to the
  /// other tabs of the visit report and any other views listening.
  final VoidCallback? onPatientChanged;

  const BeneficiaryTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onPatientChanged,
  });

  @override
  State<BeneficiaryTab> createState() => _BeneficiaryTabState();
}

class _BeneficiaryTabState extends State<BeneficiaryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _subSectionIndex = 0;
  int _activeOccupantIndex = 0;
  bool _saving = false;
  Timer? _saveTimer;

  // Shared (patient-level) fields
  late String _address;
  late String _city;
  late String _zipCode;
  late String _cityId;
  late String _phone;
  late String _email;
  late String _familySituation;
  String _occupationStatus = '';
  late String _incomeCategory;
  double? _fiscalRevenue;
  late int _numberPeople;
  late String _trustedName;
  late String _trustedPhone;
  late String _trustedEmail;
  late String _compteAnah;
  late String _envoiRapport;
  late String _personnesPresentesVisite;

  // Per-occupant fields
  late List<Occupant> _occupants;

  // References
  final ReferencesService _references = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refSub;
  List<CommuneOption> _communeOptions = const [];
  List<String> _retirementFundNames = const [];

  // ANAH options (parity with React ANAH_ACCOUNT_OPTIONS)
  static const List<FormSelectOption<String>> _anahOptions = [
    FormSelectOption(value: 'Déjà fait', label: 'Déjà fait'),
    FormSelectOption(value: 'A vérifier', label: 'A vérifier'),
    FormSelectOption(value: 'A faire', label: 'A faire'),
    FormSelectOption(value: 'Mandat', label: 'Mandat'),
  ];

  // Family situation presets
  static const List<String> _familySituationOptions = [
    'Marié',
    'Célibataire',
    'Divorcé',
    'Veuf(ve)',
    'Concubinage',
  ];

  // Dependence presets — mirrors NocoDB view `vwje1ceip6mv9bt6`.
  static const List<String> _dependenceOptions = [
    'Aucune',
    'Canne',
    'Déambulateur',
    'Fauteuil roulant',
  ];

  // GIR (Groupe Iso-Ressources) options 6 → 1 — shown quand "Bénéficiaire
  // APA" est coché. Ordre dégressif demandé par l'utilisateur (6 = moins
  // dépendant, 1 = plus dépendant).
  static const List<String> _apaGirOptions = ['6', '5', '4', '3', '2', '1'];

  // Pourcentages MDPH — shown quand "Reconnaissance Invalidité" est cochée
  // à la place du GIR (qui est réservé au GIR APA).
  static const List<String> _mdphPercentageOptions = [
    'Inférieur à 50%',
    'Entre 50 et 79%',
    'Plus de 80%',
  ];

  // Occupation presets — présentés en menu déroulant (React parity).
  static const List<String> _occupationOptions = [
    'Propriétaire',
    'Locataire',
    'Usufruitier',
  ];

  @override
  void initState() {
    super.initState();
    _loadFromDossier();
    _references.ensureLoaded();
    _refSub = _references.onLoaded.listen((_) {
      if (!mounted) return;
      setState(() => _communeOptions = _mapCommunesToOptions());
      _recomputeIncomeCategory();
    });
    _communeOptions = _mapCommunesToOptions();
    _loadRetirementFundNames();
  }

  List<CommuneOption> _mapCommunesToOptions() {
    return _references.communes
        .map((c) => CommuneOption(
              id: c.id,
              label: c.label,
              zipCode: c.zipCode,
              epciId: c.epciId,
              epciLabel: c.epciLabel,
            ))
        .toList();
  }

  Future<void> _loadRetirementFundNames() async {
    try {
      final funds = await RetirementFundsRepository().fetchAllFunds();
      if (!mounted) return;
      setState(() {
        _retirementFundNames = funds
            .map((f) => f.name)
            .where((n) => n.trim().isNotEmpty)
            .toList()
          ..sort();
      });
    } catch (_) {
      // silent
    }
  }

  void _loadFromDossier() {
    final p = widget.dossier.patient;
    _address = p.address;
    _city = p.city;
    _zipCode = p.zipCode;
    _cityId = p.cityId;
    _phone = p.phone;
    _email = p.email;
    _familySituation = p.familySituation;
    _incomeCategory = p.incomeCategory;
    _fiscalRevenue = p.fiscalRevenue;
    _numberPeople =
        p.numberPeople != null && p.numberPeople! > 0 ? p.numberPeople! : 1;
    _trustedName = p.trustedPerson.name;
    _trustedPhone = p.trustedPerson.phone;
    _trustedEmail = p.trustedPerson.email;
    _compteAnah = widget.dossier.compteAnah;
    _envoiRapport = widget.dossier.envoiRapport;
    _personnesPresentesVisite = widget.dossier.personnesPresentesVisite;
    _occupants = _buildOccupantsFromPatient(p, _numberPeople);
  }

  List<Occupant> _buildOccupantsFromPatient(Patient p, int count) {
    final existing = List<Occupant>.from(p.occupants);
    final fallbacks = <Occupant>[
      Occupant(
        firstName: p.firstName,
        lastName: p.lastName,
        birthDate: p.birthDate,
        apa: p.apa,
        invalidity: p.invalidity,
        invalidityTxt: p.invalidityTxt,
        homeHelp: p.homeHelp,
        homeHelpTxt: p.homeHelpTxt,
        dependenceTxt: p.dependenceTxt,
        caisseRetraitePrincipale: p.caisseRetraitePrincipale,
        caissesRetraiteComplementaires: p.caissesRetraiteComplementaires,
      ),
      if (p.secondFirstName.isNotEmpty || p.secondLastName.isNotEmpty)
        Occupant(
          firstName: p.secondFirstName,
          lastName: p.secondLastName,
        ),
    ];
    final merged = <Occupant>[];
    final targetLen = count < 1 ? 1 : count;
    for (var i = 0; i < targetLen; i++) {
      if (i < existing.length) {
        merged.add(existing[i]);
      } else if (i < fallbacks.length) {
        merged.add(fallbacks[i]);
      } else {
        merged.add(const Occupant());
      }
    }
    return merged;
  }

  @override
  void didUpdateWidget(covariant BeneficiaryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the parent pushes a fresh dossier (e.g. after an external edit) AND
    // there is no pending local edit to preserve, re-hydrate so the form
    // mirrors the latest patient/housing data from SQLite.
    if (_saveTimer?.isActive == true) return;
    final oldP = oldWidget.dossier.patient;
    final newP = widget.dossier.patient;
    final numberPeopleChanged = oldP.numberPeople != newP.numberPeople;
    final changed = oldP.firstName != newP.firstName ||
        oldP.lastName != newP.lastName ||
        oldP.city != newP.city ||
        oldP.zipCode != newP.zipCode ||
        oldP.phone != newP.phone ||
        oldP.email != newP.email ||
        oldP.address != newP.address ||
        oldP.birthDate != newP.birthDate ||
        oldP.secondFirstName != newP.secondFirstName ||
        oldP.secondLastName != newP.secondLastName ||
        numberPeopleChanged ||
        oldWidget.dossier.compteAnah != widget.dossier.compteAnah ||
        oldWidget.dossier.envoiRapport != widget.dossier.envoiRapport;
    if (changed) {
      setState(() => _loadFromDossier());
      // If the household size changed, recompute the income category via
      // the ANAH barème that depends on numberPeople.
      if (numberPeopleChanged) {
        _recomputeIncomeCategory();
      }
    }
  }

  @override
  void dispose() {
    _refSub?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Save (debounced)
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    // 150 ms is short enough that local SQLite writes feel truly instant
    // (the user sees other tabs update immediately after each keystroke
    // pause), while still batching rapid successive keystrokes into a
    // single persist cycle. NocoDB sync follows ~200 ms later via the
    // SyncEngine debounce.
    _saveTimer = Timer(const Duration(milliseconds: 150), _save);
  }

  void _markChanged() {
    setState(() {});
    _scheduleSave();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final primary =
          _occupants.isNotEmpty ? _occupants.first : const Occupant();
      final secondary =
          _occupants.length > 1 ? _occupants[1] : const Occupant();
      await widget.repository.updatePatient(widget.dossier.patient.id, {
        'first_name': primary.firstName,
        'last_name': primary.lastName,
        'birth_date': primary.birthDate,
        'second_first_name': secondary.firstName,
        'second_last_name': secondary.lastName,
        'address': _address,
        'city': _city,
        'zip_code': _zipCode,
        'city_id': _cityId,
        'phone': _phone,
        'email': _email,
        'family_situation': _familySituation,
        'income_category': _incomeCategory,
        // Legacy aggregate column: store the sum of per-occupant RFRs so
        // backward-compatible consumers keep working.
        'fiscal_revenue': _totalFiscalRevenue(),
        'number_people': _numberPeople,
        'apa': primary.apa ? 1 : 0,
        'invalidity': primary.invalidity ? 1 : 0,
        'invalidity_txt': primary.invalidityTxt,
        'home_help': primary.homeHelp ? 1 : 0,
        'home_help_txt': primary.homeHelpTxt,
        'dependence_txt': primary.dependenceTxt,
        'trusted_person_json': jsonEncode({
          'name': _trustedName,
          'phone': _trustedPhone,
          'email': _trustedEmail,
        }),
        'caisse_retraite_principale': primary.caisseRetraitePrincipale,
        'caisses_retraite_complementaires':
            primary.caissesRetraiteComplementaires,
        'occupants_json':
            jsonEncode(_occupants.map((o) => o.toJson()).toList()),
      });
      await widget.repository.updateDossierFields(widget.dossier.id, {
        'compte_anah': _compteAnah,
        'envoi_rapport': _envoiRapport,
        'personnes_presentes_visite': _personnesPresentesVisite,
      });
      // Notify the parent (VisitReportScreen) so it re-fetches the dossier
      // and propagates the fresh patient data (name / city / …) to every
      // other tab and to any view listening to the same dossier.
      widget.onPatientChanged?.call();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Aggregate household fiscal revenue = sum of every occupant's RFR.
  /// Falls back to the legacy single [_fiscalRevenue] value if no occupant
  /// has a per-occupant RFR yet (pre-migration data).
  double? _totalFiscalRevenue() {
    final values = _occupants
        .map((o) => o.fiscalRevenue)
        .whereType<double>()
        .toList();
    if (values.isEmpty) return _fiscalRevenue;
    var total = 0.0;
    for (final v in values) {
      total += v;
    }
    return total;
  }

  void _recomputeIncomeCategory() {
    final next = _references.computeIncomeCategory(
      _numberPeople,
      _totalFiscalRevenue(),
    );
    if (next.isNotEmpty && next != _incomeCategory) {
      setState(() => _incomeCategory = next);
      _scheduleSave();
    }
  }

  void _updateOccupant(int index, Occupant updated) {
    if (index < 0 || index >= _occupants.length) return;
    setState(() => _occupants[index] = updated);
    _scheduleSave();
  }

  List<String> _occupantLabels() {
    return List<String>.generate(_occupants.length, (i) {
      final o = _occupants[i];
      if (o.firstName.isNotEmpty) return o.firstName.split(' ').first;
      return 'Occ. ${i + 1}';
    });
  }

  // Note: numberPeople is controlled from the dossier screen. When it
  // changes, the visit report's didUpdateWidget re-hydrates _occupants via
  // _loadFromDossier so the per-occupant sections automatically adapt.

  Occupant get _activeOccupant {
    if (_occupants.isEmpty) return const Occupant();
    final idx = _safeOccupantIndex;
    return _occupants[idx];
  }

  int get _safeOccupantIndex {
    if (_occupants.isEmpty) return 0;
    return _activeOccupantIndex.clamp(0, _occupants.length - 1).toInt();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildQuickNav(),
          const SizedBox(height: 16),
          _buildActiveSection(),
        ],
      ),
    );
  }

  Widget _buildQuickNav() {
    final items = const <_QuickNavItem>[
      _QuickNavItem(icon: Icons.person_outline, label: 'Profil'),
      _QuickNavItem(icon: Icons.home_outlined, label: 'Foyer'),
      _QuickNavItem(icon: Icons.favorite_outline, label: 'Santé'),
      _QuickNavItem(icon: Icons.folder_open_outlined, label: 'Admin'),
    ];
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: List.generate(items.length, (i) {
          final active = i == _subSectionIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _subSectionIndex = i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                decoration: BoxDecoration(
                  color:
                      active ? const Color(0xFFD8D0DC) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Icon(
                      items[i].icon,
                      size: 20,
                      color: active
                          ? const Color(0xFF554A63)
                          : const Color(0xFF64748B),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      items[i].label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: active
                            ? const Color(0xFF554A63)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
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
  // Profil
  // ---------------------------------------------------------------------------

  Widget _buildProfilSection() {
    final occ = _activeOccupant;
    final phoneInvalid = !isValidFrenchPhone(_phone);
    final emailInvalid = !isValidEmail(_email);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Bloc "Identité" (titre retiré à la demande du user) --------
        // On garde le sélecteur d'occupant aligné à droite pour que le
        // switch Monsieur/Madame reste accessible. Plus de divider.
        if (_occupantLabels().length > 1) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OccupantSwitcher(
                title: '',
                occupantLabels: _occupantLabels(),
                activeIndex: _safeOccupantIndex,
                onChanged: (i) => setState(() => _activeOccupantIndex = i),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 1,
              child: _DateOfBirthField(
                birthDate: occ.birthDate,
                onChanged: (iso) => _updateOccupant(
                  _safeOccupantIndex,
                  occ.copyWith(birthDate: iso),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 1,
              child: Text(
                _computeAgeLabel(occ.birthDate),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF554A63),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // --- Bloc "Coordonnées" (titre retiré à la demande du user) -----
        FormTextFieldWithWarning(
          label: 'Téléphone',
          value: _phone,
          keyboardType: TextInputType.phone,
          showWarning: phoneInvalid,
          warningText: 'Numéro français invalide',
          onChanged: (v) {
            _phone = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 14),
        FormTextFieldWithWarning(
          label: 'Email',
          value: _email,
          keyboardType: TextInputType.emailAddress,
          showWarning: emailInvalid,
          warningText: 'Adresse mail invalide',
          onChanged: (v) {
            _email = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Foyer (ex-Revenus) — composition du foyer, sans les champs revenus.
  // ---------------------------------------------------------------------------

  Widget _buildFinanceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormSection.text(
          'Foyer',
          child: Column(
            children: [
              FormToggleGroup(
                label: 'Situation familiale',
                options: _familySituationOptions,
                selected: _familySituation,
                columns: 2,
                onChanged: (v) {
                  _familySituation = v;
                  _markChanged();
                },
              ),
              const SizedBox(height: 14),
              FormSelectDropdown<String>(
                label: 'Occupation',
                value: _occupationStatus.isEmpty ? null : _occupationStatus,
                options: _occupationOptions
                    .map((o) => FormSelectOption<String>(value: o, label: o))
                    .toList(),
                placeholder: 'Sélectionner',
                onChanged: (v) {
                  _occupationStatus = v ?? '';
                  _markChanged();
                },
              ),
              const SizedBox(height: 14),
              // Source de vérité : champ "Informations bénéficiaire" de la
              // fiche dossier. Read-only ici.
              _buildReadOnlyField(
                label: 'Nombre de personnes au foyer',
                value: _numberPeople > 0 ? '$_numberPeople' : '1',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReadOnlyField({
    required String label,
    required String value,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF334155),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Santé
  // ---------------------------------------------------------------------------

  Widget _buildSanteSection() {
    final occ = _activeOccupant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormSection(
          title: OccupantSwitcher(
            title: 'Santé',
            occupantLabels: _occupantLabels(),
            activeIndex: _safeOccupantIndex,
            onChanged: (i) => setState(() => _activeOccupantIndex = i),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormCheckbox(
                label: 'Bénéficiaire APA',
                value: occ.apa,
                onChanged: (v) => _updateOccupant(
                    _safeOccupantIndex,
                    occ.copyWith(
                      apa: v,
                      apaGir: v ? occ.apaGir : '',
                    )),
              ),
              // Si APA est coché : menu déroulant GIR dans l'ordre
              // dégressif 6 → 1 (6 = moins dépendant, 1 = plus dépendant).
              if (occ.apa)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: FormSelectDropdown<String>(
                    label: '',
                    value: _apaGirOptions.contains(occ.apaGir.trim())
                        ? occ.apaGir.trim()
                        : null,
                    options: _apaGirOptions
                        .map((g) => FormSelectOption<String>(
                              value: g,
                              label: 'GIR $g',
                            ))
                        .toList(),
                    placeholder: 'Sélectionner un GIR',
                    onChanged: (v) => _updateOccupant(
                      _safeOccupantIndex,
                      occ.copyWith(apaGir: v ?? ''),
                    ),
                  ),
                ),
              FormCheckbox(
                label: 'Reconnaissance Invalidité',
                value: occ.invalidity,
                onChanged: (v) => _updateOccupant(
                    _safeOccupantIndex,
                    occ.copyWith(
                      invalidity: v,
                      invalidityTxt: v ? occ.invalidityTxt : '',
                    )),
              ),
              // Si Invalidité est cochée : pourcentages MDPH (remplace
              // l'ancien GIR qui n'avait rien à faire côté MDPH).
              if (occ.invalidity)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: FormSelectDropdown<String>(
                    label: '',
                    value: _mdphPercentageOptions
                            .contains(occ.invalidityTxt.trim())
                        ? occ.invalidityTxt.trim()
                        : null,
                    options: _mdphPercentageOptions
                        .map((p) =>
                            FormSelectOption<String>(value: p, label: p))
                        .toList(),
                    placeholder: 'Sélectionner un taux',
                    onChanged: (v) => _updateOccupant(
                      _safeOccupantIndex,
                      occ.copyWith(invalidityTxt: v ?? ''),
                    ),
                  ),
                ),
              FormCheckbox(
                label: 'Aide à domicile',
                value: occ.homeHelp,
                onChanged: (v) => _updateOccupant(
                    _safeOccupantIndex,
                    occ.copyWith(
                      homeHelp: v,
                      homeHelpTxt: v ? occ.homeHelpTxt : '',
                    )),
              ),
              const SizedBox(height: 10),
              FormToggleGroup(
                label: 'Dépendance',
                options: _dependenceOptions,
                columns: 2,
                selected:
                    occ.dependenceTxt.isEmpty ? 'Aucune' : occ.dependenceTxt,
                onChanged: (v) => _updateOccupant(
                    _safeOccupantIndex,
                    occ.copyWith(dependenceTxt: v == 'Aucune' ? '' : v)),
              ),
            ],
          ),
        ),
        // Personnes présentes à la visite — déplacé depuis Admin vers Santé.
        FormSection.text(
          'Visite',
          child: FormTextField(
            label: 'Personnes présentes à la visite',
            value: _personnesPresentesVisite,
            onChanged: (v) {
              _personnesPresentesVisite = v;
              _markChanged();
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Admin (ex-Dossier)
  // ---------------------------------------------------------------------------

  Widget _buildAdminSection() {
    final occ = _activeOccupant;
    final trustedPhoneInvalid = !isValidFrenchPhone(_trustedPhone);
    final trustedEmailInvalid = !isValidEmail(_trustedEmail);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormSection(
          title: OccupantSwitcher(
            title: 'Personnel',
            occupantLabels: _occupantLabels(),
            activeIndex: _safeOccupantIndex,
            onChanged: (i) => setState(() => _activeOccupantIndex = i),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FormTextField(
                      label: 'N° Sécu',
                      value: occ.numeroSecuriteSociale,
                      onChanged: (v) => _updateOccupant(
                          _safeOccupantIndex,
                          occ.copyWith(numeroSecuriteSociale: v)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FormTextField(
                      label: 'Caisse princ.',
                      value: occ.caisseRetraitePrincipale,
                      onChanged: (v) => _updateOccupant(
                          _safeOccupantIndex,
                          occ.copyWith(caisseRetraitePrincipale: v)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FormSelectDropdown<String>(
                label: 'Caisse complém.',
                value: occ.caissesRetraiteComplementaires.trim().isEmpty
                    ? null
                    : occ.caissesRetraiteComplementaires.trim(),
                options: _retirementFundNames
                    .map((name) =>
                        FormSelectOption<String>(value: name, label: name))
                    .toList(),
                placeholder: 'Sélectionner une caisse',
                onChanged: (v) => _updateOccupant(
                  _safeOccupantIndex,
                  occ.copyWith(caissesRetraiteComplementaires: v ?? ''),
                ),
              ),
            ],
          ),
        ),
        // Personne de Confiance — déplacée depuis Santé vers Admin.
        FormSection.text(
          'Personne de Confiance',
          child: Column(
            children: [
              FormTextField(
                label: 'Nom',
                value: _trustedName,
                onChanged: (v) {
                  _trustedName = v;
                  _markChanged();
                },
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FormTextFieldWithWarning(
                      label: 'Téléphone',
                      value: _trustedPhone,
                      keyboardType: TextInputType.phone,
                      showWarning: trustedPhoneInvalid,
                      warningText: 'Numéro français invalide',
                      onChanged: (v) {
                        _trustedPhone = v;
                        _markChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FormTextFieldWithWarning(
                      label: 'Email',
                      value: _trustedEmail,
                      keyboardType: TextInputType.emailAddress,
                      showWarning: trustedEmailInvalid,
                      warningText: 'Adresse mail invalide',
                      onChanged: (v) {
                        _trustedEmail = v;
                        _markChanged();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        FormSection.text(
          'Renseignements sur la visite',
          child: FormToggleGroup(
            label: 'Envoi du rapport',
            options: const ['Mail', 'Courrier'],
            selected: _envoiRapport,
            columns: 2,
            onChanged: (v) {
              _envoiRapport = v;
              _markChanged();
            },
          ),
        ),
        // Création compte Anah — toujours tout en bas de la section Admin
        // (dernière étape admin après avoir rempli le reste).
        FormSection.text(
          'Informations Administratives',
          child: FormSelectDropdown<String>(
            label: 'Création compte Anah',
            value: _compteAnah.isEmpty ? null : _compteAnah,
            options: _anahOptions,
            onChanged: (v) {
              _compteAnah = v ?? '';
              _markChanged();
            },
          ),
        ),
      ],
    );
  }

  Set<String> _parseComplementaryFunds(String raw) {
    if (raw.trim().isEmpty) return <String>{};
    return raw
        .split(RegExp(r'[,;]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  String _computeAgeLabel(String birthDate) {
    final parsed = _tryParseBirthDate(birthDate);
    if (parsed == null) return '';
    final now = DateTime.now();
    var age = now.year - parsed.year;
    final hadBirthday = (now.month > parsed.month) ||
        (now.month == parsed.month && now.day >= parsed.day);
    if (!hadBirthday) age -= 1;
    // Afficher même les âges 0 (nouveau-né / enfant < 1 an). On filtre
    // seulement les dates futures (négatives).
    if (age < 0) return '';
    return '$age ans !';
  }

  /// Accepts either an ISO date (YYYY-MM-DD) or a French date (DD/MM/YYYY).
  /// Returns null when the input can't be parsed.
  DateTime? _tryParseBirthDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    // Try ISO first (most common storage format).
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso;
    // Fallback: DD/MM/YYYY or DD-MM-YYYY
    final parts = value.split(RegExp(r'[/\-.]'));
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    if (year < 1900 || year > 2100) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    try {
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }

  /// Formats a stored birth date for display as DD/MM/YYYY.
  /// If the stored value is partial / unparseable, returns it unchanged so
  /// the user can keep typing without disruption.
  String _formatBirthDateForInput(String stored) {
    final parsed = _tryParseBirthDate(stored);
    if (parsed == null) return stored;
    final d = parsed.day.toString().padLeft(2, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    return '$d/$m/${parsed.year}';
  }

  /// Converts user input (typically DD/MM/YYYY) to ISO (YYYY-MM-DD) for
  /// storage. Returns the raw input if parsing fails, so intermediate typing
  /// states don't lose characters.
  String _parseBirthDateFromInput(String typed) {
    final parsed = _tryParseBirthDate(typed);
    if (parsed == null) return typed;
    final y = parsed.year.toString().padLeft(4, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _QuickNavItem {
  final IconData icon;
  final String label;
  const _QuickNavItem({required this.icon, required this.label});
}

// ---------------------------------------------------------------------------
// _DateOfBirthField — champ date de naissance read-only visuellement
// identique à FormTextField, mais qui ouvre un showDatePicker au clic.
// Stocke la valeur en ISO (YYYY-MM-DD) et affiche en DD/MM/YYYY.
// ---------------------------------------------------------------------------

class _DateOfBirthField extends StatelessWidget {
  final String birthDate;
  final ValueChanged<String> onChanged;

  const _DateOfBirthField({
    required this.birthDate,
    required this.onChanged,
  });

  DateTime? _parse(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    final iso = DateTime.tryParse(v);
    if (iso != null) return iso;
    final parts = v.split(RegExp(r'[/\-.]'));
    if (parts.length != 3) return null;
    final d = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final y = int.tryParse(parts[2]);
    if (d == null || m == null || y == null) return null;
    try {
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  String _formatDisplay(String raw) {
    final parsed = _parse(raw);
    if (parsed == null) return '';
    final d = parsed.day.toString().padLeft(2, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    return '$d/$m/${parsed.year}';
  }

  Future<void> _pickDate(BuildContext context) async {
    final initial = _parse(birthDate) ?? DateTime(1960, 1, 1);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year + 1),
      locale: const Locale('fr', 'FR'),
      helpText: 'Sélectionner une date de naissance',
      cancelText: 'Annuler',
      confirmText: 'OK',
    );
    if (picked == null) return;
    final y = picked.year.toString().padLeft(4, '0');
    final m = picked.month.toString().padLeft(2, '0');
    final d = picked.day.toString().padLeft(2, '0');
    onChanged('$y-$m-$d');
  }

  @override
  Widget build(BuildContext context) {
    final display = _formatDisplay(birthDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Date de naissance',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _pickDate(context),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    display.isEmpty ? 'JJ / MM / AAAA' : display,
                    style: TextStyle(
                      fontSize: 14,
                      color: display.isEmpty
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF0F172A),
                    ),
                  ),
                ),
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
