import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';

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
  String _searchTerm = '';
  String? _selectedLetter;
  String _sortOrder = 'asc'; // asc, desc, random
  final List<String> _alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split('');

  List<Dossier> get _filteredDossiers {
    List<Dossier> filtered = widget.dossiers.where((d) {
      final matchesSearch =
          d.patient.lastName.toLowerCase().contains(
            _searchTerm.toLowerCase(),
          ) ||
          d.patient.city.toLowerCase().contains(_searchTerm.toLowerCase());
      final matchesLetter =
          _selectedLetter == null ||
          d.patient.lastName.toUpperCase().startsWith(_selectedLetter!) ||
          d.patient.firstName.toUpperCase().startsWith(_selectedLetter!);
      return matchesSearch && matchesLetter;
    }).toList();

    if (_sortOrder == 'asc') {
      filtered.sort((a, b) => a.patient.lastName.compareTo(b.patient.lastName));
    } else if (_sortOrder == 'desc') {
      filtered.sort((a, b) => b.patient.lastName.compareTo(a.patient.lastName));
    } else {
      filtered.shuffle();
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
        return 'Aléatoire';
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
              if (widget.onCreateNew != null)
                ElevatedButton.icon(
                  onPressed: widget.onCreateNew,
                  icon: const Icon(LucideIcons.plus, size: 18),
                  label: const Text('Nouveau'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF907CA1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(50),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    elevation: 0,
                  ),
                ),
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
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
                    value: 'random',
                    child: Text("Aléatoire"),
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
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Alphabet Bar
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Color(0xFFF1F5F9)),
                      ),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _alphabet.map((letter) {
                          final isSelected = _selectedLetter == letter;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: InkWell(
                              onTap: () => setState(
                                () => _selectedLetter = isSelected
                                    ? null
                                    : letter,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF907CA1)
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: const Color(
                                              0xFF907CA1,
                                            ).withOpacity(0.4),
                                            blurRadius: 8,
                                            offset: const Offset(0, 4),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Center(
                                  child: Text(
                                    letter,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.grey.shade500,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),

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
                              return InkWell(
                                onTap: () => widget.onSelectDossier(dossier),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.transparent,
                                    ),
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
                                            Row(
                                              children: [
                                                Icon(
                                                  LucideIcons.mapPin,
                                                  size: 14,
                                                  color: Colors.grey.shade500,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  dossier.patient.city,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    color: Colors.grey.shade500,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          _StatusPill(
                                            status: dossier.status.label,
                                          ),
                                          const SizedBox(height: 6),
                                          _SyncPill(
                                            syncState: dossier.syncState,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 24),
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.grey.shade200,
                                          ),
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

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color text;

    switch (status) {
      case 'Validé':
        bg = Colors.green.shade100;
        text = Colors.green.shade700;
        break;
      case 'À visiter':
        bg = Colors.amber.shade100;
        text = Colors.amber.shade700;
        break;
      default:
        bg = Colors.grey.shade100;
        text = Colors.grey.shade600;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: text,
        ),
      ),
    );
  }
}

class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.syncState});

  final SyncState syncState;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (syncState) {
      case SyncState.synced:
        color = Colors.green.shade600;
        break;
      case SyncState.pendingSync:
      case SyncState.localOnly:
      case SyncState.syncing:
        color = Colors.orange.shade600;
        break;
      case SyncState.syncError:
      case SyncState.conflict:
        color = Colors.red.shade600;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          syncState.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}
