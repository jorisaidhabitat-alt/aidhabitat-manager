import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../components/notes_widget.dart';

class PlansTab extends StatefulWidget {
  final Dossier dossier;

  const PlansTab({super.key, required this.dossier});

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            'Plans de visite',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF334155),
            ),
          ),
        ),
        Expanded(
          child: NotesWidget(
            patientId: widget.dossier.patient.id,
            tabKey: 'Plans',
          ),
        ),
      ],
    );
  }
}
