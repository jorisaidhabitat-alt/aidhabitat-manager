import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../models/types.dart';
import 'app_config.dart';
import 'local_database.dart';
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
  final LocalDatabase _localDb = LocalDatabase.instance;
  final StreamController<ReferencesPayload> _controller =
      StreamController<ReferencesPayload>.broadcast();

  /// Clé du cache local (table `kv_store`).
  static const _cacheKey = 'references_payload_v1';

  /// Durée pendant laquelle un payload chargé est considéré "frais".
  /// Au-delà, `ensureLoaded()` déclenche un refresh réseau en arrière-
  /// plan tout en retournant tout de suite le cache courant
  /// (sémantique stale-while-revalidate).
  ///
  /// 30 minutes : compromis entre fraîcheur (admin ajoute une commune
  /// dans NocoDB → l'ergo la voit dans la demi-heure sans redémarrage)
  /// et économies réseau / batterie sur iPad.
  static const _ttl = Duration(minutes: 30);

  ReferencesPayload _payload = const ReferencesPayload();
  bool _loaded = false;
  Future<void>? _inflight;
  DateTime? _lastFetchedAt;

  /// Latest reference data (empty lists if never loaded).
  ReferencesPayload get payload => _payload;

  List<CommuneRef> get communes => _payload.communes;
  List<BaremeAnahRef> get baremesAnah => _payload.baremesAnah;
  List<EpciRef> get epcis => _payload.epcis;

  bool get isLoaded => _loaded;

  /// Fires whenever the cache is (re)loaded with fresh data.
  Stream<ReferencesPayload> get onLoaded => _controller.stream;

  /// Renvoie `true` si le payload courant est plus vieux que [_ttl] ou
  /// si on n'a jamais réussi un fetch réseau (cache SQLite seul).
  bool get _isStale {
    final at = _lastFetchedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _ttl;
  }

  /// Loads references on first call. Subsequent calls :
  ///  - si le cache est encore frais (< TTL) → no-op
  ///  - si le cache est stale → retourne immédiatement le payload
  ///    courant et déclenche un refresh réseau en arrière-plan
  ///    (sémantique stale-while-revalidate). Le stream `onLoaded`
  ///    émettra le nouveau payload quand le fetch arrive, ce qui
  ///    déclenche un rebuild des écrans abonnés.
  ///  - [forceRefresh] court-circuite le TTL et attend le refresh.
  ///
  /// Errors are swallowed — the app can still function with empty
  /// references (autocomplete becomes dumb, income category stays
  /// empty).
  Future<void> ensureLoaded({bool forceRefresh = false}) {
    // Premier appel : on attend le hydrate cache + premier fetch pour
    // que les écrans qui font `await ensureLoaded()` aient bien des
    // données avant de rendre.
    if (!_loaded) {
      final existing = _inflight;
      if (existing != null) return existing;
      final future = _doLoad().whenComplete(() => _inflight = null);
      _inflight = future;
      return future;
    }

    // Données déjà chargées + appel forcé → on attend le refresh.
    if (forceRefresh) {
      final existing = _inflight;
      if (existing != null) return existing;
      final future = _doLoad().whenComplete(() => _inflight = null);
      _inflight = future;
      return future;
    }

    // Données chargées + fraîches → no-op.
    if (!_isStale) return Future.value();

    // Données chargées + stale → on retourne tout de suite avec ce
    // qu'on a, et on lance un refresh en arrière-plan dont le résultat
    // sera émis via `onLoaded`. Le caller ne l'attend pas : ses écrans
    // se mettent à jour via le stream quand le fetch arrive.
    _inflight ??= _doLoad().whenComplete(() => _inflight = null);
    return Future.value();
  }

  /// Force un refresh immédiat des références depuis NocoDB. Utile
  /// pour les actions explicites de l'utilisateur (pull-to-refresh,
  /// bouton "actualiser le catalogue", …). Ne lève jamais — silently
  /// keeps the previous payload si le réseau est KO.
  Future<void> refresh() => ensureLoaded(forceRefresh: true);

  Future<void> _doLoad() async {
    // 1. Hydrate depuis le cache SQLite si on n'a encore rien — comme ça
    //    le badge "Communauté de communes" du dossier (et les autocompletes
    //    de communes) s'affichent instantanément au cold start, sans
    //    attendre le round-trip réseau. Sans ce cache, sur iPad PWA après
    //    un clear cache, le badge n'apparaît qu'après 1-2 secondes alors
    //    que le reste du dossier est déjà rendu.
    if (!_loaded) {
      final cached = await _readFromCache();
      if (cached != null) {
        _payload = cached;
        _loaded = true;
        if (!_controller.isClosed) _controller.add(cached);
      }
    }

    // 2. Si la config NocoDB n'est pas encore prête (pas de session
    //    token côté `AppConfig`), on n'arme PAS le TTL et on ne marque
    //    PAS `_loaded`. Sinon, le pré-fetch au boot (déclenché avant
    //    que `AuthService.restoreRemoteSession()` ait fini de poser le
    //    token) reçoit un `ReferencesPayload` vide via le fallback
    //    `NocodbApiClient.fetchReferences()` (cf. `if
    //    (!AppConfig.hasRemoteConfig) return const ReferencesPayload()`),
    //    persisterait ce payload vide en cache et bloquerait tous les
    //    `ensureLoaded()` ultérieurs en no-op (TTL frais) → badge EPCI
    //    et autocomplete commune cassés à vie jusqu'au prochain clear
    //    cache.
    if (!AppConfig.hasRemoteConfig) {
      return;
    }

    // 3. Refresh réseau (toujours, même si on a un cache — pour récupérer
    //    les nouvelles communes/EPCIs/barèmes ANAH ajoutés côté NocoDB).
    try {
      final payload = await _apiClient.fetchReferences();
      // Sécurité : si malgré la garde au-dessus le serveur renvoie un
      // payload totalement vide, on ne le persiste pas et on ne marque
      // pas le TTL — le prochain `ensureLoaded` retentera. Ça couvre le
      // cas où le serveur est joignable mais les tables NocoDB sont
      // temporairement indisponibles (réplication, maintenance…).
      if (payload.communes.isEmpty &&
          payload.epcis.isEmpty &&
          payload.baremesAnah.isEmpty) {
        return;
      }
      _payload = payload;
      _loaded = true;
      // Marque l'instant du fetch réussi → arme le TTL stale-while-
      // revalidate (cf. `ensureLoaded`).
      _lastFetchedAt = DateTime.now();
      if (!_controller.isClosed) _controller.add(payload);
      // 4. Persiste pour le prochain cold start.
      unawaited(_writeToCache(payload));
    } catch (_) {
      // Silent fallback: keep the previous payload (cached or empty) so UI
      // degrades gracefully to plain text fields.
      //
      // On NE met PAS à jour `_lastFetchedAt` : le cache reste donc
      // marqué stale et le prochain `ensureLoaded()` retentera le
      // refresh.
    }
  }

  Future<ReferencesPayload?> _readFromCache() async {
    try {
      final db = await _localDb.database;
      final rows = await db.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: [_cacheKey],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'] as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final communes = (decoded['communes'] as List?)
              ?.whereType<Map>()
              .map((e) => CommuneRef.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [];
      final baremes = (decoded['baremesAnah'] as List?)
              ?.whereType<Map>()
              .map((e) => BaremeAnahRef.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [];
      final epcis = (decoded['epcis'] as List?)
              ?.whereType<Map>()
              .map((e) => EpciRef.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [];

      return ReferencesPayload(
        communes: communes,
        baremesAnah: baremes,
        epcis: epcis,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToCache(ReferencesPayload payload) async {
    try {
      final db = await _localDb.database;
      final encoded = jsonEncode({
        'communes': payload.communes.map((c) => c.toJson()).toList(),
        'baremesAnah': payload.baremesAnah.map((b) => b.toJson()).toList(),
        'epcis': payload.epcis.map((e) => e.toJson()).toList(),
      });
      await db.insert(
        'kv_store',
        {
          'key': _cacheKey,
          'value': encoded,
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // Silent — un cache absent n'est pas fatal, le prochain cold start
      // refera juste le round-trip réseau.
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
