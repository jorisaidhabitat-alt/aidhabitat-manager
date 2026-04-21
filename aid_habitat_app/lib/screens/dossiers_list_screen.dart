import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../services/references_service.dart';

class DossiersListScreen extends StatefulWidget {
  final List<Dossier> dossiers;
  final Function(Dossier) onSelectDossier;
  final VoidCallback? onCreateNew;

  const DossiersListScreen({
    super.key,
    required this.dossiers,
    required this.onSelectDossier,
    this.onCreateNew,
  });

  @override
  State<DossiersListScreen> createState() => _DossiersListScreenState();
}

class _DossiersListScreenState extends State<DossiersListScreen> {
  final ReferencesService _references = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refsSub;

  String _searchTerm = '';
  String _sortOrder = 'asc'; // asc, desc
  String? _selectedEpciId; // null = "Toutes"
  String _selectedEpciLabel = 'Toutes les communautés';

  @override
  void initState() {
    super.initState();
    // Trigger a references load (communes + EPCI mapping). If already
    // loaded, this is a no-op.
    _references.ensureLoaded();
    _refsSub = _references.onLoaded.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refsSub?.cancel();
    super.dispose();
  }

  /// Resolves the EPCI commune-reference for a dossier by joining its
  /// patient.city on the NocoDB communes table. Prefers a match by
  /// cityId (precise), falls back on label then zipCode. Returns null
  /// if no match.
  CommuneRef? _communeFor(Dossier d) {
    if (!_references.isLoaded) return null;
    final cityId = d.patient.cityId.trim();
    final city = d.patient.city.trim().toLowerCase();
    final zip = d.patient.zipCode.trim();

    for (final ref in _references.communes) {
      if (cityId.isNotEmpty && ref.id == cityId) return ref;
    }
    for (final ref in _references.communes) {
      if (ref.label.toLowerCase() == city) return ref;
    }
    if (zip.isNotEmpty) {
      for (final ref in _references.communes) {
        if (ref.zipCode == zip) return ref;
      }
    }
    return null;
  }

  /// Convenience: EPCI label for display.
  String _epciFor(Dossier d) => _communeFor(d)?.epciLabel ?? '';

  /// EPCI id for filter matching.
  String _epciIdFor(Dossier d) => _communeFor(d)?.epciId ?? '';

  List<Dossier> get _filteredDossiers {
    List<Dossier> filtered = widget.dossiers.where((d) {
      // EPCI filter (only active when user picked a specific one).
      if (_selectedEpciId != null) {
        if (_epciIdFor(d) != _selectedEpciId) return false;
      }
      final term = _searchTerm.toLowerCase();
      if (term.isEmpty) return true;
      final haystack =
          '${d.patient.lastName} ${d.patient.firstName} ${d.patient.city} ${_epciFor(d)}'
              .toLowerCase();
      return haystack.contains(term);
    }).toList();

    if (_sortOrder == 'asc') {
      filtered.sort((a, b) => a.patient.lastName.compareTo(b.patient.lastName));
    } else if (_sortOrder == 'desc') {
      filtered.sort((a, b) => b.patient.lastName.compareTo(a.patient.lastName));
    }

    return filtered;
  }

  String get _sortLabel {
    switch (_sortOrder) {
      case 'asc':
        return 'de A à Z';
      case 'desc':
        return 'de Z à A';
      default:
        return 'de A à Z';
    }
  }

  /// Returns all distinct EPCIs that appear in the current dossiers' communes.
  /// Falls back on the full EPCI reference list if the dossiers don't match
  /// any commune yet (e.g. references still loading). Sorted alphabetically.
  List<EpciRef> get _availableEpcis {
    final seen = <String, EpciRef>{};
    for (final d in widget.dossiers) {
      final commune = _communeFor(d);
      if (commune == null) continue;
      if (commune.epciId.isEmpty) continue;
      seen.putIfAbsent(
        commune.epciId,
        () => EpciRef(id: commune.epciId, label: commune.epciLabel),
      );
    }
    // If nothing matched yet, expose the full EPCI ref list so the user
    // can at least browse them.
    final list = seen.values.toList();
    if (list.isEmpty) list.addAll(_references.epcis);
    list.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return list;
  }

  Future<void> _openEpciPicker() async {
    final selected = await showDialog<_EpciPickerResult>(
      context: context,
      builder: (ctx) => _EpciPickerDialog(
        epcis: _availableEpcis,
        currentEpciId: _selectedEpciId,
      ),
    );
    if (selected == null) return;
    setState(() {
      _selectedEpciId = selected.id;
      _selectedEpciLabel = selected.label;
    });
  }

  String _initials(Patient patient) {
    final f = patient.firstName.trim();
    final l = patient.lastName.trim();
    if (f.isEmpty && l.isEmpty) return '?';
    if (f.isEmpty) return l.substring(0, 1).toUpperCase();
    if (l.isEmpty) return f.substring(0, 1).toUpperCase();
    return '${f[0]}${l[0]}'.toUpperCase();
  }

  String _formatVisitDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    try {
      return DateFormat('dd/MM/yyyy').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                "Mes dossiers",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 24),

