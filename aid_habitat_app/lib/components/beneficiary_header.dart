import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import 'beneficiary_badges.dart';

/// Header bénéficiaire partagé entre :
///   - `DossierScreen` (page dossier, avant d'aller en VAD ou Documents)
///   - `DocumentsScreen` (espace documents du bénéficiaire)
///   - `VisitReportScreen` (relevé de visite VAD)
///
/// Affiche dans l'ordre :
///   1. Bouton retour (chevron gauche 30×30 rounded-8 transparent)
///   2. NOM Prénom (Nunito 22px w600 ink-900, max 380pt + ellipsis)
///   3. Badge type d'accompagnement (AccompanimentBadge large)
///   4. Badge catégorie de revenu (IncomeCategoryBadge large, si non-vide)
///   5. Icône map-pin + adresse complète (rue · cp ville)
///   6. Badge statut ANAH à droite (AnahStatusBadge large, si non-vide)
///   7. Slot optionnel `trailing` (utilisé par VAD pour le bouton « Générer »)
///
/// Demande utilisateur 2026-05-15 : « la ligne qui apparait en haut du
/// relevé de visite doit apparaitre aussi en haut du dossier et de
/// l'espace documents — même couleur, même taille, même position ».
class BeneficiaryHeader extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  /// Widget optionnel à afficher tout à droite (après le badge Anah).
  /// Utilisé par le relevé de visite pour le bouton « Générer ».
  final Widget? trailing;

  const BeneficiaryHeader({
    super.key,
    required this.dossier,
    required this.onBack,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final patient = dossier.patient;
    final accompanimentLabel = formatAccompanimentType(
      dossier.natureAccompagnement,
    ).trim();
    final incomeLabel = patient.incomeCategory.trim();
    final addressLine = [
      patient.address.trim(),
      [
        patient.zipCode.trim(),
        patient.city.trim(),
      ].where((s) => s.isNotEmpty).join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');

    // Statut Anah parsé depuis le JSON compteAnah (cf.
    // beneficiary_tab._parseAnahData). Tolère le format legacy
    // « plain string » et la valeur historique « Mandat » (= pas de
    // statut associé).
    String anahStatus = '';
    final anahRaw = dossier.compteAnah.trim();
    if (anahRaw.isNotEmpty) {
      if (anahRaw.startsWith('{')) {
        try {
          final decoded = jsonDecode(anahRaw);
          if (decoded is Map) {
            anahStatus = (decoded['status']?.toString() ?? '').trim();
          }
        } catch (_) {
          /* laisse vide */
        }
      } else if (anahRaw != 'Mandat') {
        anahStatus = anahRaw;
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildBackButton(),
        const SizedBox(width: 16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // NOM Prénom — Nunito 22px w600, max 380pt avec ellipsis
              // si très long.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Text(
                  '${patient.lastName.toUpperCase()} ${patient.firstName}',
                  style: GoogleFonts.nunito(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                    color: const Color(0xFF0E1116),
                  ),
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              // Fallback "MPA complet" : même si le champ
              // `nature_accompagnement` est vide, on affiche le badge
              // avec le défaut.
              const SizedBox(width: 10),
              AccompanimentBadge(
                value: accompanimentLabel.isNotEmpty
                    ? accompanimentLabel
                    : 'MPA complet',
                rawType: dossier.natureAccompagnement.trim().isNotEmpty
                    ? dossier.natureAccompagnement
                    : 'complet',
                large: true,
              ),
              if (incomeLabel.isNotEmpty) ...[
                const SizedBox(width: 6),
                IncomeCategoryBadge(value: incomeLabel, large: true),
              ],
              if (addressLine.isNotEmpty) ...[
                const SizedBox(width: 12),
                const Icon(
                  LucideIcons.mapPin,
                  size: 18,
                  color: Color(0xFF8A939D), // ink-400
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    addressLine,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF5C6670), // ink-500
                    ),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (anahStatus.isNotEmpty) ...[
          const SizedBox(width: 12),
          AnahStatusBadge(status: anahStatus, large: true),
        ],
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }

  /// Bouton retour 30×30 rounded-8 avec fond permanent. Le fond reprend la
  /// couleur qui n'apparaissait auparavant qu'au survol.
  Widget _buildBackButton() {
    return Material(
      color: const Color(0xFFF2ECF5),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onBack,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: const Color(0xFFF2ECF5),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Icon(
            LucideIcons.chevronLeft,
            size: 16,
            color: Color(0xFF2B323A), // ink-700
          ),
        ),
      ),
    );
  }
}
