import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';

class DocumentsScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const DocumentsScreen({
    super.key,
    required this.dossier,
    required this.onBack,
  });

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final DataService _dataService = DataService();
  String _searchTerm = '';
  bool _isLoading = true;
  bool _isImporting = false;
  List<DocItem> _documents = const [];

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  Future<void> _loadDocuments() async {
    final docs = await _dataService.fetchDocuments(widget.dossier.patient.id);
    if (!mounted) return;
    setState(() {
      _documents = docs;
      _isLoading = false;
    });

    final refreshed = await _dataService.refreshDocumentsFromRemote(
      widget.dossier.patient.id,
    );
    if (!refreshed) return;

    final remoteDocs = await _dataService.fetchDocuments(
      widget.dossier.patient.id,
    );
    if (!mounted) return;
    setState(() {
      _documents = remoteDocs;
    });
  }

  Future<void> _importDocument() async {
    setState(() => _isImporting = true);
    try {
      final result = await FilePicker.platform.pickFiles();
      final filePath = result?.files.single.path;
      if (filePath == null || filePath.isEmpty) {
        if (mounted) setState(() => _isImporting = false);
        return;
      }

      await _dataService.importDocument(
        patientId: widget.dossier.patient.id,
        filePath: filePath,
      );
      await _loadDocuments();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Document enregistré localement et ajouté à la file de synchronisation.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import impossible: $error')));
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  List<DocItem> get _filteredDocuments {
    if (_searchTerm.trim().isEmpty) return _documents;
    final query = _searchTerm.trim().toLowerCase();
    return _documents.where((doc) {
      return doc.title.toLowerCase().contains(query) ||
          doc.name.toLowerCase().contains(query) ||
          doc.tags.any((tag) => tag.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            Row(
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
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black87),
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
                          "${widget.dossier.patient.lastName.toUpperCase()} ${widget.dossier.patient.firstName}",
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        Text(
                          "Documents hors ligne • ${widget.dossier.syncState.label}",
                          style: TextStyle(
                            color: _syncColor(widget.dossier.syncState),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Container(
                  width: 320,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD8D0DC),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (value) =>
                              setState(() => _searchTerm = value),
                          decoration: const InputDecoration(
                            hintText: "Rechercher...",
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      const Icon(LucideIcons.search, color: Colors.black54),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : GridView.count(
                      crossAxisCount: 6,
                      crossAxisSpacing: 24,
                      mainAxisSpacing: 24,
                      childAspectRatio: 0.75,
                      children: [
                        InkWell(
                          onTap: _isImporting ? null : _importDocument,
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFF907CA1),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: _isImporting
                                  ? const CircularProgressIndicator()
                                  : const Icon(
                                      LucideIcons.plus,
                                      size: 48,
                                      color: Color(0xFF907CA1),
                                    ),
                            ),
                          ),
                        ),
                        ..._filteredDocuments.map((doc) => _DocCard(doc: doc)),
                        if (_filteredDocuments.isEmpty)
                          _EmptyState(searchTerm: _searchTerm),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocCard extends StatelessWidget {
  const _DocCard({required this.doc});

  final DocItem doc;

  @override
  Widget build(BuildContext context) {
    final createdAt =
        DateTime.tryParse(doc.date)?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final dateLabel = createdAt.millisecondsSinceEpoch == 0
        ? doc.date
        : DateFormat('dd/MM/yyyy').format(createdAt);

    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.grey.shade200),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: _SyncBadge(syncState: doc.syncState),
                ),
                const Spacer(),
                Center(
                  child: Icon(
                    _iconFor(doc.type),
                    size: 48,
                    color: Colors.grey.shade400,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          doc.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        Text(
          dateLabel,
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'image':
        return LucideIcons.image;
      case 'pdf':
        return LucideIcons.fileText;
      default:
        return LucideIcons.file;
    }
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.syncState});

  final SyncState syncState;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _syncColor(syncState).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        syncState.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: _syncColor(syncState),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searchTerm});

  final String searchTerm;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.search, size: 42, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                searchTerm.trim().isEmpty
                    ? 'Aucun document local pour ce dossier.'
                    : 'Aucun document ne correspond à votre recherche.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _syncColor(SyncState syncState) {
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
