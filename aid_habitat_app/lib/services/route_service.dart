// Service de géocodage + calcul de temps de trajet pour le dashboard.
//
// API utilisées (gratuites, sans clé) :
//   - Géocodage : `https://api-adresse.data.gouv.fr/search/?q=...`
//     (Base Adresse Nationale française, IGN/data.gouv.fr)
//   - Routing : `https://router.project-osrm.org/route/v1/driving/...`
//     (instance publique OSRM, données OpenStreetMap)
//
// Cache mémoire + SQLite : la dernière durée reste visible hors connexion.
// Au retour du réseau, le dashboard force un nouveau calcul et remplace le
// cache si l'adresse, l'ordre ou la date des visites ont changé.
//
// Robustesse : tous les appels réseau sont best-effort. Échec → renvoie
// `null` au lieu de jeter, le caller affiche un placeholder discret
// (« — » sur le temps de route).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'local_database.dart';

/// Coordonnées géographiques (lat, lon) issues du géocodage.
class GeoPoint {
  final double lat;
  final double lon;
  const GeoPoint({required this.lat, required this.lon});

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);
}

/// Adresse de départ pour la 1ère visite de la journée — bureaux
/// Aid'Habitat à Chartres-de-Bretagne (constante hardcodée pour
/// éviter un round-trip de géocodage à chaque cold start).
const GeoPoint kAidHabitatOrigin = GeoPoint(lat: 48.022447, lon: -1.707700);

/// Texte de l'adresse origine — utilisé dans l'UI pour expliquer le
/// point de départ (« depuis Aid'Habitat »).
const String kAidHabitatAddressLabel =
    "16 rue Léo Lagrange, 35131 Chartres-de-Bretagne";

class RouteService {
  RouteService._internal();
  static final RouteService instance = RouteService._internal();

  final Map<String, GeoPoint> _geocodeCache = <String, GeoPoint>{};
  final Map<String, Future<GeoPoint?>> _geocodeInflight =
      <String, Future<GeoPoint?>>{};

  final Map<String, Duration> _routeCache = <String, Duration>{};
  final Map<String, Future<Duration?>> _routeInflight =
      <String, Future<Duration?>>{};

  static String _persistentKey(String kind, String raw) {
    final digest = sha256.convert(utf8.encode(raw)).toString();
    return 'dashboard_route_${kind}_v1_$digest';
  }

