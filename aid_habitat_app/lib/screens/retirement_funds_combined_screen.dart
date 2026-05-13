import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
                    fontWeight: FontWeight.w600,
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

/// Switch « bundle » 2 positions, sans dépendance Cupertino, pour
/// pouvoir contrôler radius / couleur de fond / absence d'ombre.
/// — Fond violet pastel (#EDE8F5)
/// — Thumb blanc avec radius forts (pill)
/// — Aucune ombre (BoxShadow vide)
/// — Animation 220 ms en easeOutCubic via AnimatedAlign.
class _CaissesSwitch extends StatelessWidget {
  const _CaissesSwitch({required this.value, required this.onChanged});

  final _CaisseMode value;
  final ValueChanged<_CaisseMode> onChanged;

  static const Color _bgColor = Color(0xFFEDE8F5); // violet clair pastel
  static const Color _thumbColor = Colors.white;
  static const Color _textColor = Color(0xFF0F172A);

  @override
  Widget build(BuildContext context) {
    const double height = 44;
    const double innerPadding = 4;
    const double innerHeight = height - innerPadding * 2; // 36

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(innerPadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double thumbWidth = constraints.maxWidth / 2;
          return Stack(
            children: [
              // Thumb animé — pas d'ombre.
              AnimatedAlign(
                alignment: value == _CaisseMode.complementaires
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: Container(
                  width: thumbWidth,
                  height: innerHeight,
                  decoration: BoxDecoration(
                    color: _thumbColor,
                    borderRadius: BorderRadius.circular(18),
                    // Pas de boxShadow — demande utilisateur.
                  ),
                ),
              ),
              // Labels cliquables.
              Row(
                children: [
                  Expanded(
                    child: _SwitchSegment(
                      label: 'Complémentaires',
                      onTap: () => onChanged(_CaisseMode.complementaires),
                    ),
                  ),
                  Expanded(
                    child: _SwitchSegment(
                      label: 'Principales',
                      onTap: () => onChanged(_CaisseMode.principales),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SwitchSegment extends StatelessWidget {
  const _SwitchSegment({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _CaissesSwitch._textColor,
          ),
        ),
      ),
    );
  }
}