          // Controls
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9), // slate-100
                    borderRadius: BorderRadius.circular(32),
                  ),
                  child: TextField(
                    onChanged: (value) => setState(() => _searchTerm = value),
                    decoration: const InputDecoration(
                      hintText: "Rechercher...",
                      border: InputBorder.none,
                      suffixIcon: Icon(LucideIcons.search, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Theme(
                // Kill the default Material hover / splash highlight around
                // the dropdown trigger — the user wants the button to stay
                // flat-looking, no floating gray pill on hover.
                data: Theme.of(context).copyWith(
                  hoverColor: Colors.transparent,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                ),
                child: PopupMenuButton<String>(
                  tooltip: '',
                  onSelected: (value) => setState(() => _sortOrder = value),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9), // slate-100
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Row(
                      children: [
                      Text(
                        _sortLabel,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      const Icon(LucideIcons.chevronDown, size: 20),
                    ],
                  ),
                ),
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'asc', child: Text("de A à Z")),
                    const PopupMenuItem(value: 'desc', child: Text("de Z à A")),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // EPCI filter trigger: opens a searchable picker dialog.
              InkWell(
                onTap: _openEpciPicker,
                borderRadius: BorderRadius.circular(32),
                hoverColor: Colors.transparent,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(32),
                  ),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.mapPin,
                          size: 16, color: Color(0xFF64748B)),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          _selectedEpciLabel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(LucideIcons.chevronDown, size: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Main List Area
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // List
                  Expanded(
                    child: _filteredDossiers.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  LucideIcons.search,
                                  size: 48,
                                  color: Colors.grey.shade300,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  "Aucun dossier ne correspond à votre recherche.",
                                  style: TextStyle(color: Colors.grey.shade400),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _filteredDossiers.length,
                            itemBuilder: (context, index) {
                              final dossier = _filteredDossiers[index];
                              final visitDate =
                                  _formatVisitDate(dossier.visitDate);
                              final epci = _epciFor(dossier);
                              return InkWell(
                                onTap: () => widget.onSelectDossier(dossier),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFD8D0DC),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Center(
                                          child: Text(
                                            _initials(dossier.patient),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF554a63),
                                              fontSize: 18,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              "${dossier.patient.lastName} ${dossier.patient.firstName}",
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Row(
                                              children: [
                                                Icon(
                                                  LucideIcons.mapPin,
                                                  size: 14,
                                                  color: Colors.grey.shade500,
                                                ),
                                                const SizedBox(width: 4),
                                                Flexible(
                                                  child: Text(
                                                    dossier.patient.city,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      color:
                                                          Colors.grey.shade500,
                                                    ),
                                                  ),
                                                ),
                                                if (epci.isNotEmpty) ...[
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    width: 3,
                                                    height: 3,
                                                    decoration: BoxDecoration(
                                                      color: Colors
                                                          .grey.shade400,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Flexible(
                                                    child: Text(
                                                      epci,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: Colors
                                                            .grey.shade600,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            if (visitDate.isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  Icon(
                                                    LucideIcons.calendar,
                                                    size: 13,
                                                    color: const Color(
                                                        0xFF907CA1),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    "Visite : $visitDate",
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Color(0xFF907CA1),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: const BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          LucideIcons.arrowRight,
                                          size: 20,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pair carried back from the EPCI picker dialog. `id` null = "Toutes".
class _EpciPickerResult {
  const _EpciPickerResult({this.id, required this.label});
  final String? id;
  final String label;
}

/// Searchable picker for EPCIs ("communautés de commune"). Shows a
/// text field at the top + a scrollable list. Selecting an entry pops
/// the dialog with an [_EpciPickerResult].
class _EpciPickerDialog extends StatefulWidget {
  const _EpciPickerDialog({
    required this.epcis,
    required this.currentEpciId,
  });

  final List<EpciRef> epcis;
  final String? currentEpciId;

  @override
  State<_EpciPickerDialog> createState() => _EpciPickerDialogState();
}

class _EpciPickerDialogState extends State<_EpciPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<EpciRef> get _visibleEpcis {
    if (_query.isEmpty) return widget.epcis;
    return widget.epcis
        .where((e) => e.label.toLowerCase().contains(_query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleEpcis;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  const Text(
                    'Communauté de commune',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 20),
                    tooltip: 'Fermer',
                  ),
                ],
              ),
            ),

            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Rechercher une communauté…',
                    border: InputBorder.none,
                    prefixIcon: Icon(LucideIcons.search, size: 16),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // "Toutes" entry — always first, never filtered.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _EpciPickerTile(
                label: 'Toutes les communautés',
                selected: widget.currentEpciId == null,
                onTap: () => Navigator.of(context).pop(
                  const _EpciPickerResult(
                    id: null,
                    label: 'Toutes les communautés',
                  ),
                ),
              ),
            ),
            const Divider(height: 12),

            Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aucune communauté trouvée.',
                          style: TextStyle(color: Color(0xFF94A3B8)),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final epci = visible[index];
                        return _EpciPickerTile(
                          label: epci.label,
                          selected: widget.currentEpciId == epci.id,
                          onTap: () => Navigator.of(context).pop(
                            _EpciPickerResult(id: epci.id, label: epci.label),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpciPickerTile extends StatelessWidget {
  const _EpciPickerTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEDE9FE) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? const Color(0xFF6D28D9)
                      : const Color(0xFF334155),
                ),
              ),
            ),
            if (selected)
              const Icon(LucideIcons.check,
                  size: 18, color: Color(0xFF6D28D9)),
          ],
        ),
      ),
    );
  }
}

