import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/commune_field_group.dart';
import '../components/form_widgets.dart';
import '../components/notes_widget.dart';
import '../models/types.dart';
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

  // Project comment (async-loaded)
  String _projectComment = '';
  bool _projectCommentLoaded = false;

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
      setState(() => _communeOptions = _mapCommunes());
    });

    _loadProjectComment();
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

  Future<void> _loadProjectComment() async {
    try {
      final obs = await _repository.fetchObservations(widget.dossier.id);
      if (!mounted) return;
      setState(() {
        _projectComment = obs?.projetSouhaitUsage ?? '';
        _projectCommentLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _projectCommentLoaded = true);
    }
  }

  @override
  void dispose() {
    _refSub?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    _scheduleSave();
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
      await _repository.updatePatientFields(widget.dossier.patient.id, {
        'first_name': _firstName,
        'last_name': _lastName,
        'number_people': numberPeopleInt,
        'city': _city,
        'zip_code': _zipCode,
        'city_id': _cityId,
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

  String _formatAccompanimentType(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'diagnostic':
        return 'Diagnostic ergo';
      case 'ergo':
        return 'Ergo';
      case 'complet':
        return 'Complet';
      default:
        return raw.trim();
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
            icon: LucideIcons.paperclip,
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
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: title + income category badge + save indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(LucideIcons.user,
                        color: Colors.grey, size: 20),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text(
                        'Bénéficiaire',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_formatAccompanimentType(_natureAccompagnement)
                        .trim()
                        .isNotEmpty) ...[
                      const SizedBox(width: 10),
                      _IncomeBadge(
                        value: _formatAccompanimentType(_natureAccompagnement),
                      ),
                    ],
                  ],
                ),
              ),
              SaveStatusIndicator(saving: _saving),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _isBeneficiaryLocked ? 'Modifier' : 'Valider',
                icon: Icon(
                  _isBeneficiaryLocked ? LucideIcons.pencil : LucideIcons.check,
                  size: 18,
                  color: const Color(0xFF64748B),
                ),
                splashRadius: 20,
                onPressed: () {
                  if (!_isBeneficiaryLocked) {
                    _saveTimer?.cancel();
                    _save();
                  }
                  setState(() {
                    _isBeneficiaryLocked = !_isBeneficiaryLocked;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Prénom + Nom (editable when unlocked)
                  if (_isBeneficiaryLocked)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ReadonlyField(
                            label: 'Prénom',
                            value: _firstName.trim().isEmpty
                                ? 'Non renseigné'
                                : _firstName,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ReadonlyField(
                            label: 'Nom',
                            value: _lastName.trim().isEmpty
                                ? 'Non renseigné'
                                : _lastName,
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: FormTextField(
                            label: 'Prénom',
                            value: _firstName,
                            onChanged: (v) {
                              _firstName = v;
                              _onChanged();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FormTextField(
                            label: 'Nom',
                            value: _lastName,
                            onChanged: (v) {
                              _lastName = v;
                              _onChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  // 2. Revenu fiscal de référence + Catégorie de revenu
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _ReadonlyField(
                          label: 'Revenu fiscal de référence',
                          value: _formatFiscalRevenue(_fiscalRevenue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ReadonlyField(
                          label: 'Catégorie de revenu',
                          value: _incomeCategory.trim().isEmpty
                              ? 'Non renseignée'
                              : _incomeCategory,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 3. Occupants + Ville (zip hidden)
                  if (_isBeneficiaryLocked)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _ReadonlyField(
                            label: 'Occupants',
                            value: _numberPeople == '1'
                                ? '1 occupant'
                                : '$_numberPeople occupants',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ReadonlyField(
                            label: 'Ville',
                            value: _city.trim().isEmpty
                                ? 'Non renseignée'
                                : _city,
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildOccupantsDropdown()),
                        const SizedBox(width: 12),
                        Expanded(
                          child: CommuneFieldGroup(
                            city: _city,
                            zipCode: _zipCode,
                            cityId: _cityId,
                            options: _communeOptions,
                            showZipField: false,
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
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  // 4. Commentaire projet (read-only, multiline)
                  _ReadonlyField(
                    label: 'Commentaire projet',
                    value: _projectCommentLoaded
                        ? (_projectComment.trim().isEmpty
                            ? 'Aucun commentaire renseigné'
                            : _projectComment)
                        : 'Chargement du commentaire…',
                    multiline: true,
                    compact: true,
                    muted: !_projectCommentLoaded ||
                        _projectComment.trim().isEmpty,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOccupantsDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Occupants',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
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
    );
  }
}

// -----------------------------------------------------------------------------
// Helper widgets
// -----------------------------------------------------------------------------

class _ReadonlyField extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasized;
  final bool multiline;
  final bool compact;
  final bool muted;

  const _ReadonlyField({
    required this.label,
    required this.value,
    this.emphasized = false,
    this.multiline = false,
    this.compact = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = emphasized ? const Color(0xFFF4EFF7) : const Color(0xFFF8FAFC);
    final borderColor =
        emphasized ? const Color(0xFFD8CFE0) : const Color(0xFFE2E8F0);
    final valueColor =
        muted ? const Color(0xFF94A3B8) : const Color(0xFF334155);

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
          constraints: multiline
              ? const BoxConstraints(maxHeight: 120)
              : const BoxConstraints(),
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: multiline
              ? SingleChildScrollView(
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 14,
                      color: valueColor,
                      height: 1.4,
                    ),
                  ),
                )
              : Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    color: valueColor,
                    fontWeight:
                        emphasized ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
        ),
      ],
    );
  }
}

class _IncomeBadge extends StatelessWidget {
  final String value;

  const _IncomeBadge({required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0F5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD8CFE0)),
      ),
      child: Text(
        value,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF554A63),
        ),
      ),
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
