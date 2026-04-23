import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';
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

  /// Called when the user taps Profil / Foyer / Santé / Admin. The
  /// visit report screen uses it to sync the right-side notes panel
  /// (which no longer has its own pill selector) to the active
  /// sub-section.
  final ValueChanged<int>? onSubSectionChanged;

  /// Initial sub-section index (kept in sync with the parent's
  /// `_activeSubsectionByTab['Bénéficiaire']`).
  final int initialSubSection;

  const BeneficiaryTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onPatientChanged,
    this.onSubSectionChanged,
    this.initialSubSection = 0,
  });

  @override
  State<BeneficiaryTab> createState() => _BeneficiaryTabState();
}

class _BeneficiaryTabState extends State<BeneficiaryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _subSectionIndex = 0;

  void _setSubSection(int i) {
    if (i == _subSectionIndex) return;
    setState(() => _subSectionIndex = i);
    widget.onSubSectionChanged?.call(i);
  }
  bool _saving = false;
  Timer? _saveTimer;

  // (Les anciens Sets d'édition repliée ont été retirés : les boutons et
  // menus déroulants du relevé de visite restent maintenant toujours
  // visibles pour permettre un changement rapide.)

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
  List<String> _principalFundNames = const [];

  // ANAH options (parity with React ANAH_ACCOUNT_OPTIONS)
  static const List<FormSelectOption<String>> _anahOptions = [
    FormSelectOption(value: 'Déjà fait', label: 'Déjà fait'),
    FormSelectOption(value: 'A vérifier', label: 'A vérifier'),
    FormSelectOption(value: 'A faire', label: 'A faire'),
    FormSelectOption(value: 'Mandat', label: 'Mandat'),
  ];

  // Family situation presets
  static const List<String> _familySituationOptions = [
    'Marié(e)',
    'Célibataire',
    'Divorcé(e)',
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
    _subSectionIndex = widget.initialSubSection.clamp(0, 3);
    _loadFromDossier();
    _references.ensureLoaded();
    _refSub = _references.onLoaded.listen((_) {
      if (!mounted) return;
      setState(() => _communeOptions = _mapCommunesToOptions());
      _recomputeIncomeCategory();
    });
    _communeOptions = _mapCommunesToOptions();
    _loadRetirementFundNames();
    _loadPrincipalFundNames();
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

  Future<void> _loadPrincipalFundNames() async {
    try {
      final names = await DataService().fetchPrincipalRetirementFundNames();
      if (!mounted) return;
      setState(() {
        _principalFundNames = names.toList()..sort();
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
    // Initialise les "committed" à partir des valeurs déjà enregistrées :
    // un occupant avec une dépendance non vide a forcément choisi une
    // option → on affiche l'état replié plutôt que les pills.
    _dependenceCommittedIndices
      ..clear()
      ..addAll([
        for (int i = 0; i < _occupants.length; i++)
          if (_occupants[i].dependenceTxt.trim().isNotEmpty) i,
      ]);
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

  // Note: numberPeople is controlled from the dossier screen. When it
  // changes, the visit report's didUpdateWidget re-hydrates _occupants via
  // _loadFromDossier so the per-occupant sections automatically adapt.

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
              onTap: () => _setSubSection(i),
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

  Widget _buildBirthDateRow(int index) {
    final occ = _occupants[index];
    final firstName = occ.firstName.trim().split(' ').first;
    final hasMultiple = _occupants.length > 1;
    final label = hasMultiple
        ? (firstName.isNotEmpty
            ? 'Date de naissance de $firstName'
            : "Date de naissance de l'occupant ${index + 1}")
        : 'Date de naissance';
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
        Builder(
          builder: (context) {
            final ageLabel = _computeAgeLabel(occ.birthDate);
            final dateField = _DateOfBirthField(
              birthDate: occ.birthDate,
              showLabel: false,
              onChanged: (iso) => _updateOccupant(
                index,
                occ.copyWith(birthDate: iso),
              ),
            );
            // Si aucune date saisie (ageLabel vide) → le champ prend
            // toute la largeur, pas de colonne vide à droite.
            if (ageLabel.isEmpty) return dateField;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 1, child: dateField),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: Text(
                    ageLabel,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF554A63),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildProfilSection() {
    final phoneInvalid = !isValidFrenchPhone(_phone);
    final emailInvalid = !isValidEmail(_email);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Bloc "Identité" : un champ Date de naissance par occupant,
        // empilés verticalement avec un label personnalisé au-dessus.
        for (int i = 0; i < _occupants.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          _buildBirthDateRow(i),
        ],
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
        // --- Bloc "Foyer" (titre retiré) --------------------------------
        // Boutons toujours visibles — pas de bascule en menu déroulant
        // après sélection (l'ergo doit voir les autres choix pour
        // changer rapidement son avis).
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
        FormToggleGroup(
          label: 'Occupation',
          options: _occupationOptions,
          selected: _occupationStatus,
          columns: 1,
          onChanged: (v) {
            _occupationStatus = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 24),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Blocs Aides + Dépendance empilés par occupant, labels
        // personnalisés avec le prénom quand le foyer a 2+ personnes.
        for (int i = 0; i < _occupants.length; i++) ...[
          if (i > 0) const SizedBox(height: 24),
          _buildAidesDependenceBlock(i),
        ],
        const SizedBox(height: 24),

        // --- Bloc "Visite" (titre retiré) -------------------------------
        FormTextField(
          label: 'Personnes présentes à la visite',
          value: _personnesPresentesVisite,
          onChanged: (v) {
            _personnesPresentesVisite = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Ligne compacte affichée en mode "replié" pour un champ ayant déjà
  /// une valeur : "Label (valeur)" suivi d'un petit crayon d'édition.
  /// Tap sur la ligne ou le crayon → [onEdit]. Wrapper autour de
  /// [CollapsedValueRow] pour garder l'appel fluide côté subclasses.
  Widget _collapsedValueRow({
    required String label,
    required String displayValue,
    required VoidCallback onEdit,
    TextStyle? labelStyle,
  }) =>
      CollapsedValueRow(
        label: label,
        displayValue: displayValue,
        onEdit: onEdit,
        labelStyle: labelStyle,
      );

  /// Case à cocher qui, une fois cochée, affiche directement la liste
  /// des options en pills sous la ligne. Les boutons restent visibles en
  /// permanence (pas de repli en "label (valeur) + crayon") pour que
  /// l'ergo puisse changer rapidement.
  Widget _buildCollapsibleOptionCheckbox({
    required String label,
    required bool checked,
    required String value,
    required List<String> options,
    required String Function(String) optionLabel,
    required int optionColumns,
    required ValueChanged<bool> onCheckedChanged,
    required ValueChanged<String> onValueChanged,
  }) {
    final pillLabels = options.map(optionLabel).toList();
    final hasValue = value.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onCheckedChanged(!checked),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color:
                        checked ? const Color(0xFF907CA1) : Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: checked
                          ? const Color(0xFF907CA1)
                          : Colors.grey.shade400,
                      width: 1.5,
                    ),
                  ),
                  child: checked
                      ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (!checked) onCheckedChanged(true);
                  },
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Boutons de choix toujours visibles quand la checkbox est cochée
        // — pas de bascule en "label (valeur) + crayon" : l'ergo doit
        // pouvoir voir tous les choix pour changer rapidement.
        if (checked) ...[
          const SizedBox(height: 6),
          FormToggleGroup(
            label: '',
            options: pillLabels,
            selected: hasValue ? optionLabel(value) : '',
            columns: optionColumns,
            onChanged: (picked) {
              final idx = pillLabels.indexOf(picked);
              if (idx >= 0) onValueChanged(options[idx]);
            },
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  /// Dépendance : liste de pills par défaut (avec "Aucune" comme état
  /// neutre vide). Une fois une option non-vide sélectionnée, la liste
  /// se replie et la valeur choisie apparaît entre parenthèses à côté
  /// du label ("Dépendance de Sophie (Canne)"). Toucher la zone label
  /// en état replié rouvre la liste pour modifier. Sélectionner
  /// "Aucune" remet à l'état buttons vide.
  Widget _buildDependenceSelector(int index, String suffix) {
    final occ = _occupants[index];
    final value = occ.dependenceTxt.trim();
    return FormToggleGroup(
      label: 'Dépendance$suffix',
      options: _dependenceOptions,
      columns: 2,
      selected: value.isEmpty ? 'Aucune' : value,
      onChanged: (v) {
        _updateOccupant(
          index,
          occ.copyWith(dependenceTxt: v == 'Aucune' ? '' : v),
        );
      },
    );
  }

  Widget _buildAidesDependenceBlock(int index) {
    final occ = _occupants[index];
    final firstName = occ.firstName.trim().split(' ').first;
    final hasMultiple = _occupants.length > 1;
    final suffix = hasMultiple
        ? (firstName.isNotEmpty ? ' de $firstName' : " de l'occupant ${index + 1}")
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Situation$suffix',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 8),
        _buildCollapsibleOptionCheckbox(
          label: 'Bénéficiaire APA',
          checked: occ.apa,
          value: occ.apaGir.trim(),
          options: _apaGirOptions,
          optionLabel: (v) => 'GIR $v',
          optionColumns: 3,
          onCheckedChanged: (v) {
            _updateOccupant(
              index,
              occ.copyWith(
                apa: v,
                apaGir: v ? occ.apaGir : '',
              ),
            );
          },
          onValueChanged: (v) {
            _updateOccupant(index, occ.copyWith(apaGir: v));
          },
        ),
        _buildCollapsibleOptionCheckbox(
          label: 'Reconnaissance Invalidité',
          checked: occ.invalidity,
          value: occ.invalidityTxt.trim(),
          options: _mdphPercentageOptions,
          optionLabel: (v) => v,
          optionColumns: 1,
          onCheckedChanged: (v) {
            _updateOccupant(
              index,
              occ.copyWith(
                invalidity: v,
                invalidityTxt: v ? occ.invalidityTxt : '',
              ),
            );
          },
          onValueChanged: (v) {
            _updateOccupant(index, occ.copyWith(invalidityTxt: v));
          },
        ),
        FormCheckbox(
          label: 'Aide à domicile',
          value: occ.homeHelp,
          onChanged: (v) => _updateOccupant(
              index,
              occ.copyWith(
                homeHelp: v,
                homeHelpTxt: v ? occ.homeHelpTxt : '',
              )),
        ),
        const SizedBox(height: 10),
        _buildDependenceSelector(index, suffix),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Admin (ex-Dossier)
  // ---------------------------------------------------------------------------

  Widget _buildAdminPersonalBlock(int index) {
    final occ = _occupants[index];
    final firstName = occ.firstName.trim().split(' ').first;
    final hasMultiple = _occupants.length > 1;
    final suffix = hasMultiple
        ? (firstName.isNotEmpty ? ' de $firstName' : " de l'occupant ${index + 1}")
        : '';
    final caissePrinc = occ.caisseRetraitePrincipale.trim();
    final caisseCompl = occ.caissesRetraiteComplementaires.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormTextField(
          label: 'N° Sécu$suffix',
          value: occ.numeroSecuriteSociale,
          onChanged: (v) => _updateOccupant(
              index, occ.copyWith(numeroSecuriteSociale: v)),
        ),
        const SizedBox(height: 14),
        FormSelectDropdown<String>(
          label: 'Caisse princ.$suffix',
          value: _principalFundNames.contains(caissePrinc)
              ? caissePrinc
              : null,
          options: _principalFundNames
              .map((name) =>
                  FormSelectOption<String>(value: name, label: name))
              .toList(),
          placeholder: 'Sélectionner...',
          onChanged: (v) {
            _updateOccupant(
              index,
              occ.copyWith(caisseRetraitePrincipale: v ?? ''),
            );
          },
        ),
        const SizedBox(height: 14),
        FormSelectDropdown<String>(
          label: 'Caisse complém.$suffix',
          value: _retirementFundNames.contains(caisseCompl)
              ? caisseCompl
              : null,
          options: _retirementFundNames
              .map((name) =>
                  FormSelectOption<String>(value: name, label: name))
              .toList(),
          placeholder: 'Sélectionner une caisse',
          onChanged: (v) {
            _updateOccupant(
              index,
              occ.copyWith(caissesRetraiteComplementaires: v ?? ''),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAdminSection() {
    final trustedPhoneInvalid = !isValidFrenchPhone(_trustedPhone);
    final trustedEmailInvalid = !isValidEmail(_trustedEmail);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // --- Bloc "Personnel" : un bloc par occupant, labels personnalisés
        // avec le prénom quand le foyer a 2+ personnes.
        for (int i = 0; i < _occupants.length; i++) ...[
          if (i > 0) const SizedBox(height: 18),
          _buildAdminPersonalBlock(i),
        ],
        const SizedBox(height: 24),

        // --- Bloc "Personne de Confiance" (titre retiré) ----------------
        FormTextField(
          label: 'Personne de confiance',
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
        const SizedBox(height: 24),

        // --- Bloc "Renseignements sur la visite" (titre retiré) ---------
        FormToggleGroup(
          label: 'Envoi du rapport',
          options: const ['Mail', 'Courrier'],
          selected: _envoiRapport,
          columns: 2,
          onChanged: (v) {
            _envoiRapport = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 24),

        // --- Bloc "Informations Administratives" (titre retiré) ---------
        FormSelectDropdown<String>(
          label: 'Création compte Anah',
          value: _compteAnah.isEmpty ? null : _compteAnah,
          options: _anahOptions,
          onChanged: (v) {
            _compteAnah = v ?? '';
            _markChanged();
          },
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

  /// Si false, le label "Date de naissance" n'est pas rendu au-dessus du
  /// cadre — utile quand le label est déjà affiché ailleurs (ex : sur la
  /// même ligne que l'OccupantSwitcher).
  final bool showLabel;

  const _DateOfBirthField({
    required this.birthDate,
    required this.onChanged,
    this.showLabel = true,
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

  /// Flow séquentiel année → mois → jour (3 dialogs successifs) demandé
  /// par l'utilisateur — plus rapide que le DatePicker Material pour
  /// atteindre une année ancienne (1940, 1955...).
  Future<void> _pickDate(BuildContext context) async {
    final initial = _parse(birthDate) ?? DateTime(1960, 1, 1);
    final now = DateTime.now();

    // 1) Année — grille 3 colonnes, du plus récent au plus ancien.
    final years = List<int>.generate(
      now.year - 1900 + 1,
      (i) => now.year - i,
    );
    final year = await _pickFromGrid(
      context,
      title: 'Année de naissance',
      labels: years.map((y) => y.toString()).toList(),
      values: years,
      initialValue: initial.year,
    );
    if (year == null) return;

    // 2) Mois — grille 3 colonnes, 12 mois FR abrégés pour tenir large.
    const monthNames = [
      'Janv.', 'Févr.', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juil.', 'Août', 'Sept.', 'Oct.', 'Nov.', 'Déc.',
    ];
    if (!context.mounted) return;
    final months = List<int>.generate(12, (i) => i + 1);
    final month = await _pickFromGrid(
      context,
      title: 'Mois',
      labels: monthNames,
      values: months,
      initialValue: initial.month,
    );
    if (month == null) return;

    // 3) Jour — vrai calendrier (7 colonnes L M M J V S D).
    if (!context.mounted) return;
    final day = await _pickDayCalendar(
      context,
      year: year,
      month: month,
      initialDay: initial.day,
    );
    if (day == null) return;

    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    onChanged('$y-$m-$d');
  }

  /// Grille de sélection (3 colonnes), utilisée pour année et mois.
  Future<int?> _pickFromGrid(
    BuildContext context, {
    required String title,
    required List<String> labels,
    required List<int> values,
    required int initialValue,
  }) {
    assert(labels.length == values.length);
    final initialIdx = values.indexOf(initialValue);
    final scrollCtrl = ScrollController(
      initialScrollOffset:
          initialIdx > 5 ? ((initialIdx ~/ 3) - 1) * 56.0 : 0,
    );
    return showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        // `pending` = sélection en cours (sert à animer le pavé qu'on vient
        // de toucher avant que le dialog ne se ferme). On pop avec un léger
        // délai pour laisser l'AnimatedContainer jouer sa transition.
        int pending = initialValue;
        bool closing = false;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            title: Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            content: SizedBox(
              width: 320,
              height: 360,
              child: Scrollbar(
                controller: scrollCtrl,
                child: GridView.builder(
                  controller: scrollCtrl,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.2,
                  ),
                  itemCount: values.length,
                  itemBuilder: (_, i) {
                    final isSelected = values[i] == pending;
                    return InkWell(
                      onTap: closing
                          ? null
                          : () {
                              setLocal(() {
                                pending = values[i];
                                closing = true;
                              });
                              // Laisse l'animation jouer avant de fermer.
                              Future.delayed(
                                const Duration(milliseconds: 220),
                                () {
                                  if (Navigator.of(dialogCtx).canPop()) {
                                    Navigator.pop(dialogCtx, values[i]);
                                  }
                                },
                              );
                            },
                      borderRadius: BorderRadius.circular(10),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF0F172A)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                          child: Text(labels[i]),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.only(right: 16, bottom: 8),
            actions: [
              TextButton(
                onPressed: closing
                    ? null
                    : () => Navigator.pop(dialogCtx, null),
                child: const Text(
                  'Annuler',
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Mini-calendrier pour un mois donné (7 colonnes L M M J V S D).
  /// Retourne le jour choisi (1..31) ou null si annulé.
  Future<int?> _pickDayCalendar(
    BuildContext context, {
    required int year,
    required int month,
    required int initialDay,
  }) {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final firstDay = DateTime(year, month, 1);
    // Flutter : weekday va de 1 (lundi) à 7 (dimanche). On veut les cases
    // vides AVANT le 1er = weekday - 1.
    final leadingBlanks = firstDay.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final effectiveInitial =
        initialDay <= daysInMonth ? initialDay : 1;

    const weekdayLabels = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
    const monthFullNames = [
      'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre',
    ];

    return showDialog<int>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(
          '${monthFullNames[month - 1]} $year',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        content: SizedBox(
          width: 320,
          height: 320,
          child: Column(
            children: [
              // En-tête jours de la semaine
              Row(
                children: weekdayLabels
                    .map(
                      (l) => Expanded(
                        child: Container(
                          height: 28,
                          alignment: Alignment.center,
                          child: Text(
                            l,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: totalCells,
                  itemBuilder: (_, idx) {
                    if (idx < leadingBlanks) return const SizedBox.shrink();
                    final dayNumber = idx - leadingBlanks + 1;
                    final isSelected = dayNumber == effectiveInitial;
                    return InkWell(
                      onTap: () => Navigator.pop(dialogCtx, dayNumber),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF0F172A)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$dayNumber',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.only(right: 16, bottom: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, null),
            child: const Text(
              'Annuler',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final display = _formatDisplay(birthDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          const Text(
            'Date de naissance',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
        ],
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
