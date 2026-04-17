import 'dart:async';

import '../models/types.dart';
import 'nocodb_api_client.dart';

/// Caches the reference data served by `GET /api/references` and exposes
/// utility helpers on top of it:
///
/// - [searchCommunes] : ranked filter used by the city autocomplete widget
/// - [computeIncomeCategory] : derives "Très modeste / Modeste / …" from
///   `numberPeople` + `fiscalRevenue` using the ANAH thresholds
///
/// The service is a process-wide singleton so the cache survives navigation.
/// It also notifies listeners (via a broadcast stream) when the payload is
/// first loaded, so widgets that care about commune autocomplete can refresh.
class ReferencesService {
  ReferencesService._();

  static final ReferencesService _instance = ReferencesService._();

  factory ReferencesService() => _instance;

  final NocodbApiClient _apiClient = NocodbApiClient();
  final StreamController<ReferencesPayload> _controller =
      StreamController<ReferencesPayload>.broadcast();

  ReferencesPayload _payload = const ReferencesPayload();
  bool _loaded = false;
  Future<void>? _inflight;

  /// Latest reference data (empty lists if never loaded).
  ReferencesPayload get payload => _payload;

  List<CommuneRef> get communes => _payload.communes;
  List<BaremeAnahRef> get baremesAnah => _payload.baremesAnah;

  bool get isLoaded => _loaded;

  /// Fires whenever the cache is (re)loaded with fresh data.
  Stream<ReferencesPayload> get onLoaded => _controller.stream;

  /// Loads references once (subsequent calls are no-ops unless
  /// [forceRefresh] is true). Errors are swallowed — the app can still
  /// function with empty references (autocomplete becomes dumb, income
  /// category stays empty).
  Future<void> ensureLoaded({bool forceRefresh = false}) {
    if (_loaded && !forceRefresh) return Future.value();
    final existing = _inflight;
    if (existing != null) return existing;

    final future = _doLoad().whenComplete(() => _inflight = null);
    _inflight = future;
    return future;
  }

  Future<void> _doLoad() async {
    try {
      final payload = await _apiClient.fetchReferences();
      _payload = payload;
      _loaded = true;
      if (!_controller.isClosed) _controller.add(payload);
    } catch (_) {
      // Silent fallback: keep the previous payload (or empty) so UI degrades
      // gracefully to plain text fields.
    }
  }

  // ---------------------------------------------------------------------------
  // Commune search
  // ---------------------------------------------------------------------------

  /// Returns up to [limit] communes matching [query]. Ordering: startsWith
  /// first, then contains, then alphabetical. Zip-code matches are accepted
  /// when the query is purely numeric.
  List<CommuneRef> searchCommunes(String query, {int limit = 12}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final isNumeric = RegExp(r'^\d+$').hasMatch(q);

    final starts = <CommuneRef>[];
    final contains = <CommuneRef>[];
    final zips = <CommuneRef>[];

    for (final c in _payload.communes) {
      final label = c.label.toLowerCase();
      if (isNumeric && c.zipCode.startsWith(q)) {
        zips.add(c);
        continue;
      }
      if (label.startsWith(q)) {
        starts.add(c);
      } else if (label.contains(q)) {
        contains.add(c);
      }
    }

    int byLabel(CommuneRef a, CommuneRef b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase());
    starts.sort(byLabel);
    contains.sort(byLabel);
    zips.sort(byLabel);

    final merged = <CommuneRef>[...zips, ...starts, ...contains];
    if (merged.length <= limit) return merged;
    return merged.sublist(0, limit);
  }

  // ---------------------------------------------------------------------------
  // Income category
  // ---------------------------------------------------------------------------

  /// Resolves the applicable bareme for [numberPeople]: prefers an exact
  /// match for the most recent year; otherwise falls back to the largest
  /// household size ≤ [numberPeople] (so a foyer of 6 falls back on the
  /// largest published bareme).
  BaremeAnahRef? _findBareme(int numberPeople) {
    if (_payload.baremesAnah.isEmpty || numberPeople <= 0) return null;

    final exact = _payload.baremesAnah
        .where((b) => b.householdSize == numberPeople)
        .toList();
    if (exact.isNotEmpty) {
      exact.sort(
        (a, b) => (b.plafondYear ?? 0).compareTo(a.plafondYear ?? 0),
      );
      return exact.first;
    }

    final below = _payload.baremesAnah
        .where((b) => b.householdSize > 0 && b.householdSize <= numberPeople)
        .toList();
    if (below.isEmpty) return null;
    below.sort((a, b) {
      final sizeCmp = b.householdSize.compareTo(a.householdSize);
      if (sizeCmp != 0) return sizeCmp;
      return (b.plafondYear ?? 0).compareTo(a.plafondYear ?? 0);
    });
    return below.first;
  }

  /// Returns one of "Très modeste", "Modeste", "Intermédiaire", "Supérieur"
  /// — empty string if thresholds are missing or inputs are invalid.
  String computeIncomeCategory(int numberPeople, double? fiscalRevenue) {
    if (fiscalRevenue == null || fiscalRevenue <= 0) return '';
    if (numberPeople <= 0) return '';

    final bareme = _findBareme(numberPeople);
    if (bareme == null) return '';

    final tresModeste = bareme.revenueTresModeste;
    final modeste = bareme.revenueModeste;
    final intermediaire = bareme.revenueIntermediaire;

    if (tresModeste != null && fiscalRevenue <= tresModeste) return 'Très modeste';
    if (modeste != null && fiscalRevenue <= modeste) return 'Modeste';
    if (intermediaire != null && fiscalRevenue <= intermediaire) {
      return 'Intermédiaire';
    }
    return 'Supérieur';
  }
}