  Future<Map<String, dynamic>?> _readPersistent(String key) async {
    try {
      final db = await LocalDatabase.instance.database;
      final rows = await db.query(
        'kv_store',
        columns: const ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return (jsonDecode(rows.first['value'] as String) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePersistent(String key, Map<String, dynamic> value) async {
    try {
      final db = await LocalDatabase.instance.database;
      await db.rawInsert(
        'INSERT OR REPLACE INTO kv_store (key, value, updated_at) '
        'VALUES (?, ?, ?)',
        [key, jsonEncode(value), DateTime.now().toIso8601String()],
      );
    } catch (_) {
      // Le cache disque est une optimisation : son échec ne bloque jamais
      // le calcul réseau ni l'affichage du dashboard.
    }
  }

  /// Géocode une adresse française en (lat, lon) via la Base Adresse
  /// Nationale. Renvoie `null` si la BAN ne trouve pas (adresse
  /// incomplète, faute de frappe, hors-France) ou si le réseau échoue.
  Future<GeoPoint?> geocode(
    String address, {
    bool forceRefresh = false,
    bool cacheOnly = false,
  }) async {
    final key = address.trim().toLowerCase();
    if (key.isEmpty) return null;
    if (!forceRefresh) {
      final memory = _geocodeCache[key];
      if (memory != null) return memory;
      final persisted = await _readPersistent(_persistentKey('geo', key));
      final lat = persisted?['lat'];
      final lon = persisted?['lon'];
      if (lat is num && lon is num) {
        final point = GeoPoint(lat: lat.toDouble(), lon: lon.toDouble());
        _geocodeCache[key] = point;
        return point;
      }
    }
    if (cacheOnly) return null;
    final pending = _geocodeInflight[key];
    if (pending != null) return pending;

    final future = () async {
      try {
        final uri = Uri.parse(
          'https://api-adresse.data.gouv.fr/search/'
          '?q=${Uri.encodeQueryComponent(address.trim())}'
          '&limit=1',
        );
        final resp = await http
            .get(uri, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 6));
        if (resp.statusCode != 200) return null;
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final features = data['features'] as List<dynamic>?;
        if (features == null || features.isEmpty) return null;
        final geom =
            (features.first as Map<String, dynamic>)['geometry']
                as Map<String, dynamic>?;
        final coords = geom?['coordinates'] as List<dynamic>?;
        if (coords == null || coords.length < 2) return null;
        // BAN renvoie [lon, lat] (convention GeoJSON).
        final lon = (coords[0] as num).toDouble();
        final lat = (coords[1] as num).toDouble();
        return GeoPoint(lat: lat, lon: lon);
      } catch (_) {
        return null;
      }
    }();

    _geocodeInflight[key] = future;
    try {
      final result = await future;
      if (result != null) {
        _geocodeCache[key] = result;
        await _writePersistent(_persistentKey('geo', key), {
          'lat': result.lat,
          'lon': result.lon,
        });
      }
      return result;
    } finally {
      _geocodeInflight.remove(key);
    }
  }

  /// Calcule la durée de trajet en voiture entre [from] et [to] via
  /// OSRM. Renvoie `null` si le routing échoue (réseau, instance OSRM
  /// indisponible).
  Future<Duration?> drivingDuration(
    GeoPoint from,
    GeoPoint to, {
    bool forceRefresh = false,
    bool cacheOnly = false,
  }) async {
    // Petite optimisation : trajet identique → 0 (au cas où l'origine
    // et la destination sont la même adresse).
    if (from == to) return Duration.zero;
    final key = '${from.lat},${from.lon}->${to.lat},${to.lon}';
    if (!forceRefresh) {
      final memory = _routeCache[key];
      if (memory != null) return memory;
      final persisted = await _readPersistent(_persistentKey('duration', key));
      final seconds = persisted?['seconds'];
      if (seconds is num && seconds >= 0) {
        final duration = Duration(seconds: seconds.round());
        _routeCache[key] = duration;
        return duration;
      }
    }
    if (cacheOnly) return null;
    final pending = _routeInflight[key];
    if (pending != null) return pending;

    final future = () async {
      try {
        // OSRM attend `lon,lat` (convention GeoJSON).
        final uri = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${from.lon},${from.lat};${to.lon},${to.lat}'
          '?overview=false&alternatives=false&steps=false',
        );
        final resp = await http
            .get(uri, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) return null;
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>?;
        if (routes == null || routes.isEmpty) return null;
        final secondsRaw = (routes.first as Map<String, dynamic>)['duration'];
        if (secondsRaw is! num) return null;
        return Duration(seconds: secondsRaw.round());
      } catch (_) {
        return null;
      }
    }();

    _routeInflight[key] = future;
    try {
      final result = await future;
      if (result != null) {
        _routeCache[key] = result;
        await _writePersistent(_persistentKey('duration', key), {
          'seconds': result.inSeconds,
        });
      }
      return result;
    } finally {
      _routeInflight.remove(key);
    }
  }

  /// Helper : géocode + calcul du trajet en une seule fonction. Utilisé
  /// par le dashboard quand on n'a que les adresses textuelles à
  /// disposition.
  Future<Duration?> drivingDurationByAddress({
    required GeoPoint from,
    required String toAddress,
    bool forceRefresh = false,
    bool cacheOnly = false,
  }) async {
    final to = await geocode(
      toAddress,
      forceRefresh: forceRefresh,
      cacheOnly: cacheOnly,
    );
    if (to == null) return null;
    return drivingDuration(
      from,
      to,
      forceRefresh: forceRefresh,
      cacheOnly: cacheOnly,
    );
  }

  /// Formate une durée en libellé court FR (« 12 min », « 1 h 05 »).
  static String formatDuration(Duration d) {
    final mins = d.inMinutes;
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (m == 0) return '$h h';
    return '$h h ${m.toString().padLeft(2, '0')}';
  }
}
