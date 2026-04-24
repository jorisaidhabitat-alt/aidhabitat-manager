import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/beneficiary_badges.dart';
import '../components/commune_field_group.dart';
import '../components/form_widgets.dart';
import '../components/notes_widget.dart';
import '../models/types.dart';
import '../services/data_service.dart';
import '../services/dossier_repository.dart';
import '../services/references_service.dart';
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

  const DossierScreen({
    super.key,
    required this.dossier,
    required this.onBack,
    this.repository,
    this.onOpenVisitReport,
  });

  @override
  State<DossierScreen> createState() => _DossierScreenState();
}

class _DossierScreenState extends State<DossierScreen> {
  late final DossierRepository _repository;

  Timer? _saveTimer;
  bool _saving = false;
  bool _isBeneficiaryLocked = true;

  // Editable fields shown in the card
  late String _firstName;
  late String _lastName;
  late String _numberPeople; // dropdown value: '1'..'5' or '5+'
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
    _city = p.city;
    _zipCode = p.zipCode;
    _cityId = p.cityId;
    _incomeCategory = p.incomeCategory;
    _natureAccompagnement = widget.dossier.natureAccompagnement;
    _fiscalRevenue = _householdFiscalRevenue(p);

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
    _saveTimer?.cancel();
    super.dispose();
  }

  void _onChanged() {
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
    // 150 ms so the local SQLite write (and the refresh of dossier list /
    // dashboard / visit report header) is effectively instant. NocoDB
    // receives the push ~200 ms later via the SyncEngine debounce.
    _saveTimer = Timer(const Duration(milliseconds: 150), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final numberPeopleInt =
          int.tryParse(_numberPeople.replaceAll('+', '')) ?? 1;
      // Recompute une dernière fois juste avant le save (au cas où les
      // barèmes viennent d'arriver entre le onChange et le save).
      _recomputeIncomeCategory();
      await _repository.updatePatientFields(widget.dossier.patient.id, {
        'first_name': _firstName,
        'last_name': _lastName,
        'number_people': numberPeopleInt,
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

  /// Mirrors React's `formatAccompanimentType()`:
  ///  - `diagnostic` → "Diagnostic ergo"
  ///  - `ergo` → "Ergo"
  ///  - `complet` → "Complet"
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
              InkWell(
                onTap: widget.onBack,
                borderRadius: BorderRadius.circular(50),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    LucideIcons.arrowLeft,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  '${_lastName.toUpperCase()} $_firstName',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (accompanimentLabel.isNotEmpty) ...[
                const SizedBox(width: 12),
                AccompanimentBadge(value: accompanimentLabel),
              ],
              if (incomeLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                IncomeCategoryBadge(value: incomeLabel),
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
            label: 'VAD',
            subLabel: 'Relevés, mesures, photos...',
            onTap: () async {
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
  Future<void> _refreshFromRepository() async {
    if (!mounted) return;
    final fresh = await _repository.fetchDossierById(widget.dossier.id);
    if (fresh == null || !mounted) return;
    // Preserve in-flight edits: only copy fields that aren't currently
    // being typed (i.e. no pending save).
    if (_saveTimer?.isActive == true) return;
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

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Bandeau violet clair (icône + titre + save + crayon) ---
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            color: const Color(0xFFEDE8F5),
            child: Row(
              children: [
                const Icon(LucideIcons.user,
                    color: Color(0xFF7C6DAA), size: 20),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Bénéficiaire',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF554A63),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SaveStatusIndicator(saving: _saving),
                const SizedBox(width: 6),
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
                        color: const Color(0xFF7C6DAA),
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
                    if (epciLabel.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      // Libellé + badge communauté de communes. Même style
                      // de label que les autres champs (violet, w700, 12pt)
                      // — le badge pastel est juste en dessous.
                      const Text(
                        'Communauté de communes',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF7C6DAA),
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _EpciPillSmall(label: epciLabel),
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
                            labelColor: const Color(0xFF7C6DAA),
                            onChanged: (v) {
                              _lastName = v;
                              _onChanged();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FormTextField(
                            label: 'Prénom',
                            value: _firstName,
                            labelColor: const Color(0xFF7C6DAA),
                            onChanged: (v) {
                              _firstName = v;
                              _onChanged();
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
                            labelColor: const Color(0xFF7C6DAA),
                            onChanged: (v) {
                              _fiscalRevenue = v;
                              _onChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    CommuneFieldGroup(
                      city: _city,
                      zipCode: _zipCode,
                      cityId: _cityId,
                      options: _communeOptions,
                      showZipField: false,
                      labelColor: const Color(0xFF7C6DAA),
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
          // Libellé violet pour cohérence avec le reste du bloc
          // Bénéficiaire (demande utilisateur : labels violets en
          // lecture comme en édition).
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF7C6DAA),
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
                          style: const TextStyle(fontSize: 14),
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
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF7C6DAA),
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: multiline ? null : 1,
          overflow: multiline ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF0F172A),
            height: multiline ? 1.4 : 1.2,
          ),
        ),
      ],
    );
  }
}

/// Petite pastille "communauté de communes" pour le bloc Bénéficiaire.
/// Utilise la même palette pastel que `_EpciBadge` de la liste des
/// dossiers (cohérence visuelle entre la liste et le détail d'un
/// dossier — demande utilisateur : fonds pastel uniquement, texte
/// slate foncé pour la lisibilité).
class _EpciPillSmall extends StatelessWidget {
  final String label;
  const _EpciPillSmall({required this.label});

  @override
  Widget build(BuildContext context) {
    final bg = _pastelEpciBgFor(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF334155),
        ),
      ),
    );
  }
}

/// Palette "Équilibrée" partagée entre la liste des dossiers et le
/// détail Bénéficiaire — même hash → même couleur pour un EPCI donné.
/// 5 tons pastel doux pour éviter le code couleur clinique.
const List<Color> _kPastelEpciBgs = [
  Color(0xFFC8E6D0), // mint
  Color(0xFFF5D6B8), // pêche
  Color(0xFFD9EAF3), // ciel
  Color(0xFFE8E2F0), // lavande
  Color(0xFFF0E4CC), // sable
];

/// Hachage déterministe label → couleur de fond pastel.
Color _pastelEpciBgFor(String label) {
  if (label.isEmpty) return const Color(0xFFF1F5F9);
  int hash = 0;
  for (final rune in label.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  return _kPastelEpciBgs[hash % _kPastelEpciBgs.length];
}

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
              child: Icon(icon, color: const Color(0xFF7C6DAA)),
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
