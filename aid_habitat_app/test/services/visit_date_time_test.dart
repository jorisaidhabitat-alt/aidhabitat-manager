import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/visit_date_time.dart';

void main() {
  group('parseVisitDateTime', () {
    test('converts UTC timestamps to the device timezone', () {
      const raw = '2026-07-28T08:00:00.000Z';

      expect(parseVisitDateTime(raw), DateTime.parse(raw).toLocal());
    });

    test('keeps local timestamps unchanged', () {
      expect(
        parseVisitDateTime('2026-07-28T10:00:00'),
        DateTime(2026, 7, 28, 10),
      );
    });

    test('keeps date-only values on their calendar day', () {
      expect(parseVisitDateTime('2026-07-28'), DateTime(2026, 7, 28));
    });

    test('returns null for empty or invalid values', () {
      expect(parseVisitDateTime(null), isNull);
      expect(parseVisitDateTime(''), isNull);
      expect(parseVisitDateTime('not-a-date'), isNull);
    });
  });
}
