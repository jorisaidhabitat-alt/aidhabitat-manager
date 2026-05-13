import 'package:flutter/material.dart';

import 'retirement_funds_principal_screen.dart';
import 'retirement_funds_screen.dart';

/// Page « Caisses » unifiée. Header :
///   - Titre changeant selon le mode :
///       • Complémentaires : "Caisses de retraite complémentaires"
///       • Principales     : "Caisses de retraite principales"
///   - À droite : switch « bundle » maison (radius forts, fond violet
///     clair, pas d'ombre — demande utilisateur 2026-05-13).
///
/// Sous le header : on embarque l'un des 2 écrans existants en mode
/// `showHeader: false` pour ne pas dupliquer le titre. Chaque écran
/// reste responsable de son fetch / cache / FAB d'ajout.
enum _CaisseMode { complementaires, principales }

class RetirementFundsCombinedScreen extends StatefulWidget {
  const RetirementFundsCombinedScreen({super.key});

  @override
  State<RetirementFundsCombinedScreen> createState() =>
      _RetirementFundsCombinedScreenState();
}

class _RetirementFundsCombinedScreenState
    extends State<RetirementFundsCombinedScreen> {
  // Mode par défaut = Complémentaires (demande utilisateur 2026-05-12).
  _CaisseMode _mode = _CaisseMode.complementaires;

  String _titleFor(_CaisseMode mode) => mode == _CaisseMode.principales
      ? 'Caisses de retraite principales'
      : 'Caisses de retraite complémentaires';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Header : titre à gauche, switch à droite ----
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  _titleFor(_mode),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Switch « bundle » maison : radius forts (pill), fond
              // violet clair pastel, pas d'ombre sur le thumb — demande
              // utilisateur 2026-05-13. Animé avec AnimatedAlign.
              SizedBox(
                width: 360,
                child: _CaissesSwitch(
                  value: _mode,
                  onChanged: (next) => setState(() => _mode = next),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ---- Contenu : écran embarqué (sans son propre header) ----
          // Le KeyedSubtree garantit qu'on rebuild un widget différent
          // (donc nouveau state, nouveau fetch) à chaque bascule.
          Expanded(
            child: _mode == _CaisseMode.complementaires
                ? const KeyedSubtree(
                    key: ValueKey('complementaires'),
                    child: RetirementFundsScreen(showHeader: false),
                  )
                : const KeyedSubtree(
                    key: ValueKey('principales'),
                    child: RetirementFundsPrincipalScreen(showHeader: false),
                  ),
          ),
        ],
      ),
    );
  }
}
