import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';
import '../../services/dossier_repository.dart';
import '../../services/references_service.dart';
import '../../services/save_debounce.dart';
import '../../services/retirement_funds_repository.dart';
import '../../components/commune_field_group.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';
import '../../components/two_threshold_swipe.dart';

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

  /// Sous-section suivante / précédente, déclenché par un swipe LARGE
  /// horizontal (≥ 55 % de la largeur). Boucle de 0 à 3 inclus
  /// (Profil / Foyer / Santé / Admin) — les pills indiquent la
  /// sous-section courante.
  ///
  /// **Le swipe sous-section a été désactivé en avril 2026** (demande
  /// utilisateur — slide réservé aux occupants). Les helpers restent
  /// présents au cas où on voudrait les réactiver, mais ils ne sont
  /// plus appelés. Le QuickNav (tap pills) gère la nav sous-section.
  // ignore: unused_element
  void _subSectionNext() {
    _setSubSection((_subSectionIndex + 1) % 4);
  }
  // ignore: unused_element
  void _subSectionPrev() {
    _setSubSection((_subSectionIndex - 1 + 4) % 4);
  }

  /// Occupant suivant / précédent, déclenché par un swipe LÉGER
  /// horizontal (< 35 % de la largeur). Disponible uniquement sur
  /// Profil / Santé / Admin (pas Foyer) et seulement s'il y a > 1
  /// occupant dans le foyer.
  void _occupantNext() {
    if (_occupants.length <= 1) return;
    setState(() {
      _currentOccupantIndex =
          (_currentOccupantIndex + 1) % _occupants.length;
    });
  }
  void _occupantPrev() {
    if (_occupants.length <= 1) return;
    setState(() {
      _currentOccupantIndex =
          (_currentOccupantIndex - 1 + _occupants.length) % _occupants.length;
    });
  }

  /// La sous-section courante affiche-t-elle des champs par-occupant ?
  /// (Profil / Santé / Admin → oui, Foyer → non)
  bool _hasOccupantSwipeInCurrentSection() {
    return (_subSectionIndex == 0 ||
            _subSectionIndex == 2 ||
            _subSectionIndex == 3) &&
        _occupants.length > 1;
  }

  /// Index de l'occupant actuellement visible dans les sous-sections
  /// "par occupant" (Profil / Santé / Admin). Partagé entre ces sections
  /// pour que l'ergo reste sur le même occupant en changeant de section.
  /// Mis à jour par un swipe horizontal sur le panneau ou en interne
  /// quand la composition du foyer change.
  int _currentOccupantIndex = 0;
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
    _occupationStatus = p.occupationStatus;
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
    // Debounce uniformisé sur kSaveDebounceText (400 ms) — laisse les
    // pauses naturelles entre lettres passer sans déclencher un save
    // mid-mot. Avant 150 ms, des frappes "BALS" ressortaient parfois
    // en "BAL" en SQLite (fix dossier_screen Apr 2026).
    _saveTimer = Timer(kSaveDebounceText, _save);
  }

  void _markChanged() {
    setState(() {});
    _scheduleSave();
  }

  Future<void> _save() async {
    // Pas de `setState(_saving = true/false)` — voir dossier_screen.dart
    // pour le rationale (rebuild lourd à chaque keystroke avec save à
    // 0 ms). `SaveStatusIndicator` est de toute façon vide.
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
        // Statut d'occupation (Propriétaire / Locataire / Usufruitier).
        // Avant ce push, le champ n'était jamais sauvé → la sélection
        // utilisateur restait orpheline en mémoire et le PDF affichait
        // par défaut la case « Propriétaire » cochée pour tous les
        // dossiers. Maintenant le serveur reçoit la vraie valeur (ou
        // vide si l'utilisateur n'a rien coché → aucune case dans le PDF).
        'occupation_status': _occupationStatus,
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
    final hasOccupantSwipe = _hasOccupantSwipeInCurrentSection();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Bandeau sous-menu : fond violet clair en pleine largeur, collé
        // au bord supérieur de la card — même traitement que le bandeau
        // "Bénéficiaire" de l'écran dossier.
        _buildQuickNav(),
        // La sous-section active gère elle-même son scroll interne +
        // épingle ses points de pagination en bas du cadre. On lui
        // donne directement l'espace restant via Expanded.
        //
        // Swipe horizontal à deux seuils (cf. TwoThresholdSwipe) :
        //   - léger (< 35 % largeur) → occupant suivant/précédent
        //     (uniquement sur Profil / Santé / Admin, pas Foyer)
        //   - large (≥ 55 % largeur) → sous-section suivante/précédente
        // Demande utilisateur 2026-04-28 : « le slide doit être léger
        // et centré pour switch entre les occupants, mais sur toute la
        // majeur partie de la largeur d'une sous partie ça change de
        // sous partie ».
        // Swipe SECTIONS désactivé (demande utilisateur 2026-04-29) :
        // les sous-sections changent uniquement via le QuickNav (tap).
        // Seul le swipe LÉGER (occupant) reste actif quand le foyer a
        // plusieurs personnes — équivaut à « slide entre occupants ».
        Expanded(
          child: TwoThresholdSwipe(
            onLightSwipeLeft: hasOccupantSwipe ? _occupantNext : null,
            onLightSwipeRight: hasOccupantSwipe ? _occupantPrev : null,
            child: _buildActiveSection(),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickNav() {
    final items = const <_QuickNavItem>[
      _QuickNavItem(icon: Icons.person_outline, label: 'Profil'),
      _QuickNavItem(icon: Icons.home_outlined, label: 'Foyer'),
      _QuickNavItem(icon: Icons.favorite_outline, label: 'Santé'),
      _QuickNavItem(icon: Icons.folder_open_outlined, label: 'Admin'),
    ];
    // Bandeau full-width sans fond ni border-radius (demande utilisateur
    // 2026-04-28 : « retire le fond rose clair »). Padding vertical
    // uniquement — la zone cliquable de chaque pill s'étend toujours
    // bord à bord via l'Expanded.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: Colors.transparent,
      child: Row(
        children: List.generate(items.length, (i) {
          final active = i == _subSectionIndex;
          // Sans fond : icon/texte/trait actifs en violet foncé
          // (#7C6DAA). Inactif : pastel lilas.
          const activeColor = Color(0xFF7C6DAA);
          const inactiveColor = Color(0xFFAE9DB3);
          return Expanded(
            child: SoftTapScale(
              // Zoom/dezoom au tap — mêmes sensations que les boutons
              // de la sidebar.
              onTap: () => _setSubSection(i),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      items[i].icon,
                      size: 20,
                      color: active ? activeColor : inactiveColor,
                    ),
                    const SizedBox(height: 2),
                    // Trait actif = LARGEUR EXACTE DU MOT (demande
                    // utilisateur 2026-04-28). On wrap Text + trait
                    // dans un IntrinsicWidth qui calque sa largeur
                    // sur celle du Text, puis crossAxisAlignment.stretch
                    // étire le trait pour combler cette largeur.
                    IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            items[i].label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color:
                                  active ? activeColor : inactiveColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            height: 1.5,
                            decoration: BoxDecoration(
                              color: active
                                  ? activeColor
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ],
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
    final Widget section;
    switch (_subSectionIndex) {
      case 0:
        section = _buildProfilSection();
        break;
      case 1:
        section = _buildFinanceSection();
        break;
      case 2:
        section = _buildSanteSection();
        break;
      case 3:
        section = _buildAdminSection();
        break;
      default:
        section = const SizedBox.shrink();
    }
    // Légère animation entre sous-sections — fade + apparition vers
    // le haut, identique au switch entre vues principales (sidebar
    // → Accueil/Dossiers/Bibliothèque…). Bascule rapide qui rappelle
    // à l'utilisateur que le contenu vient de changer.
    return SoftSwitcher(
      child: KeyedSubtree(
        key: ValueKey<int>(_subSectionIndex),
        child: section,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profil
  // ---------------------------------------------------------------------------

  Widget _buildBirthDateRow(int index) {
    final occ = _occupants[index];
    // Plus de "de <Prénom>" dans le label — l'occupant courant est déjà
    // identifié par le header du cadre quand on swipe entre occupants.
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
    final idx =
        _currentOccupantIndex.clamp(0, _occupants.length - 1);
    return _buildOccupantSwipeContainer(
      perOccupantContent: _buildBirthDateRow(idx),
      sharedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bloc "Coordonnées" — partagé pour tout le foyer (téléphone
          // et email ne changent pas d'un occupant à l'autre).
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
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers "occupant swipe" — header + content + pagination dots, avec
  // un GestureDetector horizontal englobant pour la navigation tactile.
  // ---------------------------------------------------------------------------

  /// Compose un bloc "par occupant" :
  ///   [header avec prénom de l'occupant courant]
  ///   [perOccupantContent]  ← ce qui dépend de l'occupant (date de
  ///                           naissance, APA, invalidité, n° sécu…)
  ///   [sharedContent]       ← ce qui est commun à tous (téléphone,
  ///                           personne de confiance, compte Anah…)
  ///   [pagination dots en bas]
  ///
  /// L'ensemble du bloc réagit au swipe horizontal (iPad) : un glissement
  /// vers la gauche passe à l'occupant suivant, vers la droite au
  /// précédent. Le header + la partie "per occupant" changent ;
  /// `sharedContent` reste identique.
  ///
  /// Quand le foyer n'a qu'une personne, le header et les dots
  /// disparaissent (pas de navigation nécessaire).
  Widget _buildOccupantSwipeContainer({
    required Widget perOccupantContent,
    required Widget sharedContent,
  }) {
    final hasMultiple = _occupants.length > 1;
    if (!hasMultiple) {
      // Pas de navigation nécessaire — on rend simplement le contenu
      // scrollable comme avant (pas de header, pas de dots, pas de swipe).
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            perOccupantContent,
            const SizedBox(height: 24),
            sharedContent,
          ],
        ),
      );
    }
    final idx = _currentOccupantIndex.clamp(0, _occupants.length - 1);
    // Column principal :
    //   - header + contenu scrollable (Expanded)
    //   - dots pinnés tout en bas du cadre (hors scroll)
    //
    // Le GestureDetector horizontal a été retiré ici : le swipe est
    // désormais géré au niveau du `build()` parent via
    // `TwoThresholdSwipe` (light → occupant, large → sous-section).
    // Garder un détecteur ici en plus créerait un conflit d'arène
    // dans les sous-sections Profil/Santé/Admin.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Toute la zone occupant (header + champs « per occupant » +
        // sharedContent) glisse en bloc lors d'un changement
        // d'occupant. Les dots de pagination, eux, restent fixes en
        // bas — ce sont des indicateurs de navigation, pas du
        // contenu de l'occupant.
        Expanded(
          child: HorizontalSlideSwitcher(
            index: idx,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header sticky : prénom de l'occupant courant, fond
                // blanc opaque pour cacher le contenu qui défile.
                Container(
                  color: Colors.white,
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: _buildOccupantHeader(idx),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        perOccupantContent,
                        const SizedBox(height: 24),
                        sharedContent,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Dots pinnés au bas du cadre — toujours visibles quel que
        // soit l'état du scroll interne. Hors du switcher pour ne
        // pas glisser avec le contenu.
        Padding(
          padding: const EdgeInsets.only(bottom: 14, top: 6),
          child: Center(child: _buildOccupantDots(idx)),
        ),
      ],
    );
  }

  /// Header affichant le prénom + nom de l'occupant courant, en violet
  /// foncé — change quand l'ergo swipe.
  Widget _buildOccupantHeader(int idx) {
    final occ = _occupants[idx];
    final first = occ.firstName.trim();
    final last = occ.lastName.trim();
    final fallback = "Occupant ${idx + 1}";
    final display = (first.isEmpty && last.isEmpty)
        ? fallback
        : [first, last.toUpperCase()].where((s) => s.isNotEmpty).join(' ');
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

  /// Points de pagination en bas du cadre — un par occupant, le courant
  /// est violet plein, les autres gris clair. Cliquables pour sauter
  /// directement à un occupant sans passer par tous.
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_occupants.length, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _currentOccupantIndex = i),
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

  // ---------------------------------------------------------------------------
  // Foyer (ex-Revenus) — composition du foyer, sans les champs revenus.
  // ---------------------------------------------------------------------------

  Widget _buildFinanceSection() {
    // Foyer n'a aucune donnée "par occupant" (situation familiale et
    // occupation sont partagées pour le ménage). On conserve donc un
    // simple SingleChildScrollView sans header / swipe / dots.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
      ),
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
            color: const Color(0xFFF7F7FA),
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
    final idx =
        _currentOccupantIndex.clamp(0, _occupants.length - 1);
    return _buildOccupantSwipeContainer(
      perOccupantContent: _buildAidesDependenceBlock(idx),
      sharedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bloc "Visite" — partagé (une seule fois par dossier).
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
      ),
    );
  }

  /// Case à cocher qui, une fois cochée, affiche directement la liste
  /// des options en pills sous la ligne. Les boutons restent visibles en
  /// permanence (pas de repli en "label (valeur) + crayon") pour que
  /// l'ergo puisse changer rapidement.
  /// Case à cocher ronde (style maquette utilisateur) avec libellé à
  /// droite. Tap sur la ligne entière (case + label) pour basculer
  /// l'état. Quand cochée, affiche les options en pills sous la ligne.
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
        _RoundCheckRow(
          label: label,
          checked: checked,
          onTap: () => onCheckedChanged(!checked),
        ),
        // Pills d'options visibles uniquement quand la case est cochée.
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
  Widget _buildDependenceSelector(int index) {
    final occ = _occupants[index];
    final value = occ.dependenceTxt.trim();
    // Plus de "de <Prénom>" dans le label — l'occupant courant est déjà
    // identifié par l'en-tête du cadre et la navigation par swipe.
    return FormToggleGroup(
      label: 'Dépendance',
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titre "Situation" sans suffixe "de <Prénom>" — redondant depuis
        // l'introduction du swipe par occupant (header du cadre identifie
        // déjà l'occupant courant).
        const Text(
          'Situation',
          style: TextStyle(
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
        _RoundCheckRow(
          label: 'Aide à domicile',
          checked: occ.homeHelp,
          onTap: () => _updateOccupant(
            index,
            occ.copyWith(
              homeHelp: !occ.homeHelp,
              homeHelpTxt: !occ.homeHelp ? occ.homeHelpTxt : '',
            ),
          ),
        ),
        const SizedBox(height: 10),
        _buildDependenceSelector(index),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Admin (ex-Dossier)
  // ---------------------------------------------------------------------------

  Widget _buildAdminPersonalBlock(int index) {
    final occ = _occupants[index];
    // Plus de suffixe "de <Prénom>" — l'occupant courant est identifié
    // par le header du cadre (swipe par occupant).
    final caissePrinc = occ.caisseRetraitePrincipale.trim();
    final caisseCompl = occ.caissesRetraiteComplementaires.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormTextField(
          label: 'N° Sécu',
          value: occ.numeroSecuriteSociale,
          onChanged: (v) => _updateOccupant(
              index, occ.copyWith(numeroSecuriteSociale: v)),
        ),
        const SizedBox(height: 14),
        // Caisse principale + caisse complémentaire sur la même ligne
        // (demande utilisateur). Chaque dropdown occupe la moitié de
        // la largeur avec un petit gap au centre.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: FormSelectDropdown<String>(
                label: 'Caisse princ.',
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
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FormSelectDropdown<String>(
                label: 'Caisse complém.',
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
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdminSection() {
    final trustedPhoneInvalid = !isValidFrenchPhone(_trustedPhone);
    final trustedEmailInvalid = !isValidEmail(_trustedEmail);
    final idx =
        _currentOccupantIndex.clamp(0, _occupants.length - 1);
    return _buildOccupantSwipeContainer(
      perOccupantContent: _buildAdminPersonalBlock(idx),
      sharedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bloc "Personne de Confiance" — partagé (une personne de
          // confiance pour le foyer, pas par occupant).
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

          // --- Bloc "Renseignements sur la visite" — partagé.
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

          // --- Bloc "Informations Administratives" — partagé (compte
          // Anah est un seul dossier au niveau ménage).
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
      ),
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
    return showSoftDialog<int>(
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

    return showSoftDialog<int>(
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
        // fontSize 12 + padding vertical 10 → aligné sur le pill
        // "Vasque suspendue" (référence de tous les champs du relevé).
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
                      fontSize: 12,
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

/// Ligne "case ronde + libellé" pour la section Santé > Situation —
/// parité avec la maquette utilisateur (Bénéficiaire APA / Reconnaissance
/// invalidité / Aide à domicile).
///
/// • État coché  : cercle violet plein `#7C6DAA` + ✓ blanc.
/// • État non-coché : cercle vide à contour gris clair.
/// • Tap sur la ligne entière (case + label) → bascule l'état.
class _RoundCheckRow extends StatelessWidget {
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _RoundCheckRow({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            // Cercle de check 20×20 — violet plein si coché, contour
            // gris-lilas sinon.
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: checked ? const Color(0xFF7C6DAA) : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: checked
                      ? const Color(0xFF7C6DAA)
                      : const Color(0xFFCBD5E1),
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.check,
                size: 12,
                color: checked ? Colors.white : Colors.transparent,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF334155),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
