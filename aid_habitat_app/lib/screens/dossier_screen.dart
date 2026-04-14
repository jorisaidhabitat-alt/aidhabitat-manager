import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../components/notes_widget.dart';
import 'documents_screen.dart';
import 'start_visit_screen.dart';

class DossierScreen extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const DossierScreen({super.key, required this.dossier, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: onBack,
                      borderRadius: BorderRadius.circular(50),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey.shade200),
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
                          "${dossier.patient.lastName.toUpperCase()} ${dossier.patient.firstName}",
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
                              "Dossier actif",
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
                                color: _syncBackground(dossier.syncState),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                dossier.syncState.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                  color: _syncForeground(dossier.syncState),
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
                      "Créé le",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    Text(
                      DateFormat(
                        'dd/MM/yyyy',
                      ).format(DateTime.parse(dossier.createdAt)),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Main Content
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Column: Info + Actions
                  Expanded(
                    flex: 5,
                    child: Column(
                      children: [
                        // Quick Actions
                        Row(
                          children: [
                            Expanded(
                              child: _QuickActionButton(
                                icon: LucideIcons.paperclip,
                                label: "Espace Documents",
                                subLabel: "Photos, scans, plans...",
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => DocumentsScreen(
                                        dossier: dossier,
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
                                label: "Visite Domicile",
                                subLabel: "Relevés, mesures, photos...",
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => StartVisitScreen(
                                        dossier: dossier,
                                        onBack: () => Navigator.pop(context),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Info Card
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      LucideIcons.user,
                                      color: Colors.grey,
                                    ),
                                    const SizedBox(width: 12),
                                    const Text(
                                      "Informations Bénéficiaire",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      children: [
                                        _InfoRow(
                                          icon: LucideIcons.user,
                                          label: "Identité",
                                          value:
                                              "${dossier.patient.firstName} ${dossier.patient.lastName}",
                                        ),
                                        const SizedBox(height: 24),
                                        _InfoRow(
                                          icon: LucideIcons.mapPin,
                                          label: "Adresse",
                                          value:
                                              "${dossier.patient.address}, ${dossier.patient.zipCode} ${dossier.patient.city}",
                                        ),
                                        const SizedBox(height: 24),
                                        _InfoRow(
                                          icon: LucideIcons.phone,
                                          label: "Contact",
                                          value: dossier.patient.phone,
                                        ),
                                        const SizedBox(height: 24),
                                        _InfoRow(
                                          icon: LucideIcons.calendar,
                                          label: "Né(e) le",
                                          value: DateFormat('dd/MM/yyyy')
                                              .format(
                                                DateTime.parse(
                                                  dossier.patient.birthDate,
                                                ),
                                              ),
                                        ),
                                        const SizedBox(height: 24),
                                        _InfoRow(
                                          icon: LucideIcons.activity,
                                          label: "Autonomie",
                                          value:
                                              dossier.autonomyNotes.length > 30
                                              ? "${dossier.autonomyNotes.substring(0, 30)}..."
                                              : dossier.autonomyNotes,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Divider(height: 48),
                                const Text(
                                  "Personne de confiance",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (dossier
                                    .patient
                                    .trustedPerson
                                    .name
                                    .isNotEmpty)
                                  Text(
                                    "${dossier.patient.trustedPerson.name} - ${dossier.patient.trustedPerson.phone}",
                                    style: const TextStyle(color: Colors.grey),
                                  )
                                else
                                  const Text(
                                    "Non renseigné",
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),

                  // Right Column: Notes
                  Expanded(
                    flex: 7,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(24),
                              topRight: Radius.circular(24),
                            ),
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFF1F5F9)),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Notes Rapides",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(50),
                                ),
                                child: const Text(
                                  "Sauvegarde auto",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: NotesWidget(
                            patientId: dossier.patient.id,
                            tabKey: 'notes_rapides',
                          ),
                        ),
                      ],
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
          border: Border.all(color: Colors.grey.shade200),
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

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Icon(icon, size: 16, color: Colors.grey.shade400),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade400,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
