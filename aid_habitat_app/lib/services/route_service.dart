// Service de géocodage + calcul de temps de trajet pour le dashboard.
//
// API utilisées (gratuites, sans clé) :
//   - Géocodage : `https://api-adresse.data.gouv.fr/search/?q=...`
//     (Base Adresse Nationale française, IGN/data.gouv.fr)
//   - Routing : `https://router.project-osrm.org/route/v1/driving/...`
//     (instance publique OSRM, données OpenStreetMap)
//
// Cache mémoire pour la durée du process — la même adresse n'est
// géocodée qu'une fois ; le même couple (origine, destination) n'est
// routé qu'une fois. Pas de cache disque (les adresses changent
// rarement et les latences sont acceptables au cold start, ~200-500 ms
// par appel).
//
// Robustesse : tous les appels réseau sont best-effort. Échec → renvoie
// `null` au lieu de jeter, le caller affiche un placeholder discret
// (« — » sur le temps de route).

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

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
const GeoPoint kAidHabitatOrigin = GeoPoint(
  lat: 48.022447,
  lon: -1.707700,
);

/// Texte de l'adresse origine — utilisé dans l'UI pour expliquer le
/// point de départ (« depuis Aid'Habitat »).
const String kAidHabitatAddressLabel =
    "16 rue Léo Lagrange, 35131 Chartres-de-Bretagne";

class RouteService {
  RouteService._internal();
  static final RouteService instance = RouteService._internal();

  final Map<String, GeoPoint?> _geocodeCache = <String, GeoPoint?>{};
  final Map<String, Future<GeoPoint?>> _geocodeInflight =
      <String, Future<GeoPoint?>>{};

  final Map<String, Duration?> _routeCache = <String, Duration?>{};
  final Map<String, Future<Duration?>> _routeInflight =
      <String, Future<Duration?>>{};

  /// Géocode une adresse française en (lat, lon) via la Base Adresse
  /// Nationale. Renvoie `null` si la BAN ne trouve pas (adresse
  /// incomplète, faute de frappe, hors-France) ou si le réseau échoue.
  Future<GeoPoint?> geocode(String address) async {
    final key = address.trim().toLowerCase();
    if (key.isEmpty) return null;
    if (_geocodeCache.containsKey(key)) return _geocodeCache[key];
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
        final geom = (features.first as Map<String, dynamic>)['geometry']
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
      _geocodeCache[key] = result;
      return result;
    } finally {
      _geocodeInflight.remove(key);
    }
  }

  /// Calcule la durée de trajet en voiture entre [from] et [to] via
  /// OSRM. Renvoie `null` si le routing échoue (réseau, instance OSRM
  /// indisponible).
  Future<Duration?> drivingDuration(GeoPoint from, GeoPoint to) async {
    // Petite optimisation : trajet identique → 0 (au cas où l'origine
    // et la destination sont la même adresse).
    if (from == to) return Duration.zero;
    final key = '${from.lat},${from.lon}->${to.lat},${to.lon}';
    if (_routeCache.containsKey(key)) return _routeCache[key];
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
      _routeCache[key] = result;
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
  }) async {
    final to = await geocode(toAddress);
    if (to == null) return null;
    return drivingDuration(from, to);
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
