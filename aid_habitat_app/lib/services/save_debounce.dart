/// Constantes de debounce des saves côté visit-report et dossier_screen.
///
/// **Pourquoi centraliser** : avant cette unification, chaque onglet
/// définissait sa propre valeur (100ms / 150ms / 400ms / 2000ms), ce
/// qui créait des races offline quand 2 onglets éditaient des champs
/// chevauchants (ex: Nom dans Bénéficiaire **et** Nom dans
/// dossier_screen).
///
/// **Règle finale** (demande utilisateur — « le changement doit être
/// instantané, pas d'attente ») :
///   - Texte saisi (Nom, Prénom, Adresse, observations…) → **0 ms**.
///     Chaque keystroke écrit immédiatement en SQLite et enqueue la
///     sync_op. Le SyncEngine debounce déjà à 200ms en interne avant
///     de pousser à NocoDB, donc on ne spamme pas le réseau pour
///     autant. Le ConflictAlgorithm.replace dans
///     `dossier_repository.updatePatient` collapse les sync_ops
///     successives en une seule.
///   - Toggle / pills / dropdowns → 2000 ms. Les sélections sont
///     délibérées et espacées, on peut amortir les saves pour limiter
///     les allers-retours réseau pendant la saisie d'une checklist.
///
/// Évolutions possibles :
///   - Si SQLite devient lent sur iPad anciens (15+), bumper à 50 ms
///     pour éviter les frame drops pendant une frappe rapide.
///   - Mais 0 ms reste l'objectif — c'est le seul moyen d'avoir des
///     vues qui sont synchrones avec ce que le user vient de taper.
library;

import 'dart:async';

/// Debounce pour les champs où l'utilisateur tape du texte au clavier.
/// **Zero** par demande utilisateur : chaque keystroke écrit en SQLite
/// instantanément. Le ConflictAlgorithm.replace + le debounce du
/// SyncEngine (200ms) absorbent l'overhead réseau.
const Duration kSaveDebounceText = Duration.zero;

/// Debounce pour les onglets qui n'ont que des toggles / dropdowns.
const Duration kSaveDebouncePills = Duration(seconds: 2);

/// Helper pour redémarrer un timer de save sans dupliquer le pattern
/// dans chaque onglet. Annule le timer précédent puis en démarre un
/// nouveau avec la durée donnée. Renvoie le nouveau timer pour que
/// l'appelant puisse le stocker (et l'annuler dans dispose).
Timer scheduleDebouncedSave({
  Timer? previous,
  required void Function() onFire,
  Duration delay = kSaveDebounceText,
}) {
  previous?.cancel();
  return Timer(delay, onFire);
}
