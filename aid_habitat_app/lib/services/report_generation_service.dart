import 'dart:async';
import 'dart:typed_data';

/// État d'une génération de rapport PDF en cours ou terminée.
/// Diffusé via [ReportGenerationService.stateStream] et écouté par un
/// overlay global (`_GlobalReportGenerationOverlay`) qui rend le bandeau
/// "génération en cours" + le snackbar de succès/erreur **quelle que
/// soit l'écran courant** (Dashboard, Documents, Wiki, autre dossier…).
///
/// Demande utilisateur 2026-05-11 :
///   « Quand je quitte le relevé de visite et que je retourne dessus,
///     je n'ai plus le load qui indique la generation en cours. Aussi,
///     le bandeau vert qui indique qu'il a été mis dans l'espace
///     document doit également apparaitre en bas même si je suis sur
///     une autre page une fois la generation effectuée. »
class ReportGenerationState {
  /// True tant qu'une génération est en cours. Permet à l'overlay
  /// d'afficher un indicateur de progression non-bloquant.
  final bool inProgress;

  /// Libellé court affiché dans l'overlay pendant la génération
  /// (ex. "Génération du rapport BALS Joris..."). Vide quand
  /// `inProgress == false`.
  final String progressLabel;

  /// `dossierId` du dossier dont le rapport est en train d'être
  /// généré. Permet aux écrans de filtrer s'ils veulent réagir
  /// spécifiquement (ex. désactiver le bouton "Générer" du même
  /// dossier pour éviter un double-clic).
  final String? activeDossierId;

  /// Si la génération vient de se terminer avec succès. Un événement
  /// éphémère : émis une fois, puis l'état repasse à neutre.
  final ReportGenerationSuccess? lastSuccess;

  /// Pareil pour les erreurs : émis une fois puis nettoyé.
  final ReportGenerationFailure? lastFailure;

  const ReportGenerationState({
    this.inProgress = false,
    this.progressLabel = '',
    this.activeDossierId,
    this.lastSuccess,
    this.lastFailure,
  });

  ReportGenerationState copyWith({
    bool? inProgress,
    String? progressLabel,
    String? activeDossierId,
    ReportGenerationSuccess? lastSuccess,
    ReportGenerationFailure? lastFailure,
    bool clearActiveDossier = false,
    bool clearSuccess = false,
    bool clearFailure = false,
  }) {
    return ReportGenerationState(
      inProgress: inProgress ?? this.inProgress,
      progressLabel: progressLabel ?? this.progressLabel,
      activeDossierId: clearActiveDossier
          ? null
          : (activeDossierId ?? this.activeDossierId),
      lastSuccess: clearSuccess ? null : (lastSuccess ?? this.lastSuccess),
      lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    );
  }
}

/// Événement de succès — embarque les infos nécessaires au snackbar
/// global ("Rapport ajouté dans les Documents : X.pdf") + au lien
/// "Voir" qui permet d'ouvrir le doc dans l'espace Documents même
/// depuis un autre écran.
class ReportGenerationSuccess {
  final String dossierId;
  final String patientLabel; // ex. "BALS Joris"
  final String fileName;
  final int byteSize;
  final String? savedDocUuid;
  final Uint8List? bytes; // utile si l'écran courant veut afficher la preview
  final DateTime completedAt;

  const ReportGenerationSuccess({
    required this.dossierId,
    required this.patientLabel,
    required this.fileName,
    required this.byteSize,
    this.savedDocUuid,
    this.bytes,
    required this.completedAt,
  });
}

class ReportGenerationFailure {
  final String dossierId;
  final String patientLabel;
  final String message;
  final bool deferred; // true si la génération a été enqueued offline
  final DateTime occurredAt;

  const ReportGenerationFailure({
    required this.dossierId,
    required this.patientLabel,
    required this.message,
    this.deferred = false,
    required this.occurredAt,
  });
}

/// Singleton de gestion d'état des générations de rapports. Process-wide,
/// survit aux changements d'écran. À étendre si on a besoin de gérer
/// plusieurs générations simultanées (queue) — pour l'instant on suppose
/// une seule génération à la fois (le bouton "Générer" est désactivé
/// pendant qu'une autre est en cours, cf. `inProgress` check côté UI).
class ReportGenerationService {
  ReportGenerationService._internal();
  static final ReportGenerationService instance =
      ReportGenerationService._internal();
  factory ReportGenerationService() => instance;

  final _controller =
      StreamController<ReportGenerationState>.broadcast();
  ReportGenerationState _state = const ReportGenerationState();

  /// Stream de l'état. Les abonnés reçoivent l'état courant à
  /// l'inscription (via `seedValue` au mount) + les changements
  /// suivants.
  Stream<ReportGenerationState> get stateStream => _controller.stream;

  /// État synchrone, utile pour les rebuild initiaux des widgets qui
  /// n'ont pas encore d'event Stream à l'écran.
  ReportGenerationState get currentState => _state;

  /// Marque le début d'une génération. Émet l'état mis à jour.
  void notifyStart({
    required String dossierId,
    required String patientLabel,
  }) {
    _state = _state.copyWith(
      inProgress: true,
      progressLabel: 'Génération du rapport $patientLabel...',
      activeDossierId: dossierId,
      clearSuccess: true,
      clearFailure: true,
    );
    _controller.add(_state);
  }

  /// Marque la fin réussie d'une génération. Émet l'état avec
  /// `lastSuccess` peuplé pour que l'overlay puisse afficher le
  /// snackbar.
  void notifySuccess(ReportGenerationSuccess success) {
    _state = _state.copyWith(
      inProgress: false,
      progressLabel: '',
      clearActiveDossier: true,
      lastSuccess: success,
      clearFailure: true,
    );
    _controller.add(_state);
  }

  /// Marque la fin en échec.
  void notifyFailure(ReportGenerationFailure failure) {
    _state = _state.copyWith(
      inProgress: false,
      progressLabel: '',
      clearActiveDossier: true,
      lastFailure: failure,
      clearSuccess: true,
    );
    _controller.add(_state);
  }

  /// Acquitte le dernier événement de succès/échec — typiquement
  /// appelé par l'overlay après avoir affiché le snackbar, pour que
  /// le même événement ne soit pas rejoué au remount d'un autre écran.
  void acknowledgeLastEvent() {
    if (_state.lastSuccess == null && _state.lastFailure == null) return;
    _state = _state.copyWith(clearSuccess: true, clearFailure: true);
    _controller.add(_state);
  }
}
