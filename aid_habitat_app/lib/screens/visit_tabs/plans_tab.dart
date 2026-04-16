import 'package:flutter/material.dart';

import '../../components/notes_widget.dart';
import '../../models/types.dart';

class PlansTab extends StatelessWidget {
  final Dossier dossier;
  final String tabKey;

  const PlansTab({
    super.key,
    required this.dossier,
    required this.tabKey,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: NotesWidget(
        patientId: dossier.patient.id,
        tabKey: tabKey,
      ),
    );
  }
}
