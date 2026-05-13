import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/beneficiary_badges.dart';
import '../components/beneficiary_palettes.dart';
import '../components/commune_field_group.dart';
import '../components/form_widgets.dart';
import '../components/notes_widget.dart';
import '../models/types.dart';
import '../services/data_service.dart';
import '../services/dossier_repository.dart';
import '../services/references_service.dart';
import '../services/save_debounce.dart';
import 'conflict_resolution_screen.dart';
import 'documents_screen.dart';
import 'visit_report_screen.dart';

/// Dossier detail screen — React parity with `DossierDetail` in
/// `components/DossierView.tsx`. The "Informations Bénéficiaire" card shows
/// ONLY the fields React displays here:
///  - Type d'accompagnement (read-only)
///  - Prénom, Nom (editable)
///  - Occupants (dropdown), Ville (autocomplete, zip hidden)
///  - Commentaire projet (read-only, multiline — loaded from observations)
///
/// Everything else (phone, email, address, santé, situation familiale,
/// revenus, trusted person, …) is edited via the Bénéficiaire tab of the
/// visit report, not here.
class DossierScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;
  final DossierRepository? repository;

  /// If provided, the "Visite Domicile" button will call this callback
  /// instead of pushing a full-screen route. This keeps the left sidebar
  /// visible inside the visit report (the parent MainScreen just swaps
  /// the central content).
  final VoidCallback? onOpenVisitReport;

  /// Idem pour l'écran Documents : si le parent (`MainScreen`) câble
  /// ce callback, on l'utilise pour rester dans le shell avec la
  /// sidebar visible. Demande utilisateur 2026-04-29 : « y'a toujours
  /// pas le menu vertical à gauche » sur Documents — avant cette
  /// option, on faisait un `Navigator.push` qui empilait la page sur
  /// la sidebar et la masquait.
  final VoidCallback? onOpenDocuments;

  /// Notifié immédiatement quand l'ergo coche/décoche « bénéficiaire
  /// préparé » dans le bandeau bénéficiaire. Permet à MainScreen de
  /// patcher sa liste `_dossiers` SANS attendre un refresh complet du
  /// sync engine — la bordure verte/jaune sur l'avatar de la liste
  /// « Mes dossiers » se met à jour instantanément (demande
  /// utilisateur 2026-05-05).
  final void Function(String dossierId, bool prepared)?
      onBeneficiaryPreparedChanged;

  const DossierScreen({
    super.key,
    required this.dossier,
    required this.onBack,
    this.repository,
    this.onOpenVisitReport,
    this.onOpenDocuments,
    this.onBeneficiaryPreparedChanged,
  });

  @override
  State<DossierScreen> createState() => _DossierScreenState();
}

class _DossierScreenState extends State<DossierScreen> {
  late final DossierRepository _repository;

  Timer? _saveTimer;
  bool _saving = false;
  bool _isBeneficiaryLocked = true;

  /// Coche « bénéficiaire préparé » du bandeau bénéficiaire (demande
  /// utilisateur 2026-05-05). Initialisée depuis `widget.dossier`,
  /// togglée via le bouton check entouré à côté du crayon. Persistée
  /// localement via `DataService.setBeneficiaryPrepared` (pas de sync
  /// NocoDB en v1).
  late bool _beneficiaryPrepared;

  // Editable fields shown in the card
  late String _firstName;
  late String _lastName;
  late String _numberPeople; // dropdown value: '1'..'5' or '5+'
  late String _address; // rue + n° (modifiable depuis ce bloc)
  late String _city;
  late String _zipCode;
  late String _cityId;

  // Readonly fields
  late String _natureAccompagnement;
  late String _incomeCategory;
  double? _fiscalRevenue;

  // Jeton incrémenté après la première hydratation de la note rapide
  // avec le commentaire projet d'`observations.projetSouhaitUsage` —
  // permet à NotesWidget de re-fetch quand la seed est terminée et
  // donc d'afficher le commentaire dès l'ouverture du dossier.
  int _quickNoteRefreshToken = 0;

  // References
  final ReferencesService _references = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refSub;
  List<CommuneOption> _communeOptions = const [];

