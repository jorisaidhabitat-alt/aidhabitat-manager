import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/data_service.dart';
import '../../services/dossier_repository.dart';
import '../../services/nocodb_api_client.dart';
import '../../services/references_service.dart';
import '../../services/save_debounce.dart';
import '../../services/retirement_funds_repository.dart';
import '../../components/brand_colors.dart';
import '../../components/cached_remote_image.dart';
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

  // Caisses de retraite — version 2026-05-12 : on stocke les objets
  // complets (logo, audience, montant aide) pour pouvoir alimenter le
  // picker visuel style cards 3-cols (comme les préconisations).
  // Demande utilisateur : « pour la caisse de retraite complémentaire
  // ou la caisse de retraite principale, il faut que ça ouvre une pop
  // up avec les caisses concernées avec les logos, les titres et les
  // descriptions sous forme de cards 3 par 3 ».
  // _retirementFundNames retiré 2026-05-12 : remplacé par _retirementFunds
  // (objets complets) pour alimenter le picker visuel.
  List<String> _principalFundNames = const [];
  List<RetirementFund> _retirementFunds = const [];
  List<Map<String, String>> _principalFunds = const [];

  // ANAH options — version 2026-05-04 : 3 statuts seulement, le
  // « Mandat » historique est désormais une question séparée
  // (création mandat Oui/Non + Nous/Autre) gérée plus bas dans le
  // bloc Profil → Compte ANAH.
  static const List<String> _anahStatusOptions = [
    'A faire',
    'A vérifier',
    'Déjà fait',
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
      _recomputeIncomeCategory();
    });
    _loadRetirementFundNames();
    _loadPrincipalFundNames();
  }

  Future<void> _loadRetirementFundNames() async {
    try {
      final funds = await RetirementFundsRepository().fetchAllFunds();
      if (!mounted) return;
      final filtered = funds.where((f) => f.name.trim().isNotEmpty).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      setState(() {
        _retirementFunds = filtered;
      });
    } catch (_) {
      // silent
    }
  }

  Future<void> _loadPrincipalFundNames() async {
    try {
      // Récupère les objets complets (avec logoUrl + phone) pour
      // alimenter le picker visuel. Fallback : si l'endpoint plein
      // échoue, on retombe sur la liste de noms seule (anciennement
      // unique source). De cette manière le picker fonctionne sur
      // device offline ayant déjà cache les noms.
      final funds = await NocodbApiClient().fetchPrincipalRetirementFunds();
      if (!mounted) return;
      final sorted = [...funds]
        ..sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
      setState(() {
        _principalFunds = sorted;
        _principalFundNames =
            sorted.map((f) => f['name'] ?? '').where((n) => n.isNotEmpty).toList();
      });
    } catch (_) {
      // Fallback historique : juste les noms via l'API legacy.
      try {
        final names = await DataService().fetchPrincipalRetirementFundNames();
        if (!mounted) return;
        setState(() {
          _principalFundNames = names.toList()..sort();
          _principalFunds = _principalFundNames
              .map((n) => {'name': n, 'logoUrl': '', 'phone': ''})
              .toList();
        });
      } catch (_) {
        // silent
      }
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
      Occupant occ;
      if (i < existing.length) {
        occ = existing[i];
      } else if (i < fallbacks.length) {
        occ = fallbacks[i];
      } else {
        occ = const Occupant();
      }
      // Override firstName/lastName depuis les champs TOP-LEVEL du
      // patient pour les 2 premiers occupants. Source de vérité :
      //   - occupant 0 → `p.firstName` / `p.lastName`
      //   - occupant 1 → `p.secondFirstName` / `p.secondLastName`
      // Sans cet override, quand l'ergo change le nom dans
      // `dossier_screen`, le header occupant restait sur l'ancienne
      // valeur stockée dans `p.occupants[0]` (qui n'est sync'é qu'au
      // save différé) — bug signalé 2026-04-29 : « quand je change le
      // nom, le changement n'est pas instantané pour le nom de
      // l'occupant s'il y'en a plusieurs ».
      if (i == 0) {
        occ = occ.copyWith(firstName: p.firstName, lastName: p.lastName);
      } else if (i == 1 &&
          (p.secondFirstName.isNotEmpty || p.secondLastName.isNotEmpty)) {
        occ = occ.copyWith(
          firstName: p.secondFirstName,
          lastName: p.secondLastName,
        );
      }
      merged.add(occ);
    }
    return merged;
  }

  @override
  void didUpdateWidget(covariant BeneficiaryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Quand le parent change `initialSubSection` (ex. navigation
    // depuis la popup « Champs manquants »), bascule la sous-section
    // courante. Doit fonctionner même si l'onglet a déjà été visité,
    // donc on ne peut pas se contenter de l'init dans `initState`.
    if (oldWidget.initialSubSection != widget.initialSubSection) {
      final next = widget.initialSubSection.clamp(0, 3);
      if (next != _subSectionIndex) {
        setState(() => _subSectionIndex = next);
        widget.onSubSectionChanged?.call(next);
      }
    }
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
        // Swipe horizontal → toujours change d'occupant (peu importe
        // l'amplitude, léger ou large). Sous-sections via tap QuickNav
        // exclusivement (demande utilisateur 2026-04-29).
        Expanded(
          child: TwoThresholdSwipe(
            onLightSwipeLeft: hasOccupantSwipe ? _occupantNext : null,
            onLightSwipeRight: hasOccupantSwipe ? _occupantPrev : null,
            onWideSwipeLeft: hasOccupantSwipe ? _occupantNext : null,
            onWideSwipeRight: hasOccupantSwipe ? _occupantPrev : null,
            child: _buildActiveSection(),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickNav() {
    final items = const <_QuickNavItem>[
      // Refonte 2026-05-13 (maquette user) : icônes Material outlined
      // remplacées par leurs équivalents LucideIcons (stroke fin,
      // moins « bold », parité avec le reste de l'app).
      _QuickNavItem(icon: LucideIcons.user, label: 'Profil'),
      _QuickNavItem(icon: LucideIcons.home, label: 'Foyer'),
      _QuickNavItem(icon: LucideIcons.heart, label: 'Santé'),
      _QuickNavItem(icon: LucideIcons.folderOpen, label: 'Admin'),
    ];
    // Bandeau full-width violet pâle restauré (demande utilisateur
    // 2026-04-29 : les changements « pas de fond + trait pleine
    // largeur » ne concernent QUE la barre de navigation principale du
    // relevé, pas les sous-sections internes des onglets).
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: const Color(0xFFF2ECF5),
      child: Row(
        children: List.generate(items.length, (i) {
          final active = i == _subSectionIndex;
          // Refonte 2026-05-13 (maquette user) : icons et texte en NOIR
          // dans les 2 états. Le violet (#8B6FA0) ne subsiste que sur
          // le trait sous le label de l'item actif. Inactive = même
          // couleur que active, juste pas de trait → comportement type
          // tab indicator moderne.
          const labelColor = Color(0xFF0E1116); // ink-900
          const underlineColor = kBrandPurple; // mauve-500
          return Expanded(
            child: SoftTapScale(
              onTap: () => _setSubSection(i),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      items[i].icon,
                      // 20 → 18 → 16 (demande user 2026-05-13 : icons
                      // plus petits + strokes paraissent plus fins).
                      // `lucide_icons` est un font icon → stroke fixe,
                      // pas de strokeWidth dispo ; réduire la taille est
                      // la façon native d'amincir visuellement.
                      size: 16,
                      color: labelColor,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      items[i].label,
                      style: const TextStyle(
                        // 10 → 12 (demande user 2026-05-13 : « 2px plus
                        // grand »).
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: labelColor,
                      ),
                    ),
                    // Trait fin violet uniquement sous l'item actif —
                    // seul élément différenciateur visuel.
                    const SizedBox(height: 6),
                    Container(
                      height: 1.5,
                      width: (items[i].label.length * 3.2)
                          .clamp(18.0, 50.0),
                      decoration: BoxDecoration(
                        color:
                            active ? underlineColor : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
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
          // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Color(0xFF0E1116),
          ),
        ),
        const SizedBox(height: 5),
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
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF554265),
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
    final anah = _parseAnahData(_compteAnah);
    return _buildOccupantSwipeContainer(
      perOccupantContent: _buildBirthDateRow(idx),
      sharedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bloc "Coordonnées" — partagé pour tout le foyer (téléphone
          // et email ne changent pas d'un occupant à l'autre). Disposés
          // côte à côte sur la même ligne (demande utilisateur 2026-05-04)
          // pour gagner de la place verticale dans la sous-section Profil.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FormTextFieldWithWarning(
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
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FormTextFieldWithWarning(
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
              ),
            ],
          ),
          const SizedBox(height: 24),

          // --- Bloc "Compte ANAH" — déplacé depuis Admin (demande
          // utilisateur 2026-05-04). 3 sous-questions :
          //   1. Création compte (3 statuts)
          //   2. Création mail (Oui/Non)
          //   3. Création mandat (Oui/Non) → Nous/Autre → champ texte
          // Toutes les valeurs sont sérialisées en JSON dans la colonne
          // `compte_anah` (cf. _parseAnahData / _serializeAnahData).
          // Refonte 2026-05-13 (visit-pages.js l.488-492) : pour le
          // formulaire « Création compte ANAH », ce sont des pills
          // mauves normales (FormToggleGroup). Les couleurs sémantiques
          // (todo rouge / check orange / done vert du `.vp-anah`) sont
          // utilisées UNIQUEMENT pour le badge status du header en haut
          // à droite — cf. `VisitReportScreen._buildAnahStatusBadge`.
          FormToggleGroup(
            label: 'Création compte ANAH',
            options: _anahStatusOptions,
            selected: anah['status'] ?? '',
            columns: 3,
            onChanged: (v) {
              final next = Map<String, String>.from(anah);
              next['status'] = v;
              _compteAnah = _serializeAnahData(next);
              _markChanged();
            },
          ),
          const SizedBox(height: 14),
          // Création mail + Création mandat en CASES À COCHER côte à
          // côte (demande utilisateur 2026-05-04 : « doivent être à
          // coché (facilement sur tablette) pas avec un oui/non car
          // cela prend trop de place »). Tap sur toute la ligne →
          // bascule. Coché = "Oui", décoché = "Non".
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _RoundCheckRow(
                  label: 'Création mail',
                  checked: (anah['mail'] ?? '') == 'Oui',
                  onTap: () {
                    final next = Map<String, String>.from(anah);
                    final wasChecked = (anah['mail'] ?? '') == 'Oui';
                    next['mail'] = wasChecked ? 'Non' : 'Oui';
                    _compteAnah = _serializeAnahData(next);
                    _markChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _RoundCheckRow(
                  label: 'Création mandat',
                  checked: (anah['mandat'] ?? '') == 'Oui',
                  onTap: () {
                    final next = Map<String, String>.from(anah);
                    final wasChecked = (anah['mandat'] ?? '') == 'Oui';
                    next['mandat'] = wasChecked ? 'Non' : 'Oui';
                    // Si on décoche, on purge la sous-question « par
                    // qui » pour éviter une donnée orpheline.
                    if (wasChecked) {
                      next.remove('mandatPar');
                      next.remove('mandatAutre');
                    }
                    _compteAnah = _serializeAnahData(next);
                    _markChanged();
                  },
                ),
              ),
            ],
          ),
          if ((anah['mandat'] ?? '') == 'Oui') ...[
            const SizedBox(height: 10),
            FormToggleGroup(
              label: 'Mandat fait par',
              // « Nous » remplacé par « Aid'habitat » (demande
              // utilisateur 2026-05-04). Les valeurs persistées en
              // SQLite/NocoDB sont aussi mises à jour — pas de migration
              // automatique, les anciens dossiers avec `mandatPar=Nous`
              // restent OK (ne matchent juste plus l'option active dans
              // le toggle, l'ergo doit re-sélectionner).
              options: const ["Aid'habitat", 'Autre'],
              selected: anah['mandatPar'] ?? '',
              expand: true,
              onChanged: (v) {
                final next = Map<String, String>.from(anah);
                next['mandatPar'] = v;
                if (v != 'Autre') next.remove('mandatAutre');
                _compteAnah = _serializeAnahData(next);
                _markChanged();
              },
            ),
            if ((anah['mandatPar'] ?? '') == 'Autre') ...[
              const SizedBox(height: 10),
              FormTextField(
                label: 'Précisez qui',
                value: anah['mandatAutre'] ?? '',
                onChanged: (v) {
                  final next = Map<String, String>.from(anah);
                  next['mandatAutre'] = v;
                  _compteAnah = _serializeAnahData(next);
                  _markChanged();
                },
              ),
            ],
          ],
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

  /// Bannière occupant (refonte 2026-05-13, visit-pages.js l.453-465).
  /// Cf. context_tab._buildOccupantHeader pour la spec détaillée.
  Widget _buildOccupantHeader(int idx) {
    final occ = _occupants[idx];
    final first = occ.firstName.trim();
    final last = occ.lastName.trim();
    final fallback = "Occupant ${idx + 1}";
    final display = (first.isEmpty && last.isEmpty)
        ? fallback
        : [first, last.toUpperCase()].where((s) => s.isNotEmpty).join(' ');
    final total = _occupants.length;
    final hasNav = total > 1;
    // `role` (BÉNÉFICIAIRE PRINCIPAL / CONJOINT·E) retiré sur demande user
    // 2026-05-13 — le prénom NOM seul suffit, le rôle est redondant avec
    // la navigation prev/next + les dots de pagination.

    Widget arrow(IconData icon, VoidCallback action) {
      return Opacity(
        opacity: hasNav ? 1 : 0.35,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasNav ? action : null,
            // Refonte 2026-05-13 : pill radius 999 uniforme.
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(icon, size: 16, color: const Color(0xFF2B323A)),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FB), // mauve-50
        border: Border.all(color: const Color(0xFFF2ECF5)), // mauve-100
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          arrow(LucideIcons.chevronLeft, _occupantPrev),
          Expanded(
            child: Center(
              child: Text(
                display,
                style: GoogleFonts.nunito(
                  fontSize: 17,
                  // w700 → w600 (demande user 2026-05-13 : nom occupant
                  // « moins épais »).
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                  height: 1.15,
                  color: const Color(0xFF0E1116),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          arrow(LucideIcons.chevronRight, _occupantNext),
        ],
      ),
    );
  }

  /// Points de pagination en bas du cadre — un par occupant, le courant
  /// est violet plein, les autres gris clair. Cliquables pour sauter
  /// directement à un occupant sans passer par tous.
  /// Refonte 2026-05-13 : active = pill 18×5, inactive = dot 5×5.
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_occupants.length, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _currentOccupantIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: isActive ? 18 : 5,
              height: 5,
              decoration: BoxDecoration(
                color: isActive
                    ? kBrandPurple // mauve-500
                    : const Color(0xFFE4E7EB), // ink-200
                borderRadius: BorderRadius.circular(999),
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
          // Occupation : layout 2+1 demandé par l'utilisateur
          // (2026-04-29). Propriétaire / Locataire côte à côte
          // (2 colonnes, mêmes dimensions que les pills de
          // « Situation familiale »), Usufruitier en dessous,
          // pleine largeur. On utilise 2 FormToggleGroups :
          //   1. Le premier porte le label « Occupation » + les 2
          //      options principales (`expand: true` → Row+Expanded
          //      → 50/50 % width comme les buttons de Situation
          //      familiale en 2 colonnes).
          //   2. Le second n'a pas de label (`label: ''`), juste
          //      l'option Usufruitier seule qui s'étend en pleine
          //      largeur grâce à `expand: true`.
          // Les deux groupes partagent `_occupationStatus` donc le
          // toggle est mutuellement exclusif entre les 3 options.
          FormToggleGroup(
            label: 'Occupation',
            options: _occupationOptions.sublist(0, 2),
            selected: _occupationStatus,
            expand: true,
            onChanged: (v) {
              _occupationStatus = v;
              _markChanged();
            },
          ),
          const SizedBox(height: 8),
          FormToggleGroup(
            label: '',
            options: _occupationOptions.sublist(2),
            selected: _occupationStatus,
            expand: true,
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
            color: Color(0xFF5C6670),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7FA),
            // Refonte 2026-05-13 : pill radius 999 uniforme.
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF2B323A),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A939D)),
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

  /// Dépendance : liste de pills toutes égales (Aucune incluse). On
  /// stocke directement le libellé cliqué dans `dependenceTxt`. Le tap
  /// sur la pill déjà sélectionnée la désélectionne (cf. FormToggleGroup
  /// `allowDeselect=true`) → retour à `''` = non renseigné.
  ///
  /// NB : avant 2026-04-30, l'historique stockait `''` quand l'ergo
  /// cliquait « Aucune » (convention partagée avec NocoDB) — résultat :
  /// la pill « Aucune » ne pouvait jamais être visiblement highlighted,
  /// et un tap dessus était un no-op visible. Maintenant on stocke le
  /// libellé tel quel ("Aucune"). Côté NocoDB, `dependance_particuliere`
  /// (link) ne matchera pas "Aucune" (pas dans le ref list) et le
  /// fallback `dependance_particuliere_txt` recevra simplement "Aucune"
  /// comme texte — ce qui est sémantiquement correct.
  Widget _buildDependenceSelector(int index) {
    final occ = _occupants[index];
    final value = occ.dependenceTxt.trim();
    return FormToggleGroup(
      label: 'Dépendance',
      options: _dependenceOptions,
      columns: 2,
      selected: value,
      onChanged: (v) {
        // v peut être '' (désélection via FormToggleGroup.allowDeselect)
        // ou une des options (y compris « Aucune »). On stocke tel quel.
        _updateOccupant(index, occ.copyWith(dependenceTxt: v));
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
          // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Color(0xFF0E1116),
          ),
        ),
        const SizedBox(height: 5),
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
        // Caisse principale + caisse complémentaire sur la même ligne.
        // Refactor 2026-05-12 : remplacement des FormSelectDropdown par
        // un bouton cliquable qui ouvre un picker visuel style "cards"
        // (parité avec le picker des préconisations). Chaque card
        // affiche le logo + le nom + une description courte. L'ergo
        // peut aussi saisir un nom libre (caisse non listée).
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _RetirementFundFieldButton(
                label: 'Caisse princ.',
                value: caissePrinc,
                placeholder: 'Sélectionner...',
                onTap: () async {
                  final picked = await _openPrincipalFundPicker(caissePrinc);
                  if (picked == null) return;
                  _updateOccupant(
                    index,
                    occ.copyWith(caisseRetraitePrincipale: picked),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _RetirementFundFieldButton(
                label: 'Caisse complém.',
                value: caisseCompl,
                placeholder: 'Sélectionner une caisse',
                onTap: () async {
                  final picked =
                      await _openComplementaryFundPicker(caisseCompl);
                  if (picked == null) return;
                  _updateOccupant(
                    index,
                    occ.copyWith(caissesRetraiteComplementaires: picked),
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
          // Multi-select : l'ergo peut cocher Mail ET Courrier (demande
          // utilisateur 2026-05-04). Stocké en CSV "Mail, Courrier" dans
          // la colonne `envoi_rapport` (texte libre côté NocoDB).
          FormMultiToggleGroup(
            label: 'Envoi du rapport',
            options: const ['Mail', 'Courrier'],
            selected: _parseEnvoiRapport(_envoiRapport),
            columns: 2,
            onChanged: (next) {
              _envoiRapport = _serializeEnvoiRapport(next);
              _markChanged();
            },
          ),
          // NB : le bloc « Création compte ANAH » a été déplacé dans la
          // section Profil (demande utilisateur 2026-05-04). Voir
          // _buildProfilSection > Bloc Compte ANAH.
        ],
      ),
    );
  }

  /// `compte_anah` stockait historiquement un simple statut texte
  /// ("A faire", "A vérifier", "Déjà fait", "Mandat"). Depuis 2026-05-04,
  /// la fiche bénéficiaire demande 3 sous-questions distinctes (statut
  /// du compte + création mail + création mandat avec sous-question
  /// « par qui »). Pour éviter une migration de schéma NocoDB, on stocke
  /// l'objet en JSON dans la même colonne `compte_anah`.
  ///
  /// Format JSON :
  /// ```json
  /// {
  ///   "status":      "A faire" | "A vérifier" | "Déjà fait" | "",
  ///   "mail":        "Oui" | "Non" | "",
  ///   "mandat":      "Oui" | "Non" | "",
  ///   "mandatPar":   "Aid'habitat" | "Autre" | "",
  ///   "mandatAutre": "<texte libre quand mandatPar=Autre>"
  /// }
  /// ```
  ///
  /// Rétrocompat : si la valeur stockée est une chaîne brute (cas
  /// historique), on la traite comme `{status: <chaîne>}`. La valeur
  /// historique « Mandat » est migrée vers `{mandat: "Oui"}` (le statut
  /// reste vide, à recompléter par l'ergo).
  Map<String, String> _parseAnahData(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, String>{};
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      } catch (_) {/* fall through au plain string */}
    }
    // Plain string legacy
    if (trimmed == 'Mandat') {
      return <String, String>{'status': '', 'mandat': 'Oui'};
    }
    return <String, String>{'status': trimmed};
  }

  String _serializeAnahData(Map<String, String> data) {
    // On ne stocke que les clés non-vides — JSON plus compact, et
    // évite les PATCH inutiles sur NocoDB.
    final clean = <String, String>{};
    for (final entry in data.entries) {
      if (entry.value.trim().isNotEmpty) clean[entry.key] = entry.value;
    }
    if (clean.isEmpty) return '';
    return jsonEncode(clean);
  }

  /// `envoi_rapport` est désormais multi-valeur : on stocke les choix
  /// de l'ergo en CSV ("Mail", "Courrier", "Mail, Courrier") dans la
  /// colonne texte côté NocoDB. Ces helpers normalisent les
  /// allers-retours entre la chaîne stockée et le `Set<String>` utilisé
  /// par `FormMultiToggleGroup`. Tolère les anciens dossiers où la
  /// valeur était une chaîne simple ("Mail" / "Courrier") — pas de
  /// migration nécessaire.
  Set<String> _parseEnvoiRapport(String raw) {
    if (raw.trim().isEmpty) return <String>{};
    return raw
        .split(RegExp(r'[,;]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  String _serializeEnvoiRapport(Set<String> values) {
    if (values.isEmpty) return '';
    // Ordre stable Mail puis Courrier pour une chaîne déterministe au save
    // (évite des PATCH inutiles sur NocoDB et garde la lecture cohérente
    // côté serveur / PDF).
    const order = ['Mail', 'Courrier'];
    final sorted = order.where(values.contains).toList();
    // Si l'ergo a entré une valeur custom (cas legacy), on l'append.
    for (final v in values) {
      if (!order.contains(v)) sorted.add(v);
    }
    return sorted.join(', ');
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

  /// Ouvre le picker visuel pour la caisse de retraite PRINCIPALE.
  /// Source : table NocoDB `caisses_de_retraite` (champ `logoUrl` +
  /// `phone` disponibles ; pas d'`audience` / `aidAmount` côté
  /// principal, donc la card affiche logo + nom + téléphone).
  Future<String?> _openPrincipalFundPicker(String currentValue) async {
    final items = _principalFunds
        .map((f) => _RetirementFundPickerItem(
              name: f['name'] ?? '',
              logoUrl: f['logoUrl'] ?? '',
              subtitle: (f['phone'] ?? '').trim(),
            ))
        .where((it) => it.name.isNotEmpty)
        .toList();
    return _showRetirementFundPicker(
      title: 'Caisse de retraite principale',
      items: items,
      initialSelected: currentValue,
    );
  }

  /// Ouvre le picker visuel pour la caisse de retraite COMPLÉMENTAIRE.
  /// Source : table NocoDB `caisses_de_retraite_complementaires` —
  /// le modèle `RetirementFund` a `audience` + `aidAmount` qu'on
  /// concatène en ligne courte (Option 1B utilisateur 2026-05-12).
  Future<String?> _openComplementaryFundPicker(String currentValue) async {
    final items = _retirementFunds
        .map((f) => _RetirementFundPickerItem(
              name: f.name,
              logoUrl: f.logoUrl,
              subtitle: _buildSubtitleForFund(f),
            ))
        .where((it) => it.name.isNotEmpty)
        .toList();
    return _showRetirementFundPicker(
      title: 'Caisse de retraite complémentaire',
      items: items,
      initialSelected: currentValue,
    );
  }

  /// Concatène `audience` + `aidAmount` en une ligne courte affichée
  /// sous le titre dans chaque card. Sépare par " · " si les deux
  /// champs sont renseignés, sinon affiche celui qui existe.
  String _buildSubtitleForFund(RetirementFund f) {
    final aud = f.audience.trim();
    final amount = f.aidAmount.trim();
    if (aud.isNotEmpty && amount.isNotEmpty) {
      return '$aud · $amount';
    }
    return aud.isNotEmpty ? aud : amount;
  }

  /// Ouvre le dialog picker. Renvoie `null` si l'utilisateur ferme
  /// sans choisir. Renvoie le nom (existant OU saisi librement) sinon.
  Future<String?> _showRetirementFundPicker({
    required String title,
    required List<_RetirementFundPickerItem> items,
    required String initialSelected,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _RetirementFundPickerDialog(
        title: title,
        items: items,
        initialSelected: initialSelected,
      ),
    );
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
              // Refonte 2026-05-13 : Nunito w700 sur les titres dialog.
              style: GoogleFonts.nunito(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
                color: const Color(0xFF0E1116),
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
                              final selectedValue = values[i];
                              setLocal(() {
                                pending = selectedValue;
                                closing = true;
                              });
                              // Laisse l'animation jouer avant de fermer.
                              Future.delayed(
                                const Duration(milliseconds: 220),
                                () {
                                  if (!dialogCtx.mounted) return;
                                  if (Navigator.of(dialogCtx).canPop()) {
                                    Navigator.pop(dialogCtx, selectedValue);
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
                              ? const Color(0xFF0E1116)
                              : const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          // Merge sur le style ambiant pour préserver
                          // la fontFamily Quicksand (sinon retombe sur
                          // Roboto — interdit, demande utilisateur
                          // 2026-05-13).
                          //
                          // `decoration: TextDecoration.none` forcé pour
                          // bloquer la fuite d'underline jaune fluo qui
                          // apparaît parfois en contexte de dialog
                          // (bug 2026-05-15 : `copyWith` ne reset pas
                          // `decoration`/`decorationColor`, donc un style
                          // ambiant avec underline polluait les cellules).
                          style: DefaultTextStyle.of(ctx).style.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFF0E1116),
                                decoration: TextDecoration.none,
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
                    color: Color(0xFF5C6670),
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
          // Refonte 2026-05-13 : Nunito w700.
          style: GoogleFonts.nunito(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.25,
            color: const Color(0xFF0E1116),
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
                              color: Color(0xFF5C6670),
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
                              ? const Color(0xFF0E1116)
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
                                : const Color(0xFF0E1116),
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
                color: Color(0xFF5C6670),
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
          // Refonte 2026-05-13 — aligné sur FormTextField (vp-label) :
          // w700 14px ink-900 (noir). Demande utilisateur 2026-05-13 :
          // « uniformise absolument tout les titres de champs avec
          // police noir à la même taille que téléphone ».
          const Text(
            'Date de naissance',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0xFF0E1116),
            ),
          ),
          const SizedBox(height: 5),
        ],
        // Refonte 2026-05-13 — aligné sur FormTextField (vp-input) :
        // border-radius pill (999), padding h:14 v:8, fontSize 14.
        InkWell(
          onTap: () => _pickDate(context),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Color(0xFFB9C0C7)),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    display.isEmpty ? 'JJ / MM / AAAA' : display,
                    style: TextStyle(
                      fontSize: 14,
                      color: display.isEmpty
                          ? const Color(0xFF8A939D)
                          : const Color(0xFF2B323A),
                    ),
                  ),
                ),
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 16,
                  color: Color(0xFF5C6670),
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
            // Cercle de check 20×20 animé (refonte 2026-05-13, vp-dot-fill).
            VpCheckboxDot(completed: checked, size: 20),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF2B323A),
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

// =============================================================================
// Caisses de retraite — picker visuel (cards 3 par 3) façon préconisations.
// Demande utilisateur 2026-05-12.
// =============================================================================

/// Item simplifié alimentant le picker. Issu soit d'un `RetirementFund`
/// (complémentaire — table `caisses_de_retraite_complementaires`) soit
/// d'une `Map<String,String>` (principale — table `caisses_de_retraite`).
class _RetirementFundPickerItem {
  final String name;
  final String logoUrl;
  final String subtitle;
  const _RetirementFundPickerItem({
    required this.name,
    required this.logoUrl,
    required this.subtitle,
  });
}

/// Bouton d'ouverture du picker. Style cohérent avec `FormSelectDropdown`
/// (label flottant en haut, valeur en gros dessous, hint si vide) pour
/// que l'ergo ne ressente pas un changement d'UI brutal — c'est juste
/// le comportement du tap qui change (popup au lieu de dropdown natif).
class _RetirementFundFieldButton extends StatelessWidget {
  final String label;
  final String value;
  final String placeholder;
  final VoidCallback onTap;
  const _RetirementFundFieldButton({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 5, left: 0),
          child: Text(
            label,
            // Uniformisé 2026-05-13 : w700 14px ink-900 noir, aligné
            // sur les autres labels de champ (Téléphone, etc.).
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0E1116),
            ),
          ),
        ),
        Material(
          color: Colors.white,
          // Refonte 2026-05-13 : pill radius 999 uniforme.
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            // Refonte 2026-05-13 : pill radius 999 uniforme.
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Container(
              // Taille de texte alignée sur Occupation (FormToggleGroup
              // pill : fontSize 14, height 32, padding h:14). Demande
              // utilisateur 2026-05-13 : « la taille de texte de ces
              // deux parties de boutons doit être la même que celle
              // d'Occupation ». On garde le pill radius 999 et on
              // ajuste le padding vertical (7) pour reproduire la
              // hauteur ~32 px du pill Occupation.
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFE4E7EB)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      hasValue ? value : placeholder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // 12 → 14 : aligné sur la fontSize des pills
                        // Occupation (FormToggleGroup).
                        fontSize: 14,
                        fontWeight:
                            hasValue ? FontWeight.w600 : FontWeight.w400,
                        color: hasValue
                            ? const Color(0xFF1E293B)
                            : const Color(0xFF8A939D),
                      ),
                    ),
                  ),
                  const Icon(
                    LucideIcons.chevronDown,
                    // 16 → 18 : ré-augmenté pour rester proportionnel
                    // à la fontSize 14 du texte (alignement Occupation).
                    size: 18,
                    color: Color(0xFF8A939D),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog modal qui présente les caisses de retraite en grille 3-cols.
/// Recherche par nom (uniquement, demande utilisateur). Tap sur une
/// card → renvoie le nom de la caisse sélectionnée. En bas, un champ
/// de saisie libre permet d'ajouter un nom non listé.
class _RetirementFundPickerDialog extends StatefulWidget {
  final String title;
  final List<_RetirementFundPickerItem> items;
  final String initialSelected;
  const _RetirementFundPickerDialog({
    required this.title,
    required this.items,
    required this.initialSelected,
  });

  @override
  State<_RetirementFundPickerDialog> createState() =>
      _RetirementFundPickerDialogState();
}

class _RetirementFundPickerDialogState
    extends State<_RetirementFundPickerDialog> {
  String _search = '';
  late TextEditingController _freeInputController;

  @override
  void initState() {
    super.initState();
    // Hydrate le champ de saisie libre avec la valeur courante UNIQUEMENT
    // si elle n'existe pas dans la liste — sinon le user voit son choix
    // existant en saisie libre, ce qui est confusant. La règle : si on
    // peut retrouver le nom dans la liste, c'est un choix "card", pas
    // un free-text.
    final initial = widget.initialSelected.trim();
    final inList = widget.items.any((it) => it.name == initial);
    _freeInputController =
        TextEditingController(text: inList ? '' : initial);
  }

  @override
  void dispose() {
    _freeInputController.dispose();
    super.dispose();
  }

  List<_RetirementFundPickerItem> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    // Recherche UNIQUEMENT par nom — demande utilisateur 2026-05-12.
    return widget.items
        .where((it) => it.name.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 800,
        height: 600,
        child: Column(
          children: [
            // Header + barre de recherche : conteneur opaque pour
            // masquer le scroll grid en dessous (parité visuelle avec
            // le picker des préconisations).
            Material(
              color: Colors.white,
              elevation: 1,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            // Refonte 2026-05-13 : Nunito w700.
                            style: GoogleFonts.nunito(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.25,
                              color: const Color(0xFF2B323A),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Rechercher une caisse par nom',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: kBrandPurple, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                ],
              ),
            ),
            // Grid de cards 3-cols
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'Aucune caisse trouvée.',
                        style: TextStyle(color: Color(0xFF8A939D)),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.85,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, i) =>
                          _buildTile(filtered[i]),
                    ),
            ),
            // Champ "caisse non listée" — demande utilisateur 2026-05-12
            // (option 4C). Valider via le bouton "Utiliser" → renvoie
            // ce texte comme name choisi. Permet à l'ergo de saisir
            // librement un nom de caisse qui n'est pas encore dans
            // NocoDB (sera ajouté plus tard via l'écran admin).
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              decoration: const BoxDecoration(
                color: Color(0xFFFAFBFC),
                border: Border(
                  top: BorderSide(color: Color(0xFFE4E7EB)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _freeInputController,
                      decoration: InputDecoration(
                        hintText: 'Ou saisir une caisse non listée…',
                        prefixIcon:
                            const Icon(LucideIcons.edit3, size: 18),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFFE4E7EB)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFFE4E7EB)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: kBrandPurple, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (v) {
                        final t = v.trim();
                        if (t.isNotEmpty) Navigator.pop(context, t);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kBrandPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () {
                      final t = _freeInputController.text.trim();
                      if (t.isNotEmpty) Navigator.pop(context, t);
                    },
                    child: const Text(
                      'Utiliser',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(_RetirementFundPickerItem it) {
    final isSelected = it.name == widget.initialSelected.trim();
    return InkWell(
      onTap: () => Navigator.pop(context, it.name),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? kBrandPurple
                : const Color(0xFFE4E7EB),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Logo en haut — soit l'image distante (CachedRemoteImage),
            // soit un avatar avec les initiales si pas de logoUrl
            // (demande utilisateur option 5).
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFFAFAFC),
                child: it.logoUrl.trim().isNotEmpty
                    ? CachedRemoteImage(
                        key: ValueKey(it.logoUrl),
                        url: it.logoUrl,
                        fit: BoxFit.contain,
                        placeholder: _FundInitialsAvatar(name: it.name),
                        errorWidget: _FundInitialsAvatar(name: it.name),
                      )
                    : _FundInitialsAvatar(name: it.name),
              ),
            ),
            // Titre + sous-titre
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  if (it.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      it.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF5C6670),
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Avatar circulaire avec les initiales du nom de la caisse — utilisé
/// quand `logoUrl` est vide ou en cas d'erreur de chargement.
/// Couleurs neutres (mauve clair, palette identifiée 2026-05).
class _FundInitialsAvatar extends StatelessWidget {
  final String name;
  const _FundInitialsAvatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
            ? parts.first.substring(0, 1).toUpperCase()
            : '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFFEEE7F2),
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF554265),
          ),
        ),
      ),
    );
  }
}

// `_AnahStatusToggle` retiré 2026-05-13 — la maquette utilise des pills
// mauves normales (FormToggleGroup) pour le formulaire « Création
// compte ANAH ». Les couleurs sémantiques `.vp-anah` (todo/check/done)
// sont uniquement pour le badge status du header du relevé, implémenté
// dans `VisitReportScreen` (cf. `_AnahStatusBadge`).
