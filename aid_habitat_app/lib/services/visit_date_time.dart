import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

final tz.Location _parisLocation = () {
  tz_data.initializeTimeZones();
  return tz.getLocation('Europe/Paris');
}();

DateTime? parseVisitDateTime(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;

  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;

  // A date-only value represents a local calendar day, even if a legacy
  // source appended a timezone marker.
  final hasTime = RegExp(r'[T ]\d{2}:\d{2}').hasMatch(value);
  if (!hasTime) {
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  // Les visites sont planifiées en France. Une conversion avec `toLocal()`
  // dépendrait du fuseau configuré sur chaque iPad et pourrait donc afficher
  // une heure différente d'un appareil à l'autre.
  return parsed.isUtc ? tz.TZDateTime.from(parsed, _parisLocation) : parsed;
}
