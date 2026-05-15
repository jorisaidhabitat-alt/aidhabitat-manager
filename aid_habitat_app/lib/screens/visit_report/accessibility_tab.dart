import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../components/brand_colors.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';

/// Accessibilité tab — refonte :
///   Général : type logement · années · surface · chauffage · niveaux
///             (ajout dynamique) · volets (dropdowns)
///   Extérieur : accès rue · annexes + motorisations conditionnelles
class AccessibilityTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;
  final VoidCallback? onHousingChanged;

  /// Sous-section affichée à l'ouverture du tab. Permet à
  /// `visit_report_screen.dart > _navigateToMissingField` de pointer
  /// directement sur la sous-section qui contient le champ vide
  /// (ex. "Niveaux" pour un manque de logement). Si null, on garde
  /// la sous-section précédemment affichée OU 0 (Général) au 1er
  /// chargement.
  final int? initialSubSection;

  /// Callback notifié à chaque tap d'onglet interne — visit_report_screen
  /// l'utilise pour mettre à jour son cache `_activeSubsectionByTab`
  /// (sync avec d'autres surfaces, ex. panneau notes latéral).
  final ValueChanged<int>? onSubSectionChanged;

  const AccessibilityTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onHousingChanged,
    this.initialSubSection,
    this.onSubSectionChanged,
  });

  @override
  State<AccessibilityTab> createState() => _AccessibilityTabState();
}

// ---------------------------------------------------------------------------
// Level config
// ---------------------------------------------------------------------------

class _LevelConfig {
  final String field;
  final String roomsField;
  final String label;
  final List<String> presetRooms;
  const _LevelConfig({
    required this.field,
    required this.roomsField,
    required this.label,
    required this.presetRooms,
  });
}

