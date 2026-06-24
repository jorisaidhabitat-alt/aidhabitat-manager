class FeedbackContextSnapshot {
  final String page;
  final String dossierId;
  final String dossierName;
  final String section;
  final String lastAction;

  const FeedbackContextSnapshot({
    required this.page,
    required this.dossierId,
    required this.dossierName,
    required this.section,
    required this.lastAction,
  });

  Map<String, dynamic> toJson() => {
    'page': page,
    'dossierId': dossierId,
    'dossierName': dossierName,
    'section': section,
    'lastAction': lastAction,
  };
}

class FeedbackActivityService {
  FeedbackActivityService._();
  static final FeedbackActivityService instance = FeedbackActivityService._();

  String _lastAction = 'Ouverture de l’application';

  void track(String action) {
    final trimmed = action.trim();
    if (trimmed.isEmpty) return;
    _lastAction = trimmed;
  }

  String get lastAction => _lastAction;

  FeedbackContextSnapshot snapshot({
    required String page,
    String dossierId = '',
    String dossierName = '',
    String section = '',
  }) {
    return FeedbackContextSnapshot(
      page: page,
      dossierId: dossierId,
      dossierName: dossierName,
      section: section,
      lastAction: _lastAction,
    );
  }
}
