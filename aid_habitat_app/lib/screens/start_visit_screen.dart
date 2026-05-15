import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../components/brand_colors.dart';
import '../models/types.dart';
import 'visit_report_screen.dart';
import 'package:lucide_icons/lucide_icons.dart';

class StartVisitScreen extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const StartVisitScreen({
    super.key,
    required this.dossier,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Back Button
          Positioned(
            top: 32,
            left: 32,
            child: Row(
              children: [
                // Bouton retour aligné sur celui du VAD (uniformisation
                // 2026-05-13) : 44×44 transparent, chevronLeft 24px
                // ink-700.
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onBack,
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${dossier.patient.lastName.toUpperCase()} ${dossier.patient.firstName}",
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const Text("Visite à domicile", style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
          
          // Center Content
          Center(
            child: Container(
              width: 600,
              height: 400,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Color(0xFFE4E7EB)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "Génération de prise de relevés pour",
                    style: TextStyle(fontSize: 18, color: Colors.black54),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    "${dossier.patient.lastName.toUpperCase()} ${dossier.patient.firstName}",
                    // Refonte 2026-05-13 : Nunito w600 — uniforme avec
                    // les autres titres de page.
                    style: GoogleFonts.nunito(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dossier.patient.address,
                    style: const TextStyle(fontSize: 18, color: Colors.black54),
                  ),
                  const SizedBox(height: 48),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => Scaffold(
                            body: VisitReportScreen(
                              dossier: dossier,
                              onBack: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kBrandPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                      textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      elevation: 0,
                    ),
                    child: const Text("C'est parti"),
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
