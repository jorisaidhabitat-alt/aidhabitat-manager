List<String> parseRetirementFunds(String raw) {
  final seen = <String>{};
  final funds = <String>[];
  for (final part in raw.split(RegExp(r'\s*(?:;|\n|\|)\s*'))) {
    final value = part.trim();
    if (value.isEmpty) continue;
    if (seen.add(value.toLowerCase())) funds.add(value);
  }
  return funds;
}

String serializeRetirementFunds(Iterable<String> values) {
  final seen = <String>{};
  final funds = <String>[];
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    if (seen.add(value.toLowerCase())) funds.add(value);
  }
  return funds.join('; ');
}

List<String> updateRetirementFundsAtIndex({
  required List<String> current,
  required int fundIndex,
  required String value,
}) {
  final normalizedValue = value.trim();
  if (fundIndex < 0 || normalizedValue.isEmpty) return [...current];

  final next = [...current];
  while (next.length <= fundIndex) {
    next.add('');
  }

  final previousValue = next[fundIndex].trim();
  final duplicateIndex = next.indexWhere(
    (fund) => fund.trim().toLowerCase() == normalizedValue.toLowerCase(),
  );

  next[fundIndex] = normalizedValue;

  if (duplicateIndex != -1 && duplicateIndex != fundIndex) {
    if (previousValue.isNotEmpty) {
      next[duplicateIndex] = previousValue;
    } else {
      next.removeAt(duplicateIndex);
    }
  }

  return next;
}
