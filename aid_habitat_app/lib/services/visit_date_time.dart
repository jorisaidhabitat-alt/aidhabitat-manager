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

  // NocoDB serializes DateTime values in UTC. Convert them back to the
  // device timezone before displaying or comparing visit hours.
  return parsed.isUtc ? parsed.toLocal() : parsed;
}