const List<_LevelConfig> _kLevelConfigs = [
  _LevelConfig(
    field: 'basement',
    roomsField: 'basement_rooms_json',
    label: 'Sous-sol',
    presetRooms: ['Salle de bain', 'WC', 'Garage', 'Buanderie'],
  ),
  _LevelConfig(
    field: 'rdc',
    roomsField: 'rdc_rooms_json',
    label: 'RDC',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'floor',
    roomsField: 'floor_rooms_json',
    label: '1er étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'second_floor',
    roomsField: 'second_floor_rooms_json',
    label: '2e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'third_floor',
    roomsField: 'third_floor_rooms_json',
    label: '3e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class _AccessibilityTabState extends State<AccessibilityTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// Index de la sous-section active :
  ///   0 = Général             (type, années, surface)
  ///   1 = Niveaux et pièces   (ajout des niveaux + cartes pièces) ← demande
  ///                            utilisateur 2026-04-29 : sortir cette logique
  ///                            de Général pour avoir une page dédiée.
  ///   2 = Équipements         (chauffage + volets)
  ///   3 = Extérieur           (accès rue + annexes/motorisations)
  int _subSection = 0;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  /// ScrollController du formulaire — préserve la position de scroll
  /// entre les rebuilds de la sous-section Général.
  final ScrollController _scrollController = ScrollController();

  // Niveaux : field actuellement "ouvert" (carte pleine). Les autres
  // niveaux sont repliés en "Nom (pièces cochées)" + crayon. Null quand
  // aucun niveau n'est en cours d'édition. C'est le SEUL repli préservé
  // dans l'onglet Accessibilité (sur demande utilisateur) : les autres
  // champs (type de logement, surface, chauffage, volets, annexes…)
  // restent toujours visibles sous forme de pills/dropdown.
  String? _expandedLevel;
  // Affichage de la liste pills pour ajouter un nouveau niveau.
  bool _addLevelMode = false;
  // Niveau actuellement édité À L'INTÉRIEUR du container "Ajouter un
  // niveau" (= morphing container). Quand non null, le container
  // affiche l'éditeur du niveau au lieu du bouton ou du picker. Le
  // niveau est aussi présent dans `_orderedLevels` mais on le SKIP
  // dans la liste principale tant qu'il est dans le container, pour
  // éviter de le rendre deux fois.
  String? _pendingLevelField;

  // Général
  String _yearConstruction = '';
  String _yearHabitation = '';
  double? _surface;
  // '' = jamais répondu (aucun pill highlight UI). L'ergo doit cliquer
  // explicitement Maison ou Appartement pour passer la validation
  // pré-génération (cf. _checkAccessibilite > Général).
  String _typology = '';
  Set<String> _heatingTypes = {};

  // Niveaux (ordre d'ajout par l'utilisateur)
  List<String> _orderedLevels = [];
  final Map<String, List<String>> _levelRooms = {};
  final Map<String, TextEditingController> _customRoomCtrls = {};

  // Volets : '' | 'Aucun' | 'Entier' | 'Localisé'.
  // '' = jamais répondu (aucun pill highlight UI). L'ergo doit cliquer
  // explicitement Aucun/Entier/Localisé pour passer la validation
  // pré-génération (cf. _checkAccessibilite > checkVolets).
  String _voletsManStatus = '';
  String _voletsManLoc = '';
  String _voletsElecStatus = '';
  String _voletsElecLoc = '';
  String _voletsPersStatus = '';
  String _voletsPersLoc = '';

  // Extérieur — `_easyAccess` nullable pour permettre l'état « non
  // renseigné » (UI sans pré-sélection). Demande utilisateur
  // 2026-04-30. true=Facile, false=À revoir, null=non renseigné.
  bool? _easyAccess;
  final Set<String> _annexes = {};
  bool _portail = false;
  String _motorisationPorteGarage = 'Aucun';
  String _motorisationPortail = 'Aucun';

  /// Ordre dans lequel les motorisations ont été sélectionnées dans la
  /// session courante. Permet d'afficher la motorisation choisie en
  /// premier en haut, la deuxième en dessous (demande utilisateur
  /// 2026-04-28). Valeurs possibles : 'Garage' et/ou 'Portail'. Pas
  /// persisté — au reload, ordre par défaut alphabétique
  /// ['Garage', 'Portail'].
  final List<String> _motorisationOrder = [];

  static const _heatingOptions = [
    'Électrique',
    'Gaz',
    'Fioul',
    'PAC',
    'Bois',
    'Granulés',
    'Collectif',
    'Autre',
  ];

  static const _annexeOptions = [
    'Garage',
    'Véranda',
    'Balcon',
    'Terrasse',
    'Jardin',
  ];

  static const _voletStatuses = ['Aucun', 'Entier', 'Localisé'];
  static const _motorisationOptions = ['Aucun', 'Manuel', 'Électrique'];

  /// Marqueur invisible (zero-width space) stocké dans la colonne
  /// `volets_*_localisation` quand l'ergo a sélectionné "Localisé"
  /// sans préciser la localisation. Permet de distinguer
  /// "Aucun volet" (loc="") de "Localisé mais pas encore renseigné"
  /// (loc="​") qui s'inféreraient sinon tous les deux comme
  /// "Aucun" au reload — bug reporté 2026-04-28.
  ///
  /// Aucun risque de collision : zero-width space n'est pas saisissable
  /// au clavier et invisible dans NocoDB UI / le rapport PDF.
  /// ZWSP (U+200B) — marque « Localisé sans texte ». Persiste dans
  /// `volets_*_localisation` pour distinguer ce cas d'un champ vide.
  static const String _kVoletsLocalizedMarker = '​';

  /// ZWNJ (U+200C) — marque « Aucun explicite » (l'ergo a cliqué Aucun).
  /// Persiste dans `volets_*_localisation` pour distinguer ce cas du
  /// statut « non renseigné » (loc='', entier=false). Sans ce marqueur,
  /// le validateur de pré-génération ne pouvait pas dire si l'ergo
  /// avait répondu « Aucun » ou pas répondu du tout — il flagait à tort
  /// les volets « Aucun » comme manquants.
  static const String _kVoletsAucunMarker = '‌';

  /// Infère le statut volets ('' / 'Aucun' / 'Entier' / 'Localisé') depuis
  /// les 2 champs persistés (`entier`, `localisation`).
  ///
  ///   '' (vide)              → non renseigné (pas de pill)
  ///   '‌' (ZWNJ)        → Aucun explicite
  ///   '​' (ZWSP)        → Localisé sans texte
  ///   '​' + texte / autre → Localisé avec texte
  ///   entier=true            → Entier (loc ignorée)
  static String _inferVoletsStatus(bool entier, String rawLoc) {
    if (entier) return 'Entier';
    if (rawLoc == _kVoletsAucunMarker) return 'Aucun';
    if (rawLoc.isNotEmpty) return 'Localisé';
    return '';
  }

  /// Nettoie la localisation pour l'affichage : retire les marqueurs
  /// invisibles (ZWSP « Localisé sans texte » et ZWNJ « Aucun »).
  /// L'ergo doit voir un champ vide, pas un caractère bizarre.
  static String _cleanVoletsLoc(String rawLoc) {
    if (rawLoc == _kVoletsLocalizedMarker) return '';
    if (rawLoc == _kVoletsAucunMarker) return '';
    return rawLoc;
  }

  /// Sérialise la localisation pour la save :
  ///   - status='Aucun'    → ZWNJ (marqueur invisible)
  ///   - status='Entier'   → '' (loc inutile, le bool entier=1 suffit)
  ///   - status='Localisé' + texte vide → ZWSP (préserve « Localisé sans
  ///     précision »)
  ///   - status='Localisé' + texte → texte tel quel
  ///   - status='' (non renseigné) → ''
  static String _serializeVoletsLoc(String status, String loc) {
    if (status == 'Aucun') return _kVoletsAucunMarker;
    if (status != 'Localisé') return '';
    if (loc.isEmpty) return _kVoletsLocalizedMarker;
    return loc;
  }

  /// Formate la liste des pièces d'un niveau en groupant les doublons
  /// avec un exposant Unicode (² / ³ / ⁴) — ex.
  /// `['SDB', 'WC', 'SDB']` → `'SDB ², WC'`. Préserve l'ordre
  /// d'apparition de chaque pièce unique. Le max actuel est 4 (cf.
  /// `_buildLevelCard` qui clamp le compteur à 4 — demande utilisateur
  /// 2026-05-04 : jusqu'à 4 chambres / niveau).
  static String _formatRoomsWithCounts(List<String> rooms) {
    final counts = <String, int>{};
    final order = <String>[];
    for (final r in rooms) {
      if (!counts.containsKey(r)) order.add(r);
      counts[r] = (counts[r] ?? 0) + 1;
    }
    return order.map((r) {
      final n = counts[r]!;
      if (n <= 1) return r;
      final suffix = n == 2 ? '²' : (n == 3 ? '³' : (n == 4 ? '⁴' : '$n'));
      return '$r $suffix';
    }).join(', ');
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // Honore la sous-section initiale demandée par le parent (utile
    // pour que « Remplir les champs » dans la popup de validation
    // pointe directement sur la bonne sous-section, pas seulement
    // sur l'onglet — bug rapporté 2026-05-04).
    final initial = widget.initialSubSection;
    if (initial != null && initial >= 0 && initial < 4) {
      _subSection = initial;
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant AccessibilityTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Quand le parent change `initialSubSection` (programmatic nav
    // depuis _navigateToMissingField), on bascule la sous-section
    // courante. Filtre par `oldWidget.initialSubSection !=
    // widget.initialSubSection` pour ne pas écraser le tap manuel
    // de l'utilisateur lors d'un rebuild banal du parent.
    final next = widget.initialSubSection;
    if (next != null &&
        next != oldWidget.initialSubSection &&
        next >= 0 &&
        next < 4 &&
        next != _subSection) {
      setState(() => _subSection = next);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scrollController.dispose();
    for (final c in _customRoomCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    final row = await widget.repository.fetchHousingRaw(widget.dossier.id);
    final h = widget.dossier.housing;

    _yearConstruction =
        (row?['year_construction'] ?? h.yearConstruction) as String? ?? '';
    _yearHabitation =
        (row?['year_habitation'] ?? h.yearHabitation) as String? ?? '';
    _surface = (row?['surface'] as num?)?.toDouble() ?? h.surface;
    // Demande utilisateur 2026-04-30 : pas de pré-sélection 'Maison'
    // par défaut — l'ergo doit cliquer explicitement Maison ou
    // Appartement, sinon le validateur le flag comme manquant.
    _typology = (row?['typology'] as String?) ??
        (h.typology.isNotEmpty ? h.typology : '');

    // Niveaux
    for (final cfg in _kLevelConfigs) {
      _levelRooms[cfg.field] =
          _parseRooms(row?[cfg.roomsField] as String? ?? '[]');
      _customRoomCtrls[cfg.field] = TextEditingController();
    }
    _orderedLevels = _kLevelConfigs
        .where((c) => (row?[c.field] as int? ?? 0) == 1)
        .map((c) => c.field)
        .toList();

    // Chauffage (rétrocompat : données antérieures stockées comme
    // "Pompe à chaleur" → remplacées par la version compacte "PAC").
    _heatingTypes =
        _parseHeatingJson(row?['heating_details_json'] as String? ?? '{}');
    if (_heatingTypes.contains('Pompe à chaleur')) {
      _heatingTypes.remove('Pompe à chaleur');
      _heatingTypes.add('PAC');
    }

    // Volets — le statut ('Aucun' / 'Entier' / 'Localisé') est inféré
    // depuis les colonnes persistées via `_inferVoletsStatus`. Le
    // marqueur invisible `_kVoletsLocalizedMarker` permet de préserver
    // un état "Localisé sans texte" (sinon ça repasserait à "Aucun").
    final manEntier =
        ((row?['volets_roulants_manuels_entier'] as int?) ??
                (h.voletsRoulantsManuelsEntier ? 1 : 0)) ==
            1;
    final manRawLoc =
        (row?['volets_roulants_manuels_localisation'] as String?) ??
            h.voletsRoulantsManuelsLocalisation;
    _voletsManStatus = _inferVoletsStatus(manEntier, manRawLoc);
    _voletsManLoc = _cleanVoletsLoc(manRawLoc);

    final elecEntier =
        ((row?['volets_roulants_electriques_entier'] as int?) ??
                (h.voletsRoulantsElectriquesEntier ? 1 : 0)) ==
            1;
    final elecRawLoc =
        (row?['volets_roulants_electriques_localisation'] as String?) ??
            h.voletsRoulantsElectriquesLocalisation;
    _voletsElecStatus = _inferVoletsStatus(elecEntier, elecRawLoc);
    _voletsElecLoc = _cleanVoletsLoc(elecRawLoc);

    final persEntier =
        ((row?['volets_persiennes_entier'] as int?) ??
                (h.voletsPersiennesEntier ? 1 : 0)) ==
            1;
    final persRawLoc =
        (row?['volets_persiennes_localisation'] as String?) ??
            h.voletsPersiennesLocalisation;
    _voletsPersStatus = _inferVoletsStatus(persEntier, persRawLoc);
    _voletsPersLoc = _cleanVoletsLoc(persRawLoc);

    // Extérieur — `easy_access_set` (migration v15→v16) tracke si
    // l'ergo a explicitement cliqué Facile/À revoir. Sans ce flag, le
    // défaut SQLite `easy_access=0 NOT NULL` faisait apparaître la pill
    // « À revoir » comme pré-sélectionnée à la première ouverture du
    // dossier — le validateur de pré-génération ne pouvait pas signaler
    // le champ comme manquant.
    //   set=0 → _easyAccess=null (aucune pill highlight)
    //   set=1 + easy_access=1 → _easyAccess=true (Facile)
    //   set=1 + easy_access=0 → _easyAccess=false (À revoir)
    final easyAccessSet = (row?['easy_access_set'] as int? ?? 0) == 1;
    if (easyAccessSet) {
      _easyAccess = (row?['easy_access'] as int? ?? 0) == 1;
    } else {
      _easyAccess = null;
    }
    _annexes.clear();
    if ((row?['garage'] as int? ?? 0) == 1) _annexes.add('Garage');
    if ((row?['veranda'] as int? ?? 0) == 1) _annexes.add('Véranda');
    if ((row?['balcon'] as int? ?? 0) == 1) _annexes.add('Balcon');
    if ((row?['terrasse'] as int? ?? 0) == 1) _annexes.add('Terrasse');
    if ((row?['jardin'] as int? ?? 0) == 1) _annexes.add('Jardin');
    // Sync Garage depuis les pièces des niveaux : si "Garage" est coché
    // dans n'importe quel niveau, l'annexe Garage est automatiquement activée.
    if (_levelRooms.values.any((rooms) => rooms.contains('Garage'))) {
      _annexes.add('Garage');
    }

    final rawGarage =
        (row?['motorisation_porte_garage'] as String?) ?? h.motorisationPorteGarage;
    _motorisationPorteGarage = rawGarage.isEmpty ? 'Aucun' : rawGarage;

    final rawPortail =
        (row?['motorisation_portail'] as String?) ?? h.motorisationPortail;
    _portail = rawPortail.isNotEmpty;
    _motorisationPortail = rawPortail.isEmpty ? 'Aucun' : rawPortail;

    // Ordre par défaut au reload : Garage en premier s'il est présent,
    // Portail en deuxième. La session courante peut ré-ordonner via
    // la séquence de toggle (cf. `_buildMultiSelectGrid` callback).
    _motorisationOrder.clear();
    if (_annexes.contains('Garage')) _motorisationOrder.add('Garage');
    if (_portail) _motorisationOrder.add('Portail');

    if (mounted) setState(() => _loaded = true);
  }

  List<String> _parseRooms(String raw) {
    if (raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  Set<String> _parseHeatingJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.entries
            .where((e) => e.value == true)
            .map((e) => e.key.toString())
            .toSet();
      }
    } catch (_) {}
    return {};
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(kSaveDebouncePills, _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    // Pas de setState(_saving) — voir dossier_screen.dart pour le
    // rationale (rebuild lourd inutile, indicateur visuel toujours vide).
    final heatingJson = <String, bool>{
      for (final opt in _heatingOptions) opt: _heatingTypes.contains(opt),
    };

    final map = <String, dynamic>{
      'year_construction': _yearConstruction,
      'year_habitation': _yearHabitation,
      'surface': _surface,
      'levels': _orderedLevels.length,
      'typology': _typology,
      'heating_details_json': jsonEncode(heatingJson),
      // Volets — `_serializeVoletsLoc` gère le marqueur invisible
      // pour préserver l'état "Localisé sans texte" au reload.
      'volets_roulants_manuels_entier': _voletsManStatus == 'Entier' ? 1 : 0,
      'volets_roulants_manuels_localisation':
          _serializeVoletsLoc(_voletsManStatus, _voletsManLoc),
      'volets_roulants_electriques_entier':
          _voletsElecStatus == 'Entier' ? 1 : 0,
      'volets_roulants_electriques_localisation':
          _serializeVoletsLoc(_voletsElecStatus, _voletsElecLoc),
      'volets_persiennes_entier': _voletsPersStatus == 'Entier' ? 1 : 0,
      'volets_persiennes_localisation':
          _serializeVoletsLoc(_voletsPersStatus, _voletsPersLoc),
      // Extérieur
      // `_easyAccess` peut être null (= non renseigné). On ne peut PAS
      // écrire null dans `easy_access` (NOT NULL) — on utilise plutôt
      // `easy_access_set` (migration v15→v16) pour tracer la réponse
      // explicite. Si jamais répondu : easy_access=0 + easy_access_set=0
      // (load le restituera comme null, sans pill highlight).
      'easy_access': _easyAccess == true ? 1 : 0,
      'easy_access_set': _easyAccess == null ? 0 : 1,
      // Champs supprimés de l'UI — on les vide pour effacer les données obsolètes
      'access_observation': '',
      'cheminement_plat': 0,
      'cheminement_pente_douce': 0,
      'cheminement_quelques_marches': 0,
      'cheminement_escalier_exterieur': 0,
      'cheminement_escalier_interieur': 0,
      'cheminement_seuil_porte': 0,
      'cheminement_par_arriere': 0,
      // Annexes
      'garage': _annexes.contains('Garage') ? 1 : 0,
      'veranda': _annexes.contains('Véranda') ? 1 : 0,
      'balcon': _annexes.contains('Balcon') ? 1 : 0,
      'terrasse': _annexes.contains('Terrasse') ? 1 : 0,
      'jardin': _annexes.contains('Jardin') ? 1 : 0,
      'motorisation_porte_garage': _annexes.contains('Garage')
          ? (_motorisationPorteGarage == 'Aucun'
              ? ''
              : _motorisationPorteGarage)
          : '',
      'motorisation_portail': _portail
          ? (_motorisationPortail == 'Aucun' ? 'Aucun' : _motorisationPortail)
          : '',
    };

    for (final cfg in _kLevelConfigs) {
      map[cfg.field] = _orderedLevels.contains(cfg.field) ? 1 : 0;
      map[cfg.roomsField] = jsonEncode(_levelRooms[cfg.field] ?? []);
      // Auto-remplit la description du niveau avec la liste des pièces
      // séparées par des virgules (avec exposants ² ³ pour les
      // doublons). Cf. `_formatRoomsWithCounts`. Alimente les champs
      // `Sous sol` / `rdc` / `etage` page 5 du PDF — demande
      // utilisateur 2026-04-29 : « après les deux petits points
      // marqué les pièces concernées (ici salle de bain et wc) à la
      // ligne séparée par une virgule ».
      //
      // Note : seuls basement / rdc / floor ont une colonne NocoDB
      // dédiée (description_sous_sol, description_rdc, description_etage).
      // Pour second_floor / third_floor on stocke quand même côté local
      // (au cas où une colonne serait ajoutée plus tard).
      map['${cfg.field}_desc'] =
          _formatRoomsWithCounts(_levelRooms[cfg.field] ?? []);
    }

    await widget.repository.updateHousing(widget.dossier.id, map);
    widget.onHousingChanged?.call();
  }

  void _markChanged() {
    setState(() {});
    _scheduleSave();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Bandeau sous-menu full-width en haut de la card — parité
        // avec l'onglet Bénéficiaire.
        _buildQuickNav(),
        Expanded(
          // Swipe SECTIONS désactivé (demande utilisateur 2026-04-29) :
          // bascule entre Général / Niveaux / Équipements / Extérieur
          // uniquement via le QuickNav (tap). Pas d'occupants dans cet
          // onglet → plus aucun swipe horizontal câblé ici.
          child: SoftSwitcher(
              // Légère animation entre les 4 sous-sections — fade +
              // apparition vers le haut, mêmes sensations qu'un
              // changement de vue principale (sidebar).
              child: KeyedSubtree(
                key: ValueKey<int>(_subSection),
                child: SingleChildScrollView(
                  // Le controller n'est utile qu'en sous-section
                  // « Niveaux et pièces » (auto-scroll après ajout d'un
                  // niveau). On le branche uniquement là — pas d'effet
                  // de bord sur les autres sections.
                  controller:
                      _subSection == 1 ? _scrollController : null,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_subSection == 0)
                        _buildGeneral()
                      else if (_subSection == 1)
                        _buildLevelsAndRooms()
                      else if (_subSection == 2)
                        _buildEquipements()
                      else
                        _buildExterior(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
  }

  // ---------------------------------------------------------------------------
  // Quick nav (Général / Niveaux et pièces / Équipements / Extérieur)
  // ---------------------------------------------------------------------------

  Widget _buildQuickNav() {
    const items = [
      // Refonte 2026-05-13 (maquette user) : Material outlined → Lucide
      // (stroke fin, moins « bold »).
      _QuickNavItem(icon: LucideIcons.home, label: 'Général'),
      _QuickNavItem(icon: LucideIcons.layers, label: 'Niveaux'),
      // Demande user 2026-05-13 : icon « 3 lignes les unes en dessous
      // des autres » → menu (hamburger Lucide, 3 traits horizontaux).
      _QuickNavItem(icon: LucideIcons.menu, label: 'Équipements'),
      _QuickNavItem(icon: LucideIcons.mapPin, label: 'Extérieur'),
    ];
    return Container(
      // Fond violet pâle restauré (demande utilisateur 2026-04-29 :
      // les changements « pas de fond + trait pleine largeur » ne
      // concernent QUE la barre de navigation principale du relevé,
      // pas les sous-sections internes des onglets).
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: const Color(0xFFF2ECF5),
      child: Row(
        children: [
          ...List.generate(items.length, (i) {
            final active = i == _subSection;
            // Refonte 2026-05-13 (maquette user) : icon + texte en NOIR
            // dans les 2 états. Violet (#8B6FA0) uniquement sur le trait
            // sous l'item actif — parité avec Bénéficiaire et Contexte
            // de vie.
            const labelColor = Color(0xFF0E1116); // ink-900
            const underlineColor = kBrandPurple; // mauve-500
            return Expanded(
              child: SoftTapScale(
                onTap: () {
                  setState(() => _subSection = i);
                  widget.onSubSectionChanged?.call(i);
                },
                child: Container(
                  color: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    children: [
                      // 20 → 18 → 16 (demande user 2026-05-13).
                      Icon(items[i].icon, size: 16, color: labelColor),
                      const SizedBox(height: 2),
                      Text(items[i].label,
                          style: const TextStyle(
                            // 10 → 12 (demande user 2026-05-13).
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: labelColor,
                          )),
                      const SizedBox(height: 6),
                      Container(
                        height: 1.5,
                        width: 28,
                        decoration: BoxDecoration(
                          color: active ? underlineColor : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: SaveStatusIndicator(saving: _saving),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Général
  // ---------------------------------------------------------------------------

  Widget _buildGeneral() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Type de logement (en premier)
        FormToggleGroup(
          label: 'Type de logement',
          options: const ['Maison', 'Appartement'],
          selected: _typology,
          expand: true,
          onChanged: (v) {
            _typology = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 14),
        // 2. Années avec flèche de copie
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: FormTextField(
                label: 'Construction',
                value: _yearConstruction,
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  _yearConstruction = v;
                  _markChanged();
                },
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: "Copier dans Habitation",
              child: InkWell(
                onTap: () {
                  if (_yearConstruction.isNotEmpty) {
                    setState(() => _yearHabitation = _yearConstruction);
                    _markChanged();
                  }
                },
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF2ECF5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_forward,
                      size: 16, color: Color(0xFF554265)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: FormTextField(
                label: "Habitation",
                value: _yearHabitation,
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  _yearHabitation = v;
                  _markChanged();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 3. Surface
        FormNumberField(
          label: 'Surface habitable',
          value: _surface,
          unit: 'm²',
          onChanged: (v) {
            _surface = v;
            _markChanged();
          },
        ),
        // (Niveaux + pièces déplacés vers la sous-section dédiée
        // « Niveaux et pièces ». Cf. `_buildLevelsAndRooms`. Demande
        // utilisateur 2026-04-29.)
        // (Chauffage + volets dans la sous-section « Équipements ».)
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Niveaux et pièces
  // ---------------------------------------------------------------------------

  /// Sous-section dédiée à la gestion des niveaux du logement (sortie
  /// de Général sur demande utilisateur 2026-04-29). Contient :
  ///   1. Le container morphant « + Ajouter un niveau » avec ses 3 états
  ///      (bouton / picker / éditeur) — cf. `_buildAddLevelInline`.
  ///   2. La liste des niveaux déjà ajoutés sous forme de cartes
  ///      pliantes (`_buildLevelCard`). Une seule carte ouverte à la
  ///      fois — les autres affichent « Label (pièces cochées) » +
  ///      crayon pour ré-éditer.
  ///   3. Le niveau actuellement en édition INLINE dans le container
  ///      morphant (`_pendingLevelField`) est SKIPPÉ ici pour éviter
  ///      le double rendu.
  Widget _buildLevelsAndRooms() {
    final available = _kLevelConfigs
        .where((c) => !_orderedLevels.contains(c.field))
        .toList();
    // Ordre d'affichage (demande utilisateur 2026-04-29) :
    //   1. Cartes des niveaux DÉJÀ AJOUTÉS, en haut
    //   2. Container morphant « + Ajouter un niveau » EN DESSOUS
    // → ergo voit immédiatement ses niveaux ajoutés, le bouton +
    //   se "décale" vers le bas au fur et à mesure des ajouts.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._orderedLevels
            .where((field) => field != _pendingLevelField)
            .map((field) {
          final cfg = _kLevelConfigs.firstWhere((c) => c.field == field);
          return Padding(
            key: ValueKey<String>('level-${cfg.field}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildLevelCard(cfg),
          );
        }),
        if (available.isNotEmpty) ...[
          const SizedBox(height: 6),
          _buildAddLevelInline(available),
        ],
        if (available.isEmpty && _orderedLevels.isEmpty)
          // Edge case : aucune config de niveau dispo et aucun niveau
          // ajouté. En théorie impossible (kLevelConfigs n'est jamais
          // vide), mais on évite l'écran totalement blanc.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Aucun niveau disponible.',
                style: TextStyle(color: Color(0xFF2B323A), fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Équipements (chauffage + volets)
  // ---------------------------------------------------------------------------

  Widget _buildEquipements() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Chauffage (multi-select pills toujours visibles).
        _buildHeatingEditor(),
        const SizedBox(height: 18),
        // 2. Volets (pills toujours visibles, pas de repli).
        _buildVoletRow(
          'Volets roulants manuels',
          _voletsManStatus,
          _voletsManLoc,
          (s) => setState(() {
            _voletsManStatus = s;
            if (s != 'Localisé') _voletsManLoc = '';
          }),
          (l) => setState(() => _voletsManLoc = l),
        ),
        const SizedBox(height: 10),
        _buildVoletRow(
          'Volets roulants électriques',
          _voletsElecStatus,
          _voletsElecLoc,
          (s) => setState(() {
            _voletsElecStatus = s;
            if (s != 'Localisé') _voletsElecLoc = '';
          }),
          (l) => setState(() => _voletsElecLoc = l),
        ),
        const SizedBox(height: 10),
        _buildVoletRow(
          'Volets persiennes',
          _voletsPersStatus,
          _voletsPersLoc,
          (s) => setState(() {
            _voletsPersStatus = s;
            if (s != 'Localisé') _voletsPersLoc = '';
          }),
          (l) => setState(() => _voletsPersLoc = l),
        ),
        // NB : le bloc « Observations sur les équipements et
        // utilisation » a été retiré (demande utilisateur 2026-04-28
        // — « rien à ajouter, simplement une connexion à établir »).
        // Le champ `obs` page 6 du PDF est désormais alimenté par la
        // note du panneau latéral (en haut à droite du formulaire) —
        // sous-sections `Général` et `Extérieur` concaténées côté
        // serveur dans `fetchVadOverlayNotesForReport`. L'ancien
        // tabKey `Accessibilité-Équipements` reste lu en fallback
        // pour les dossiers historiques qui auraient encore du
        // contenu dessus.
      ],
    );
  }

  /// Container "morphant" pour l'ajout d'un niveau — passe par 3 états
  /// avec une transition fluide (AnimatedSize pour la hauteur,
  /// AnimatedSwitcher pour le contenu) :
  ///
  ///   1. **Bouton** : juste la pill "+ Ajouter un niveau"
  ///   2. **Picker** : la même boîte étendue, propose les types de
  ///      niveaux (Sous-sol, RDC, 1er étage, …) en grille 2 colonnes
  ///   3. **Éditeur** : la boîte se transforme en éditeur du niveau
  ///      choisi (titre + cases à cocher des pièces + ajout custom)
  ///
  /// Quand l'utilisateur clique sur le X de l'éditeur, le niveau est
  /// "settled" dans la liste des niveaux du foyer (juste en dessous)
  /// et le container reprend la forme du bouton — toujours en
  /// transition douce.
  Widget _buildAddLevelInline(List<_LevelConfig> available) {
    // Détermine l'état courant + la clé/contenu à afficher.
    Widget content;
    Key contentKey;
    if (_pendingLevelField != null) {
      final cfg = _kLevelConfigs.firstWhere(
        (c) => c.field == _pendingLevelField,
      );
      contentKey = ValueKey<String>('editor-${cfg.field}');
      // Bouton "+ Ajouter un niveau" toujours visible AU-DESSUS de
      // l'éditeur du niveau pending — permet à l'utilisateur
      // d'enchaîner sans devoir d'abord fermer le niveau en cours.
      // Le tap "settle" le niveau pending puis rouvre la picker
      // (cf. `_settlePendingAndOpenPicker`).
      final stillAvailable = _kLevelConfigs
          .where((c) =>
              !_orderedLevels.contains(c.field) || c.field == cfg.field)
          .where((c) => c.field != cfg.field)
          .toList();
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stillAvailable.isNotEmpty) ...[
            _buildAddLevelButton(onTap: _settlePendingAndOpenPicker),
            const SizedBox(height: 10),
          ],
          _buildLevelCard(cfg),
        ],
      );
    } else if (_addLevelMode) {
      contentKey = const ValueKey<String>('picker');
      content = _buildLevelTypePicker(available);
    } else {
      contentKey = const ValueKey<String>('button');
      content = _buildAddLevelButton();
    }

    // AnimatedSize pour la hauteur (transition douce quand le contenu
    // grandit/rétrécit) ; AnimatedSwitcher pour le crossfade + slide
    // léger ("déroulement") du contenu interne.
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) {
          // Layout par défaut mais sans empilement vertical : on
          // affiche l'enfant courant en haut, les transitions
          // sortantes sont en surimpression. Garde la hauteur cohérente
          // avec AnimatedSize.
          return Stack(
            alignment: Alignment.topCenter,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          // "Déroulement" : slide depuis le haut + fondu — donne la
          // sensation que le contenu se déploie depuis le bord
          // supérieur du container.
          final slide = Tween<Offset>(
            begin: const Offset(0, -0.06),
            end: Offset.zero,
          ).animate(animation);
          return ClipRect(
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: slide,
                child: child,
              ),
            ),
          );
        },
        child: KeyedSubtree(key: contentKey, child: content),
      ),
    );
  }

  /// Pill "+ Ajouter un niveau" — utilisée à la fois comme état 1 du
  /// container morphant (rentre dans la picker au tap) ET en haut de
  /// l'éditeur (état 3) pour permettre d'enchaîner l'ajout d'un autre
  /// niveau sans devoir d'abord refermer celui en cours d'édition.
  /// [onTap] permet aux deux call sites de fournir le bon handler.
  Widget _buildAddLevelButton({VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap ?? () => setState(() => _addLevelMode = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF2ECF5),
          // Refonte 2026-05-13 : pill radius 999 uniforme.
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFD8D0DC), width: 1.5),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 16, color: Color(0xFF554265)),
            SizedBox(width: 8),
            Text('Ajouter un niveau',
                style: TextStyle(
                  color: Color(0xFF554265),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }

  /// Settle le niveau en cours d'édition (le sort du container vers la
  /// liste, collapsé en pill) puis rouvre la picker pour qu'un nouveau
  /// type de niveau puisse être choisi tout de suite. Appelé quand
  /// l'utilisateur clique sur le bouton "+ Ajouter un niveau"
  /// affiché en haut de l'éditeur d'un niveau pending — chaîne fluide
  /// d'ajout de plusieurs niveaux dans la foulée.
  void _settlePendingAndOpenPicker() {
    setState(() {
      _pendingLevelField = null;
      _expandedLevel = null;
      _addLevelMode = true;
    });
  }

  /// État 2 : picker des types de niveaux — même boîte violet pâle que
  /// le bouton, chevron en haut à droite pour replier. Les types
  /// disponibles s'affichent en grille 2 colonnes via FormToggleGroup.
  ///
  /// **Tap-to-fold sur tout le container** : tap n'importe où dans la
  /// boîte violette qui n'est pas un des boutons de type → repli du
  /// picker (équivalent au tap sur le chevron). Demande utilisateur
  /// 2026-04-28 : « si je veux refermer le bouton la fonctionnalité du
  /// chevron doit être active sur toute le container violet si je n'ai
  /// pas cliqué sur un bouton ». Les pills `FormToggleGroup` ont leur
  /// propre gesture handler, elles gagnent l'arène pour leur zone —
  /// donc tap sur une pill → ajoute le niveau, tap ailleurs → replie.
  Widget _buildLevelTypePicker(List<_LevelConfig> available) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _addLevelMode = false),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF2ECF5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFD8D0DC), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 4),
                const Icon(Icons.layers_outlined,
                    size: 16, color: Color(0xFF554265)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Choisir un niveau',
                    style: TextStyle(
                      color: Color(0xFF554265),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                // Chevron pour replier le picker. Comportement
                // dupliqué côté container parent (cf. GestureDetector
                // au-dessus) — l'icône reste comme affordance visuelle
                // explicite mais n'est plus le seul endroit cliquable.
                // Pas de croix — demande utilisateur 2026-04-28 :
                // « met un chevron dès le début ne met pas de croix,
                // la croix apparaît seulement pour supprimer un niveau
                // si on RE CLIQUE dessus ». La croix « supprimer »
                // reste réservée à l'éditeur d'un niveau RÉ-OUVERT
                // depuis sa pill (cf. `_buildLevelCard`) — pas au
                // picker, qui n'a aucune donnée à supprimer.
                InkWell(
                  onTap: () => setState(() => _addLevelMode = false),
                  // Refonte 2026-05-13 : pill radius 999 uniforme.
                  borderRadius: BorderRadius.circular(999),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.expand_less,
                        size: 20, color: Color(0xFF554265)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FormToggleGroup(
              label: '',
              options: available.map((c) => c.label).toList(),
              selected: '',
              columns: 2,
              onChanged: (picked) {
                final cfg = available.firstWhere((c) => c.label == picked);
                _addLevel(cfg);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Ajoute un nouveau niveau au foyer :
  ///  - Insertion EN TÊTE de [_orderedLevels] (persistance).
  ///  - Marque `_pendingLevelField` → l'éditeur du niveau est rendu
  ///    À L'INTÉRIEUR du container morphant (au lieu d'apparaître en
  ///    dessous), et la liste principale skip ce niveau le temps
  ///    qu'il y reste.
  ///  - Le niveau est ouvert par défaut.
  ///  - Aucun scroll automatique : le morphing du container se fait
  ///    sur place, l'œil de l'utilisateur reste dans la même zone.
  void _addLevel(_LevelConfig cfg) {
    setState(() {
      _orderedLevels.insert(0, cfg.field);
      _levelRooms[cfg.field] ??= [];
      _customRoomCtrls.putIfAbsent(
          cfg.field, () => TextEditingController());
      _expandedLevel = cfg.field;
      _addLevelMode = false;
      _pendingLevelField = cfg.field;
    });
    _scheduleSave();
  }

  /// Éditeur chauffage : pills multi-toggle sur 3 colonnes, toujours
  /// visibles. L'ergo peut cocher/décocher librement sans que la liste
  /// ne se replie.
  Widget _buildHeatingEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Chauffage',
          // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Color(0xFF0E1116),
          ),
        ),
        const SizedBox(height: 5),
        _buildMultiSelectGrid(
          options: _heatingOptions,
          selected: _heatingTypes,
          columns: 3,
          onToggle: (opt) {
            setState(() {
              final next = Set<String>.from(_heatingTypes);
              if (next.contains(opt)) {
                next.remove(opt);
              } else {
                next.add(opt);
              }
              _heatingTypes = next;
            });
            _scheduleSave();
          },
        ),
      ],
    );
  }

  /// Grille de pills multi-toggle (colonnes fixes, largeur égale). Les
  /// pills non sélectionnées ont une bordure visible pour bien marquer
  /// leur présence ; les sélectionnées passent en violet plein.
  Widget _buildMultiSelectGrid({
    required List<String> options,
    required Set<String> selected,
    required int columns,
    required ValueChanged<String> onToggle,
  }) {
    final rows = <Widget>[];
    for (var r = 0; r < options.length; r += columns) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < columns; c++) {
        if (c > 0) rowChildren.add(const SizedBox(width: 8));
        final idx = r + c;
        rowChildren.add(
          Expanded(
            child: idx < options.length
                ? _buildPill(
                    label: options[idx],
                    isSelected: selected.contains(options[idx]),
                    onTap: () => onToggle(options[idx]),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(Row(children: rowChildren));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _buildPill({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    // Refonte 2026-05-13 : aligné sur FormToggleGroup.buildPill
    // (Occupation) — AnimatedContainer 220ms, height 32, padding h:14,
    // bg mauve-50 → mauve-500, border transparent → mauve-500, texte
    // fontSize 14 w400/w500 (Quicksand hérité du thème).
    // Demande utilisateur : « conceptionne … vraiment pareil que les
    // autres boutons, avec fond de couleur de base, animation de
    // remplissage » → s'applique ici à Chauffage et Annexes.
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? kBrandPurple // mauve-500
              : const Color(0xFFFAF7FB), // mauve-50
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSelected
                ? kBrandPurple
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : const Color(0xFF2B323A), // ink-700
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildLevelCard(_LevelConfig cfg) {
    final rooms = _levelRooms[cfg.field] ?? [];
    final allItems = <String>[
      ...cfg.presetRooms,
      ...rooms.where((r) =>
          !cfg.presetRooms.any((p) => p.toLowerCase() == r.toLowerCase())),
    ];
    final ctrl = _customRoomCtrls[cfg.field]!;
    final isExpanded = _expandedLevel == cfg.field;

    if (!isExpanded) {
      // Vue repliée (style menu déroulant) : "Sous-sol (Salle de bain,
      // WC ²)" + chevron vers le bas. Pas de crayon ni de croix — la
      // croix n'apparaît qu'une fois la card rouverte (mode édition).
      // Les doublons sont groupés avec un exposant (² ou ³) pour
      // refléter le compteur des pills.
      final displayRooms =
          rooms.isEmpty ? '—' : _formatRoomsWithCounts(rooms);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expandedLevel = cfg.field),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF2B323A),
                    ),
                    children: [
                      TextSpan(text: cfg.label),
                      TextSpan(
                        text: ' ($displayRooms)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2B323A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.expand_more,
                size: 20,
                color: Color(0xFF5C6670),
              ),
            ],
          ),
        ),
      );
    }

    // Tap-to-fold sur tout le container violet de l'éditeur — même
    // pattern que le picker (« Choisir un niveau ») : tap sur une pill
    // de pièce ou sur le champ texte « Ajouter une pièce » est absorbé
    // par le widget concerné (gagne l'arène) ; tap n'importe où ailleurs
    // (titre, padding, espace inter-pills) replie l'éditeur. Demande
    // utilisateur 2026-04-28 (« fait la meme fonctionnalité une fois
    // que j'ai choisi un niveau pour la partie choix des types de
    // pieces »).
    //
    // **Action toujours = collapse, jamais delete** : le tap n'importe
    // où ne fait QUE replier (équivalent du chevron). La suppression
    // reste exclusive à la croix top-right (intention explicite, à
    // l'abri des taps accidentels). Pour un niveau pending →
    // settle+collapse ; pour un niveau ré-ouvert → simple collapse.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          if (_pendingLevelField == cfg.field) {
            _pendingLevelField = null;
          }
          _expandedLevel = null;
        });
        _scheduleSave();
      },
      child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF2ECF5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête niveau + bouton fermer/supprimer.
          //
          // L'icône change selon le « moment » de l'édition (demande
          // utilisateur 2026-04-28 : « on doit simplement avoir un
          // chevron pour refermer mais pas une croix, la croix apparait
          // seulement quand on reclique dessus si on souhaite supprimer
          // le niveau ajouté precedemment ») :
          //   - Niveau qui vient d'être ajouté (encore dans le container
          //     morphant, `_pendingLevelField == cfg.field`) → chevron
          //     vers le haut. Le tap "settle" le niveau dans la liste
          //     principale et collapse l'éditeur en pill (donnée
          //     préservée).
          //   - Niveau ré-ouvert depuis sa pill (déjà settle dans la
          //     liste, `_pendingLevelField != cfg.field`) → croix. Le
          //     tap retire le niveau du foyer (intention destructive
          //     explicite, utilisateur a choisi de re-cliquer dessus).
          Row(
            children: [
              Text(
                cfg.label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF8A939D),
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              // Bouton fermer/supprimer.
              //
              // **Hit area agrandie en mode croix** : comme le reste du
              // container violet replie l'éditeur (cf. GestureDetector
              // parent), il faut que la croix de suppression ait une
              // zone tactile généreuse pour être atteignable sans
              // déclencher le repli par accident. Demande utilisateur
              // 2026-04-28 : « rend la croix plus facilement cliquable
              // si elle est présente car le reste du container le
              // repli ». Padding 12 + icon 18 → ~42 × 42 pt de hit
              // area, au-dessus du seuil HIG (44 pt) sans couper
              // visuellement avec le reste du header.
              //
              // En mode chevron, on garde la hit area d'origine (le
              // tap-anywhere du parent absorbe les ratés).
              InkWell(
                onTap: () async {
                  if (_pendingLevelField == cfg.field) {
                    // Pending = juste créé, pas de confirmation
                    // nécessaire — le chevron up "settle" sans
                    // perdre de données saisies.
                    setState(() {
                      _pendingLevelField = null;
                      _expandedLevel = null;
                    });
                    _scheduleSave();
                    return;
                  }

                  // Niveau déjà settled : la croix est destructive.
                  // Confirmation explicite avant de supprimer + reset
                  // total des données (pièces cochées, descriptions)
                  // pour que le niveau parte sur un état vierge si
                  // l'ergo le ré-ajoute plus tard. Demande user
                  // 2026-04-28 : "si je supprime le niveau ça doit
                  // tout réinitialiser, pas garder les boutons cochés
                  // au prochain ajout".
                  final confirm = await showSoftDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      title: const Text('Supprimer ce niveau ?'),
                      content: Text(
                        'Le niveau « ${cfg.label} » et toutes les '
                        'pièces cochées dessus seront supprimés du '
                        'foyer. Cette action est définitive.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Annuler'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFB91C1C),
                          ),
                          child: const Text('Supprimer'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true || !mounted) return;

                  setState(() {
                    _orderedLevels.remove(cfg.field);
                    // Reset complet des données du niveau — sans ça
                    // un re-add ressort les anciennes pills cochées.
                    _levelRooms[cfg.field] = [];
                    // Sync annexe Garage : si le Garage était coché
                    // uniquement parce qu'il était dans ce niveau, on
                    // doit le retirer aussi de la liste annexes.
                    final stillPresent = _levelRooms.values
                        .any((rooms) => rooms.contains('Garage'));
                    if (!stillPresent) _annexes.remove('Garage');
                  });
                  _scheduleSave();
                },
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: EdgeInsets.all(
                    _pendingLevelField == cfg.field ? 4 : 12,
                  ),
                  child: Icon(
                    _pendingLevelField == cfg.field
                        ? Icons.expand_less
                        : Icons.close,
                    size: _pendingLevelField == cfg.field ? 20 : 18,
                    color: const Color(0xFF8A939D),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Pièces — boutons-pilules multi-sélection (plus de
          // cases à cocher). Un tap bascule l'état de la pièce dans
          // le niveau courant.
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // Demande utilisateur : boutons des pièces nettement plus
            // grands (ils étaient si compressés que les libellés
            // longs comme "Salle de bain" se faisaient tronquer).
            // Aspect ratio 3.2 = environ 60 px de haut pour ~190 px
            // de large → place pour un libellé d'une ligne avec
            // confort tactile sur iPad.
            childAspectRatio: 3.2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: allItems.map((room) {
              // Compte les occurrences de cette pièce dans le niveau
              // courant. Le tap cycle 0 → 1 → 2 → 3 → 4 → 0 (max 4
              // pour couvrir les maisons familiales avec jusqu'à
              // 4 chambres sur un même étage — demande utilisateur
              // 2026-05-04). Bump global à toutes les pièces, pas
              // juste « Chambre » : permet aussi 4 SDB / 4 WC sur le
              // même niveau si besoin (rare mais cohérent).
              final count = rooms.where((r) => r == room).length;
              final checked = count > 0;
              return TogglePillButton(
                label: room,
                active: checked,
                countBadge: count,
                expand: true,
                onTap: () {
                  setState(() {
                    final next =
                        List<String>.from(_levelRooms[cfg.field] ?? []);
                    if (count >= 4) {
                      // Cycle complet : on retire toutes les
                      // occurrences (retour à 0 = pill désactivée).
                      next.removeWhere((r) => r == room);
                    } else {
                      // Incrément : ajoute une occurrence (la pill
                      // affiche ² ³ ⁴ via TogglePillButton).
                      next.add(room);
                    }
                    _levelRooms[cfg.field] = next;
                    // Sync Garage annexe : présent dans n'importe quel
                    // niveau → coché dans Annexes ; sinon décoché.
                    if (room == 'Garage') {
                      final stillPresent = _levelRooms.values
                          .any((rooms) => rooms.contains('Garage'));
                      if (stillPresent) {
                        _annexes.add('Garage');
                      } else {
                        _annexes.remove('Garage');
                      }
                    }
                  });
                  _scheduleSave();
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          // Ajout pièce personnalisée
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  stylusHandwritingEnabled: true,
                  // fontSize 12 + padding vertical 10 → même hauteur que
                  // le pill "Vasque suspendue" (référence du relevé).
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    hintText: 'Ajouter une pièce',
                    hintStyle: const TextStyle(
                        color: Color(0xFF8A939D), fontSize: 12),
                    filled: true,
                    fillColor: Colors.white,
                    // Refonte 2026-05-13 (demande user) — border gris léger
                    // partout, focus violet, parité avec FormTextField et
                    // le champ Ville du dossier.
                    // Refonte 2026-05-13 : pill radius 999 uniforme.
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                    ),
                    // Refonte 2026-05-13 : pill radius 999 uniforme.
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide(color: Color(0xFFB9C0C7)),
                    ),
                    // Refonte 2026-05-13 : pill radius 999 uniforme.
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: const BorderSide(
                          color: kBrandPurple, width: 1.5),
                    ),
                  ),
                  onSubmitted: (_) => _addCustomRoom(cfg),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _addCustomRoom(cfg),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                      color: Color(0xFFF2ECF5), shape: BoxShape.circle),
                  child: const Icon(Icons.add,
                      color: Color(0xFF554265), size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  void _addCustomRoom(_LevelConfig cfg) {
    final ctrl = _customRoomCtrls[cfg.field]!;
    final val = ctrl.text.trim();
    if (val.isEmpty) return;
    final current = List<String>.from(_levelRooms[cfg.field] ?? []);
    final lc = val.toLowerCase();
    if (!current.any((r) => r.toLowerCase() == lc) &&
        !cfg.presetRooms.any((p) => p.toLowerCase() == lc)) {
      current.add(val);
    }
    setState(() {
      _levelRooms[cfg.field] = current;
      ctrl.clear();
    });
    _scheduleSave();
  }

  Widget _buildVoletRow(
    String label,
    String status,
    String loc,
    ValueChanged<String> onStatusChange,
    ValueChanged<String> onLocChange,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormToggleGroup(
          label: label,
          options: _voletStatuses,
          selected: status,
          columns: 3,
          onChanged: (v) {
            onStatusChange(v);
            _markChanged();
          },
        ),
        if (status == 'Localisé') ...[
          const SizedBox(height: 10),
          FormTextField(
            label: 'Localisation',
            value: loc,
            onChanged: (v) {
              onLocChange(v);
              _markChanged();
            },
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Extérieur
  // ---------------------------------------------------------------------------

  Widget _buildExterior() {
    final showGarageMoto = _annexes.contains('Garage');
    final showPortailMoto = _portail;
    // `_easyAccess` nullable : '' si non renseigné → aucun pill highlight.
    final accessValue = _easyAccess == null
        ? ''
        : (_easyAccess! ? 'Facile' : 'À revoir');
    final annexItems = <String>[..._annexeOptions, 'Portail'];
    final selectedAnnexes = <String>{
      ..._annexes,
      if (_portail) 'Portail',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Accès depuis la rue : pills toujours visibles.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Accès depuis la rue',
                // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF0E1116))),
            const SizedBox(height: 5),
            FormToggleGroup(
              label: '',
              options: const ['Facile', 'À revoir'],
              selected: accessValue,
              expand: true,
              onChanged: (v) {
                setState(() {
                  // v == '' → désélection (l'ergo a re-cliqué la pill
                  // sélectionnée). On repasse en « non renseigné ».
                  if (v.isEmpty) {
                    _easyAccess = null;
                  } else {
                    _easyAccess = v == 'Facile';
                  }
                });
                _scheduleSave();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Annexes : pills 3 colonnes, toujours visibles.
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Annexes',
                // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF0E1116))),
            const SizedBox(height: 5),
            _buildMultiSelectGrid(
              options: annexItems,
              selected: selectedAnnexes,
              columns: 3,
              onToggle: (opt) {
                setState(() {
                  if (opt == 'Portail') {
                    _portail = !_portail;
                    if (!_portail) {
                      _motorisationPortail = 'Aucun';
                      _motorisationOrder.remove('Portail');
                    } else {
                      // Ajoute en fin d'ordre (premier sélectionné en
                      // haut, second en dessous).
                      if (!_motorisationOrder.contains('Portail')) {
                        _motorisationOrder.add('Portail');
                      }
                    }
                  } else {
                    if (_annexes.contains(opt)) {
                      _annexes.remove(opt);
                      if (opt == 'Garage') {
                        _motorisationPorteGarage = 'Aucun';
                        _motorisationOrder.remove('Garage');
                      }
                    } else {
                      _annexes.add(opt);
                      if (opt == 'Garage' &&
                          !_motorisationOrder.contains('Garage')) {
                        _motorisationOrder.add('Garage');
                      }
                    }
                  }
                });
                _scheduleSave();
              },
            ),
          ],
        ),
        // Motorisations conditionnelles (toujours visibles quand
        // l'annexe associée est active). Boutons (FormToggleGroup) au
        // lieu de menu déroulant, **empilés verticalement** avec
        // l'élément sélectionné en premier en haut (demande utilisateur
        // 2026-04-28).
        if (showGarageMoto || showPortailMoto) ...[
          const SizedBox(height: 16),
          ..._motorisationOrder
              // Filtre défensif : on ne rend que les motorisations dont
              // l'annexe est encore active.
              .where((m) =>
                  (m == 'Garage' && showGarageMoto) ||
                  (m == 'Portail' && showPortailMoto))
              .map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _buildMotorisationButtons(m),
                  )),
        ],
      ],
    );
  }

  /// Bloc de sélection (FormToggleGroup) pour la motorisation d'une
  /// annexe ('Garage' ou 'Portail') — 3 boutons pleine largeur :
  /// Aucun / Manuel / Électrique. Remplace l'ancien menu déroulant
  /// `FormSelectDropdown` (demande utilisateur 2026-04-28).
  Widget _buildMotorisationButtons(String which) {
    final label = which == 'Garage' ? 'Porte de garage' : 'Portail';
    final value = which == 'Garage'
        ? _motorisationPorteGarage
        : _motorisationPortail;
    return FormToggleGroup(
      label: label,
      options: _motorisationOptions,
      selected: value,
      columns: 3,
      expand: true,
      onChanged: (v) {
        setState(() {
          if (which == 'Garage') {
            _motorisationPorteGarage = v;
          } else {
            _motorisationPortail = v;
          }
        });
        _scheduleSave();
      },
    );
  }

}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _QuickNavItem {
  final IconData icon;
  final String label;
  const _QuickNavItem({required this.icon, required this.label});
}