  static const List<String> _occupantOptions = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '5+',
  ];

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? DossierRepository();
    _loadFromDossier();

    // Refactor 2026-05-12 : suppression de `enterActiveContext` (mode
    // pull ultra-actif retiré). La fiche bénéficiaire affiche l'état
    // au moment de l'ouverture ; les modifs distantes sont récupérées
    // au prochain événement (foreground/reconnexion/login).

    _references.ensureLoaded();
    _communeOptions = _mapCommunes();
    _refSub = _references.onLoaded.listen((_) {
      if (!mounted) return;
      // Quand les barèmes ANAH arrivent depuis NocoDB, on re-calcule
      // tout de suite la catégorie pour que le badge s'affiche correct
      // même si l'user n'a encore rien modifié.
      _recomputeIncomeCategory();
      setState(() => _communeOptions = _mapCommunes());
    });
    // Hydrate la note rapide avec le commentaire projet (si la note
    // rapide n'existe pas encore côté storage — un utilisateur qui a
    // volontairement effacé la note ne verra pas le commentaire
    // réapparaître).
    _seedQuickNoteFromProjectComment();
  }

  /// Si la note rapide ("notes_rapides") n'existe PAS encore côté
  /// storage pour ce dossier, et que `observations.projetSouhaitUsage`
  /// contient un commentaire projet, on pré-remplit la note avec ce
  /// commentaire. Ensuite, NotesWidget se re-fetch via le jeton de
  /// rafraîchissement et affiche le texte.
  ///
  /// Condition d'idempotence : on ne seede QUE si la ligne n'existe
  /// pas du tout (DataService.fetchNoteDrawingJson → null). Si
  /// l'utilisateur a déjà tapé puis effacé la note, il y a une ligne
  /// (JSON avec texte vide) et on ne touche à rien.
  Future<void> _seedQuickNoteFromProjectComment() async {
    try {
      final existingJson = await DataService().fetchNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: 'notes_rapides',
        pageNumber: 0,
      );
      if (existingJson != null) return;
      // Récupère le commentaire projet depuis les observations du dossier.
      final obs = await _repository.fetchObservations(widget.dossier.id);
      final comment = (obs?.projetSouhaitUsage ?? '').trim();
      if (comment.isEmpty) return;
      // Écrit le commentaire comme texte initial de la page 0 de la
      // note rapide. Format identique à `_currentDrawingJson()` de
      // NotesWidget (version:1, text, strokes).
      final json = jsonEncode({
        'version': 1,
        'text': comment,
        'strokes': <dynamic>[],
      });
      await DataService().saveNoteDrawingJson(
        patientId: widget.dossier.patient.id,
        tabKey: 'notes_rapides',
        pageNumber: 0,
        drawingJson: json,
      );
      if (mounted) {
        // Le jeton externe force NotesWidget à re-fetch sa page 0 — le
        // commentaire tout juste sauvé apparaît alors dans la zone texte.
        setState(() => _quickNoteRefreshToken++);
      }
    } catch (_) {
      // silent — la note rapide restera vide si la hydratation échoue.
    }
  }

  List<CommuneOption> _mapCommunes() {
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

  void _loadFromDossier() {
    final p = widget.dossier.patient;
    _firstName = p.firstName;
    _lastName = p.lastName;
    _address = p.address;
    _city = p.city;
    _zipCode = p.zipCode;
    _cityId = p.cityId;
    _incomeCategory = p.incomeCategory;
    _natureAccompagnement = widget.dossier.natureAccompagnement;
    _fiscalRevenue = _householdFiscalRevenue(p);
    _beneficiaryPrepared = widget.dossier.beneficiaryPrepared;

    final n = p.numberPeople ?? 0;
    if (n <= 0) {
      _numberPeople = '1';
    } else if (n >= 5) {
      _numberPeople = '5';
    } else {
      _numberPeople = n.toString();
    }
  }

  @override
  void dispose() {
    _refSub?.cancel();
    // Flush last-shot synchrone si une saisie attendait le debounce.
    // dispose() ne peut pas await, mais _save() écrit en SQLite avec
    // une promesse qu'on laisse partir — au pire elle complète après le
    // démontage (le `await _database.database` ne dépend pas du widget).
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      // ignore: discarded_futures
      _save();
    }
    super.dispose();
  }

  /// Handler pour les champs texte qui n'influencent PAS la catégorie de
  /// revenus (Nom, Prénom, Adresse, …). Pas de `_recomputeIncomeCategory`
  /// ni de `setState(() {})` : seul le state local de mémorisation
  /// est mis à jour (l'affectation `_lastName = v` est déjà faite par
  /// l'appelant). On planifie juste le save SQLite débouncé. Le
  /// FormTextField conserve sa valeur affichée (controller géré
  /// localement) — pas besoin de rebuild.
  ///
  /// Avant cette séparation : chaque keystroke sur Nom déclenchait
  /// _recomputeIncomeCategory + setState global, ce qui rebuildait
  /// tout le bloc dossier (badges, EpciBadge, photos, …) et
  /// occasionnellement faisait perdre des keystrokes ("BALS" arrivait
  /// en SQLite comme "BAL" voire "BAI"). Symptôme reporté.
  void _onTextChanged() {
    _scheduleSave();
  }

  /// Handler pour les champs qui influencent la catégorie de revenus
  /// (Occupants dropdown, RFR du foyer). On recalcule la catégorie
  /// puis on rebuild pour rafraîchir le badge — le coût rebuild est
  /// acceptable parce que ces 2 champs ne génèrent pas de keystrokes
  /// rapides (dropdown ou champ numérique).
  void _onIncomeAffectingChanged() {
    _recomputeIncomeCategory();
    setState(() {});
    _scheduleSave();
  }

  /// Recalcule la catégorie de revenu (Très modeste / Modeste /
  /// Intermédiaire / Supérieur) à partir de `_numberPeople` et
  /// `_fiscalRevenue`, en utilisant les barèmes ANAH chargés via
  /// `ReferencesService` (table NocoDB `baremes_anah`).
  /// - Met à jour `_incomeCategory` localement (badge en haut du dossier
  ///   rafraîchi instantanément).
  /// - La valeur est persistée côté patient dans `_save` (propagée à
  ///   NocoDB via le sync offline-first).
  void _recomputeIncomeCategory() {
    final numberPeopleInt =
        int.tryParse(_numberPeople.replaceAll('+', '')) ?? 1;
    final next = ReferencesService().computeIncomeCategory(
      numberPeopleInt,
      _fiscalRevenue,
    );
    // Si on n'a pas encore les barèmes chargés, computeIncomeCategory
    // renvoie '' → on ne touche pas à la valeur existante pour éviter
    // d'écraser une catégorie déjà calculée par le back.
    if (next.isNotEmpty) {
      _incomeCategory = next;
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    // Debounce uniformisé sur `kSaveDebounceText` (400 ms) — voir
    // `lib/services/save_debounce.dart` pour le rationale détaillé.
    _saveTimer = Timer(kSaveDebounceText, _save);
  }

  /// Annule le timer de save en cours et exécute `_save()` immédiatement
  /// si quelque chose était en attente. Appelé avant chaque navigation
  /// qui pourrait emmener l'utilisateur loin du dossier (VAD, Documents,
  /// etc.) pour garantir que la dernière saisie est en SQLite + dans la
  /// queue de sync_op AVANT que le code suivant tente de relire les
  /// données.
  Future<void> _flushPendingSave() async {
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      await _save();
    }
  }

  Future<void> _save() async {
    if (!mounted) return;
    // Pas de `setState(_saving = true/false)` : le seul consumer de
    // `_saving` est `SaveStatusIndicator` qui retourne désormais un
    // SizedBox.shrink() vide (demande utilisateur — aucun feedback
    // visuel pendant la sauvegarde). Avec save à 0 ms (chaque
    // keystroke), un setState ici aurait déclenché un rebuild lourd
    // par caractère tapé, qui mangeait des keystrokes — exactement
    // le bug "BAL au lieu de BALS" qu'on a passé du temps à éliminer.
    final numberPeopleInt =
        int.tryParse(_numberPeople.replaceAll('+', '')) ?? 1;
    // Recompute une dernière fois juste avant le save (au cas où les
    // barèmes viennent d'arriver entre le onChange et le save).
    _recomputeIncomeCategory();
    await _repository.updatePatientFields(widget.dossier.patient.id, {
      'first_name': _firstName,
      'last_name': _lastName,
      'number_people': numberPeopleInt,
      'address': _address,
      'city': _city,
      'zip_code': _zipCode,
      'city_id': _cityId,
      // RFR du foyer modifiable depuis le bloc Bénéficiaire
      // (demande utilisateur). Stocké au niveau patient — écrase
      // la valeur éventuellement calculée à partir des occupants.
      'fiscal_revenue': _fiscalRevenue,
      // Catégorie de revenu auto-dérivée des barèmes ANAH NocoDB.
      'income_category': _incomeCategory,
    });
  }

  String _formatDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      return DateFormat('dd/MM/yyyy').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  /// Mirrors React's `formatAccompanimentType()`:
  ///  - `diagnostic` → "Diag ergo"
  ///  - `ergo`       → "MPA ergo"
  ///  - `complet`    → "MPA complet"
  ///  - anything else → the raw value (or empty placeholder)
  /// Household RFR: sum of every occupant's RFR, or the legacy patient-level
  /// value when no per-occupant data exists (pre-migration records).
  double? _householdFiscalRevenue(Patient p) {
    final values = p.occupants
        .map((o) => o.fiscalRevenue)
        .whereType<double>()
        .toList();
    if (values.isEmpty) return p.fiscalRevenue;
    var total = 0.0;
    for (final v in values) {
      total += v;
    }
    return total;
  }

  String _formatFiscalRevenue(double? value) {
    if (value == null || value <= 0) return 'Non renseigné';
    final fmt = NumberFormat.currency(
      locale: 'fr_FR',
      symbol: '€',
      decimalDigits: 0,
    );
    return fmt.format(value);
  }

  // Note : `_formatAccompanimentType` a été déplacé vers la fonction
  // top-level `formatAccompanimentType` dans components/beneficiary_badges.dart
  // pour être réutilisée côté visit_report_screen.

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
    // Nouveau header (parité maquette) : bouton retour + NOM Prénom +
    // deux badges à droite du titre (type d'accompagnement en violet,
    // catégorie de revenu en couleur pastel liée à la catégorie).
    // La date "Créé le" reste à l'extrême droite.
    final accompanimentLabel =
        formatAccompanimentType(_natureAccompagnement).trim();
    final incomeLabel = _incomeCategory.trim();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            children: [
              // Bouton retour aligné sur celui du VAD (visit_report_screen
              // `_buildBackButton`). Demande utilisateur 2026-05-13 :
              // « fais la meme flèche pour les autres pages ».
              // 44×44 transparent, chevronLeft 24px ink-700.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onBack,
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
              Flexible(
                child: Text(
                  '${_lastName.toUpperCase()} $_firstName',
                  // Bumpé w600 → w700 pour alignement « textes du dossier
                  // légèrement plus épais que par défaut » (demande
                  // utilisateur 2026-05-13 : « met l'épaisseur de tout
                  // les textes légèrement plus importante comme dans
                  // le relevé de visite »).
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Fallback "MPA complet" 2026-05-07 : badge toujours
              // affiché même si le champ est vide (dossiers legacy).
              const SizedBox(width: 12),
              AccompanimentBadge(
                value: accompanimentLabel.isNotEmpty
                    ? accompanimentLabel
                    : 'MPA complet',
                rawType: _natureAccompagnement.trim().isNotEmpty
                    ? _natureAccompagnement
                    : 'complet',
                large: true,
              ),
              if (incomeLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                IncomeCategoryBadge(value: incomeLabel, large: true),
              ],
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              'Créé le',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            Text(
              _formatDate(widget.dossier.createdAt),
              // Date « créé le » bumpée w400 → w600 pour rester
              // alignée avec l'épaisseur générale du dossier (demande
              // utilisateur 2026-05-13).
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
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
    // IntrinsicHeight + CrossAxisAlignment.stretch force the two quick-action
    // buttons to share the same height (the taller one wins) so "Espace
    // Documents" and "Visite Domicile" are always visually aligned,
    // regardless of how their sub-labels wrap.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        Expanded(
          child: _QuickActionButton(
            // Icône "document avec lignes de texte" — plus iconique
            // qu'un trombone pour signaler l'espace Documents.
            icon: LucideIcons.fileText,
            label: 'Documents',
            subLabel: 'Photos, scans, plans...',
            onTap: () async {
              // Flush avant navigation : même rationale que pour le
              // bouton VAD — éviter qu'un dossier modifié localement
              // (mais pas encore sauvé à 400 ms près) ne soit lu en
              // version stale dans Documents.
              await _flushPendingSave();
              if (!mounted) return;
              // Préférer le callback in-shell (`onOpenDocuments`) pour
              // rester dans `MainScreen` avec la sidebar gauche
              // visible (demande utilisateur 2026-04-29). Fallback sur
              // `Navigator.push` uniquement si le parent ne câble pas
              // le handler — utile en tests isolés.
              if (widget.onOpenDocuments != null) {
                widget.onOpenDocuments!();
                return;
              }
              if (!mounted) return;
              await Navigator.push(
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
            label: 'VAD',
            subLabel: 'Relevé de visite',
            onTap: () async {
              // Flush des éventuelles modifs en attente (debounce 400 ms
              // du Nom/Prénom/Adresse) AVANT de naviguer vers VAD —
              // sinon "Générer le rapport" depuis VAD pousserait un PDF
              // basé sur l'ancienne version NocoDB. Symptôme reporté :
              // "j'ai changé le nom en EVANS, le PDF affiche juste Joris"
              // → le _saveTimer n'avait pas encore tiré quand l'user a
              // cliqué Generate.
              await _flushPendingSave();

              // Prefer the in-shell navigation (callback) so the left
              // sidebar stays visible. Fallback to Navigator.push only if
              // the parent didn't wire a handler (isolated testing).
              if (widget.onOpenVisitReport != null) {
                widget.onOpenVisitReport!();
                return;
              }
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: VisitReportScreen(
                      dossier: widget.dossier,
                      onBack: () => Navigator.pop(context),
                    ),
                  ),
                ),
              );
              // On return from the visit report, re-read the patient row
              // so any change made there (firstName, lastName, city…) is
              // reflected in the "informations bénéficiaire" card here.
              await _refreshFromRepository();
            },
          ),
        ),
        ],
      ),
    );
  }

  /// Re-reads the patient row from SQLite and hydrates the local form
  /// state. Called on return from the visit report so edits made there
  /// propagate back to the dossier screen without requiring a full
  /// navigation refresh.
  ///
  /// Doubly-guarded contre l'écrasement des saisies en cours :
  ///   1. Si un `_saveTimer` est actif, l'utilisateur est en train de
  ///      taper — on skip pour ne PAS overwrite ses keystrokes en
  ///      vol.
  ///   2. Si le bénéficiaire local est marqué `pendingSync`, on skip
  ///      aussi : un push NocoDB est en cours et la valeur fraîche
  ///      retournée par fetchDossierById pourrait représenter
  ///      l'ancienne version remote (eventual consistency NocoDB) —
  ///      on l'écraserait par-dessus la valeur locale qui est en
  ///      réalité la plus récente.
  Future<void> _refreshFromRepository() async {
    if (!mounted) return;
    if (_saveTimer?.isActive == true) return;
    final fresh = await _repository.fetchDossierById(widget.dossier.id);
    if (fresh == null || !mounted) return;
    // Garde supplémentaire : ne pas overwrite si la modification
    // locale n'est pas encore confirmée par NocoDB. On compare le
    // payload qu'on vient de fetcher au state local pour les champs
    // de saisie : si différent, c'est qu'une saisie est en cours
    // (ou en attente de sync), on garde le local.
    final hasUnsyncedTextEdits = fresh.patient.firstName != _firstName ||
        fresh.patient.lastName != _lastName ||
        fresh.patient.address != _address ||
        fresh.patient.city != _city ||
        fresh.patient.zipCode != _zipCode;
    if (hasUnsyncedTextEdits) {
      // L'utilisateur a des modifications locales différentes du
      // payload — on garde son state local, on n'overwrite pas.
      return;
    }
    setState(() {
      _firstName = fresh.patient.firstName;
      _lastName = fresh.patient.lastName;
      _city = fresh.patient.city;
      _zipCode = fresh.patient.zipCode;
      _cityId = fresh.patient.cityId;
      _incomeCategory = fresh.patient.incomeCategory;
      _natureAccompagnement = fresh.natureAccompagnement;
      _fiscalRevenue = _householdFiscalRevenue(fresh.patient);
      final n = fresh.patient.numberPeople ?? 0;
      if (n <= 0) {
        _numberPeople = '1';
      } else if (n >= 5) {
        _numberPeople = '5';
      } else {
        _numberPeople = n.toString();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Info Card — strict React parity
  // ---------------------------------------------------------------------------
  Widget _buildInfoCard() {
    // Nouveau layout (parité maquette utilisateur) :
    //   - Bandeau violet clair en haut : icône + "Bénéficiaire" + crayon.
    //   - Corps en texte brut : labels violets + valeurs sans fond ni
    //     contour (les champs non modifiables sont du pur texte).
    //   - Ordre : Nom, Prénom, Occupants, RFR du foyer, Adresse,
    //     badge communauté de communes, Commentaire du projet.
    final streetAddress = widget.dossier.patient.address.trim();
    // Fallback en 3 étapes (parité avec DossiersListScreen._communeFor) :
    //   1. match strict par cityId
    //   2. match par label (nom de ville insensible à la casse)
    //   3. match par code postal
    // Nécessaire car certaines données NocoDB historiques ont un cityId
    // manquant ou désynchronisé (ex : Roche aux Fées, St Méen…).
    final epciLabel = _resolveEpciLabel(
      cityId: _cityId,
      city: _city,
      zipCode: _zipCode,
    );
    final fullAddress = _formatFullAddress(streetAddress, _zipCode, _city);

    // Couleurs du bandeau bénéficiaire — animées selon l'état
    // « préparé » du dossier (demande utilisateur 2026-05-05). Quand
    // coché : fond violet foncé + texte/icônes en violet clair.
    // Quand non coché : fond violet clair + texte/icônes en violet
    // foncé (look historique).
    final bannerBg = _beneficiaryPrepared
        ? const Color(0xFF554265) // violet foncé
        : const Color(0xFFEDE8F5); // violet clair
    final bannerFg = _beneficiaryPrepared
        ? const Color(0xFFEDE8F5) // violet clair (texte sur fond foncé)
        : const Color(0xFF554265); // violet foncé (texte sur fond clair)
    final bannerAccent = _beneficiaryPrepared
        ? const Color(0xFFEDE8F5)
        : const Color(0xFF8B6FA0);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bandeau violet clair / foncé (animé) ---
          AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            color: bannerBg,
            child: Row(
              children: [
                Icon(LucideIcons.user, color: bannerAccent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    // On part du style ambiant pour préserver la
                    // fontFamily Quicksand héritée du thème. Sans ce
                    // merge, AnimatedDefaultTextStyle écraserait le
                    // DefaultTextStyle ambiant et le Text retomberait
                    // sur Roboto. Demande utilisateur 2026-05-13 : « il
                    // ne faut absolument pas de Roboto ».
                    style: DefaultTextStyle.of(context).style.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: bannerFg,
                        ),
                    child: const Text(
                      'Bénéficiaire',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                SaveStatusIndicator(saving: _saving),
                const SizedBox(width: 6),
                // Bouton check entouré : toggle « bénéficiaire préparé ».
                // Demande utilisateur 2026-05-05 : à côté du crayon.
                // Quand coché → bandeau passe en violet foncé (animation
                // ci-dessus). L'icône elle-même change : cercle vide →
                // cercle plein avec check.
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () async {
                    final next = !_beneficiaryPrepared;
                    setState(() => _beneficiaryPrepared = next);
                    // Notifie le parent IMMÉDIATEMENT (avant l'await
                    // SQLite) pour que la bordure verte/jaune dans
                    // « Mes dossiers » réponde instantanément, sans
                    // attendre la persistance ni un refresh sync.
                    widget.onBeneficiaryPreparedChanged
                        ?.call(widget.dossier.id, next);
                    try {
                      await DataService().setBeneficiaryPrepared(
                        dossierLocalId: widget.dossier.id,
                        prepared: next,
                      );
                    } catch (_) {
                      // Échec persistance : revert UI + parent
                      if (mounted) {
                        setState(() => _beneficiaryPrepared = !next);
                      }
                      widget.onBeneficiaryPreparedChanged
                          ?.call(widget.dossier.id, !next);
                    }
                  },
                  child: Tooltip(
                    message: _beneficiaryPrepared
                        ? 'Marquer comme non préparé'
                        : 'Marquer comme préparé',
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      child: Icon(
                        _beneficiaryPrepared
                            ? LucideIcons.checkCircle2
                            : LucideIcons.circle,
                        size: 20,
                        color: bannerAccent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    if (!_isBeneficiaryLocked) {
                      _saveTimer?.cancel();
                      _save();
                    }
                    setState(() {
                      _isBeneficiaryLocked = !_isBeneficiaryLocked;
                    });
                  },
                  child: Tooltip(
                    message: _isBeneficiaryLocked ? 'Modifier' : 'Valider',
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      child: Icon(
                        _isBeneficiaryLocked
                            ? LucideIcons.pencil
                            : LucideIcons.check,
                        size: 18,
                        color: bannerAccent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // --- Corps : champs en texte brut (mode lecture) ou FormTextField
          //     (mode édition quand l'utilisateur a cliqué sur le crayon).
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isBeneficiaryLocked) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _PlainField(
                            label: 'Nom',
                            value: _lastName.trim().isEmpty
                                ? '—'
                                : _lastName,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _PlainField(
                            label: 'Prénom',
                            value: _firstName.trim().isEmpty
                                ? '—'
                                : _firstName,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _PlainField(
                            label: 'Occupants',
                            value: _numberPeople == '1'
                                ? '1'
                                : _numberPeople,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _PlainField(
                            label: 'RFR du foyer',
                            value: _formatFiscalRevenue(_fiscalRevenue),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _PlainField(
                      label: 'Adresse',
                      value:
                          fullAddress.isEmpty ? 'Non renseignée' : fullAddress,
                      multiline: true,
                    ),
                    // Section "Communauté de communes" — réservée dès qu'on
                    // a une commune (cityId ou ville ou code postal). Sans
                    // ça le badge "apparaissait après" le reste du dossier
                    // sur iPad PWA cold start, parce que `_communeOptions`
                    // est peuplé seulement quand `/api/references` répond.
                    // Maintenant on rend la section dans le flux normal et
                    // on remplace le badge par un skeleton pendant le
                    // chargement — pas de décalage visuel ni d'apparition
                    // tardive.
                    if (_hasCityInfo()) ...[
                      const SizedBox(height: 16),
                      // Libellé + badge communauté de communes. Même style
                      // de label violet que les autres champs du bloc
                      // Bénéficiaire en preview (`_PlainField` → 14 px,
                      // w700) — le badge pastel est juste en dessous.
                      const Text(
                        'Communauté de communes',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF8B6FA0),
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (epciLabel.isNotEmpty)
                        // Variante "large" du widget partagé : padding
                        // 16×9 + fontSize 14 → mieux proportionné à
                        // côté de l'adresse de la preview Bénéficiaire.
                        // La liste "Mes dossiers" garde la taille par
                        // défaut (12×6, fontSize 12).
                        EpciBadge(label: epciLabel, large: true)
                      else if (!_references.isLoaded)
                        // Skeleton aux mêmes dimensions que le badge
                        // pour que la mise en page reste stable pendant
                        // que `/api/references` répond.
                        const _EpciBadgeSkeleton()
                      else
                        // Références chargées mais aucun match (commune
                        // inconnue ou EPCI manquant côté NocoDB) —
                        // affichage discret au lieu d'un blanc.
                        const Text(
                          '—',
                          style: TextStyle(
                            fontSize: 14,
                            // Bumpé w400 → w500 (uniformisation 2026-05-13).
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                    ],
                    // "Commentaire du projet" retiré du bloc Bénéficiaire
                    // (demande utilisateur) : s'il existe, il est affiché
                    // par défaut dans la note rapide en haut à droite.
                  ] else ...[
                    // --- Mode édition : libellés violets conservés même
                    // quand les champs deviennent modifiables (demande
                    // utilisateur : pas de changement de couleur entre
                    // lecture et édition).
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: FormTextField(
                            label: 'Nom',
                            value: _lastName,
                            labelColor: const Color(0xFF8B6FA0),
                            labelSize: 14,
                            valueSize: 14,
                            onChanged: (v) {
                              _lastName = v;
                              _onTextChanged();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FormTextField(
                            label: 'Prénom',
                            value: _firstName,
                            labelColor: const Color(0xFF8B6FA0),
                            labelSize: 14,
                            valueSize: 14,
                            onChanged: (v) {
                              _firstName = v;
                              _onTextChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildOccupantsDropdown()),
                        const SizedBox(width: 12),
                        Expanded(
                          // RFR du foyer : modifiable en édition (demande
                          // utilisateur). Écrit vers patient.fiscal_revenue
                          // via `_save` — écrase l'éventuelle somme
                          // calculée depuis les occupants.
                          child: FormNumberField(
                            label: 'RFR du foyer',
                            value: _fiscalRevenue,
                            unit: '€',
                            labelColor: const Color(0xFF8B6FA0),
                            labelSize: 14,
                            valueSize: 14,
                            onChanged: (v) {
                              _fiscalRevenue = v;
                              _onIncomeAffectingChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Adresse (rue / n°) — modifiable directement depuis
                    // ce bloc. La ville et le code postal sont sur la
                    // ligne suivante (CommuneFieldGroup avec showZipField).
                    FormTextField(
                      label: 'Adresse',
                      value: _address,
                      labelColor: const Color(0xFF8B6FA0),
                      labelSize: 14,
                      valueSize: 14,
                      onChanged: (v) {
                        _address = v;
                        _onTextChanged();
                      },
                    ),
                    const SizedBox(height: 12),
                    CommuneFieldGroup(
                      city: _city,
                      zipCode: _zipCode,
                      cityId: _cityId,
                      options: _communeOptions,
                      // Code postal éditable lui aussi → l'ergo peut
                      // corriger une commune mal résolue sans repasser
                      // par le relevé de visite.
                      showZipField: true,
                      labelColor: const Color(0xFF8B6FA0),
                      labelSize: 14,
                      valueSize: 14,
                      onChanged: (update) {
                        setState(() {
                          if (update.city != null) _city = update.city!;
                          if (update.zipCode != null) {
                            _zipCode = update.zipCode!;
                          }
                          if (update.cityId != null) {
                            _cityId = update.cityId!;
                          }
                        });
                        _scheduleSave();
                      },
                    ),
                    // "Commentaire du projet" retiré — déplacé vers la
                    // note rapide en haut à droite (demande utilisateur).
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Combine adresse rue + code postal + ville en deux lignes distinctes :
  ///   ligne 1 : rue
  ///   ligne 2 : code postal ville
  /// Utilise un retour-chariot pour la coupure — le widget _PlainField
  /// est en `multiline: true` → Flutter respecte les `\n`.
  String _formatFullAddress(String street, String zip, String city) {
    final parts = <String>[];
    if (street.trim().isNotEmpty) parts.add(street.trim());
    final cityLine = [zip.trim(), city.trim()]
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (cityLine.isNotEmpty) parts.add(cityLine);
    return parts.join('\n');
  }

  /// Résout le libellé EPCI pour l'adresse du bénéficiaire en tentant
  /// trois stratégies successives (cityId exact → nom insensible à la
  /// casse → code postal). Retourne une chaîne vide si aucun match.
  ///
  /// Motif : certaines communes (Roche aux Fées, St Méen Montauban,
  /// Brocéliande…) ont un `cityId` vide ou obsolète sur des dossiers
  /// créés avant la synchronisation NocoDB — sans fallback on perdait
  /// l'affichage du badge EPCI pour ces dossiers-là.
  /// Vrai dès qu'une info de localisation est saisie sur le dossier.
  /// Utilisé pour décider si on RÉSERVE la place du badge "Communauté
  /// de communes" dans la preview du bloc Bénéficiaire — même si
  /// `_resolveEpciLabel` n'a pas encore résolu (références en cours
  /// de chargement).
  bool _hasCityInfo() {
    return _cityId.trim().isNotEmpty ||
        _city.trim().isNotEmpty ||
        _zipCode.trim().isNotEmpty;
  }

  String _resolveEpciLabel({
    required String cityId,
    required String city,
    required String zipCode,
  }) {
    if (_communeOptions.isEmpty) return '';
    final trimmedId = cityId.trim();
    final lowerCity = city.trim().toLowerCase();
    final trimmedZip = zipCode.trim();

    // 1. cityId exact
    if (trimmedId.isNotEmpty) {
      for (final c in _communeOptions) {
        if (c.id == trimmedId) return (c.epciLabel ?? '').trim();
      }
    }
    // 2. nom de ville (insensible à la casse)
    if (lowerCity.isNotEmpty) {
      for (final c in _communeOptions) {
        if (c.label.toLowerCase() == lowerCity) {
          return (c.epciLabel ?? '').trim();
        }
      }
    }
    // 3. code postal
    if (trimmedZip.isNotEmpty) {
      for (final c in _communeOptions) {
        if (c.zipCode == trimmedZip) return (c.epciLabel ?? '').trim();
      }
    }
    return '';
  }

  Widget _buildOccupantsDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Occupants',
          // Libellé violet 14px, aligné sur les autres labels du bloc
          // Bénéficiaire (FormTextField.labelSize = 14, valueSize = 14
          // pour matcher la preview où libellé violet et valeur noire
          // ont la même taille).
          // Bumpé w600 → w700 pour uniformiser avec les labels du
          // relevé de visite (demande utilisateur 2026-05-13).
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Color(0xFF8B6FA0),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _occupantOptions.contains(_numberPeople)
                  ? _numberPeople
                  : '1',
              items: _occupantOptions
                  .map((opt) => DropdownMenuItem<String>(
                        value: opt,
                        child: Text(
                          opt == '1' ? '1 occupant' : '$opt occupants',
                          // Bumpé w400 (défaut) → w600 pour rester
                          // aligné sur l'épaisseur des autres valeurs
                          // du bloc Bénéficiaire (demande user 2026-05-13).
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _numberPeople = v);
                // Dropdown selection is a single, deliberate action : no
                // typing debounce needed, save immediately so the visit
                // report and the sync engine see the new count at once.
                _saveTimer?.cancel();
                _save();
              },
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right column: Notes
  // ---------------------------------------------------------------------------
  Widget _buildNotesColumn() {
    return NotesWidget(
      patientId: widget.dossier.patient.id,
      tabKey: 'notes_rapides',
      sharedText: true,
      allowTextModal: false,
      // Nouvelle mise en page "deux cartes empilées" — texte en haut,
      // canvas en bas avec pagination flottante en haut-droite et
      // toolbar en bas-centre. Mise en cohérence visuelle avec les
      // notes du relevé de visite.
      stackedCards: true,
      allowPagination: true,
      fillParentHeight: true,
      // Autosave debounced → pas de bouton Save explicite (design épuré).
      showSaveButton: false,
      // Jeton bumped dès que la note rapide a été hydratée avec le
      // commentaire projet → force NotesWidget à re-fetch la page 0
      // et afficher le commentaire juste après l'ouverture du dossier.
      externalRefreshToken: _quickNoteRefreshToken,
    );
  }
}

// -----------------------------------------------------------------------------
// Helper widgets
// -----------------------------------------------------------------------------

/// Champ en texte brut (label violet + valeur slate) — pas de fond, pas
/// de bordure, pas de coins arrondis. Utilisé dans le bloc "Bénéficiaire"
/// pour afficher les champs non modifiables (demande utilisateur).
class _PlainField extends StatelessWidget {
  final String label;
  final String value;
  final bool multiline;

  const _PlainField({
    required this.label,
    required this.value,
    this.multiline = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          // Titre violet à la même taille que la valeur noire dessous
          // (14 px) pour équilibrer la lecture du bloc Bénéficiaire en
          // preview — demande utilisateur.
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8B6FA0),
            letterSpacing: 0.2,
          ),
        ),
        // Gap respiré entre le titre violet et la valeur — uniquement
        // en preview (quand le bloc Bénéficiaire est verrouillé).
        const SizedBox(height: 10),
        Text(
          value,
          maxLines: multiline ? null : 1,
          overflow: multiline ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF0F172A),
            height: multiline ? 1.4 : 1.2,
          ),
        ),
      ],
    );
  }
}

/// Petite pastille "communauté de communes" pour le bloc Bénéficiaire.
// (Ancien _EpciPillSmall + palette locale supprimés — le bloc
// Bénéficiaire utilise désormais le widget partagé `EpciBadge` de
// `beneficiary_palettes.dart`, identique à celui de la liste "Mes
// dossiers". Une seule source de vérité pour le visuel des EPCI.)

// Anciens widgets _ReadonlyField / _IncomeBadge et helpers _sync*
// retirés : le header du dossier et le bloc Bénéficiaire utilisent
// désormais _PlainField + _AccompanimentBadge + _IncomeCategoryBadge
// (mise en cohérence avec la maquette utilisateur, pas de badge de sync
// dans l'en-tête).

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
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFEDE8F5),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Icon(icon, color: const Color(0xFF8B6FA0)),
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
              // Sub-label des quick action buttons bumpé w400 → w500
              // pour rester lisible avec l'épaisseur générale du
              // dossier (demande user 2026-05-13).
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton pour le badge "Communauté de communes" pendant que les
/// références sont en train de charger. Mêmes dimensions que le badge
/// "large" (`EpciBadge(large: true)`) — padding 16×9, fontSize 14 —
/// pour que la mise en page de la preview Bénéficiaire ne saute pas
/// quand le vrai badge prend la place.
class _EpciBadgeSkeleton extends StatelessWidget {
  const _EpciBadgeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      // 14 (fontSize) × 1.2 (line-height) ≈ 17 px texte + 9×2 padding
      // vertical = 35 px. Match `EpciBadge(large: true)`.
      height: 35,
      decoration: BoxDecoration(
        color: const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}
