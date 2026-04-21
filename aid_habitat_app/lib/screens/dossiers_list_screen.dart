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
  String _sortOrder = 'asc'; // asc, desc, epci

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

  /// Resolves the EPCI ("communauté de commune") label for a dossier by
  /// joining its patient.city on the NocoDB communes table. Prefers a
  /// match by cityId (precise), falls back on label (case-insensitive).
  /// Returns empty string if no match.
  String _epciFor(Dossier d) {
    if (!_references.isLoaded) return '';
    final cityId = d.patient.cityId.trim();
    final city = d.patient.city.trim().toLowerCase();
    final zip = d.patient.zipCode.trim();

    for (final ref in _references.communes) {
      if (cityId.isNotEmpty && ref.id == cityId) return ref.epciLabel;
    }
    for (final ref in _references.communes) {
      if (ref.label.toLowerCase() == city) return ref.epciLabel;
    }
    if (zip.isNotEmpty) {
      for (final ref in _references.communes) {
        if (ref.zipCode == zip) return ref.epciLabel;
      }
    }
    return '';
  }

  List<Dossier> get _filteredDossiers {
    List<Dossier> filtered = widget.dossiers.where((d) {
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
    } else if (_sortOrder == 'epci') {
      filtered.sort((a, b) {
        final epciA = _epciFor(a);
        final epciB = _epciFor(b);
        // Empty EPCI goes last so user-visible sort starts with real EPCI.
        if (epciA.isEmpty && epciB.isEmpty) {
          return a.patient.lastName.compareTo(b.patient.lastName);
        }
        if (epciA.isEmpty) return 1;
        if (epciB.isEmpty) return -1;
        final cmp = epciA.toLowerCase().compareTo(epciB.toLowerCase());
        if (cmp != 0) return cmp;
        return a.patient.lastName.compareTo(b.patient.lastName);
      });
    }

    return filtered;
  }

  String get _sortLabel {
    switch (_sortOrder) {
      case 'asc':
        return 'de A à Z';
      case 'desc':
        return 'de Z à A';
      case 'epci':
        return 'Par communauté de commune';
      default:
        return 'de A à Z';
    }
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
              PopupMenuButton<String>(
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
                  const PopupMenuItem(
                    value: 'epci',
                    child: Text("Par communauté de commune"),
                  ),
                ],
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

