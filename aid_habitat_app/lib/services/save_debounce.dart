/// Constantes de debounce des saves côté visit-report et dossier_screen.
///
/// **Pourquoi centraliser** : avant cette unification, chaque onglet
/// définissait sa propre valeur (100ms / 150ms / 400ms / 2000ms), ce
/// qui créait des races offline quand 2 onglets éditaient des champs
/// chevauchants (ex: Nom dans Bénéficiaire **et** Nom dans
/// dossier_screen). Le « last save wins » côté NocoDB pouvait
/// régresser silencieusement la valeur la plus récente.
///
/// Symptôme reporté ayant motivé ce ménage : « j'ai changé le nom
/// pour BALS, ça s'est sauvé sur BAL puis BAI puis revenait à AB »
/// — une combinaison de debounce trop court (150ms) + rebuild lourd
/// + race avec un refresh remote.
///
/// **Règle** :
///   - Texte saisi (Nom, Prénom, Adresse, observations…) → 400 ms.
///     Laisse les pauses naturelles entre lettres passer.
///   - Toggle / pills / dropdowns (équipements SDB, autonomie,
///     chauffage…) → 2000 ms. Les sélections sont délibérées et
///     espacées, on peut amortir les saves.
///
/// Si tu trouves un nouveau cas qui n'entre pas dans ces 2 catégories,
/// crée une constante explicite plutôt qu'une valeur littérale dans
/// le code.
library;

import 'dart:async';

/// Debounce pour les champs où l'utilisateur tape du texte au clavier.
const Duration kSaveDebounceText = Duration(milliseconds: 400);

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
