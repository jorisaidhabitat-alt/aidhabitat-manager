import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'local_database.dart';

class PrincipalRetirementFundCache {
  PrincipalRetirementFundCache({
    LocalDatabase? database,
    Future<Database> Function()? databaseProvider,
  }) : _databaseProvider =
           databaseProvider ??
           (() => (database ?? LocalDatabase.instance).database);

  static final PrincipalRetirementFundCache instance =
      PrincipalRetirementFundCache();

  static const String cacheKey = 'principal_retirement_funds_v1';

  final Future<Database> Function() _databaseProvider;

  Future<List<Map<String, String>>> read() async {
    try {
      final db = await _databaseProvider();
      final rows = await db.query(
        'kv_store',
        columns: const ['value'],
        where: 'key = ?',
        whereArgs: const [cacheKey],
        limit: 1,
      );
      if (rows.isEmpty) return const [];
      final raw = rows.first['value']?.toString() ?? '';
      if (raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) {
            final map = item.cast<Object?, Object?>();
            return <String, String>{
              'id': map['id']?.toString() ?? '',
              'name': map['name']?.toString() ?? '',
              'phone': map['phone']?.toString() ?? '',
              'logoUrl': map['logoUrl']?.toString() ?? '',
            };
          })
          .where((fund) => fund['name']!.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> readNames() async {
    final funds = await read();
    final names = funds
        .map((fund) => fund['name']!.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
    names.sort();
    return names;
  }

  Future<void> write(List<Map<String, String>> funds) async {
    final normalized = funds
        .map(
          (fund) => <String, String>{
            'id': fund['id']?.trim() ?? '',
            'name': fund['name']?.trim() ?? '',
            'phone': fund['phone']?.trim() ?? '',
            'logoUrl': fund['logoUrl']?.trim() ?? '',
          },
        )
        .where((fund) => fund['name']!.isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) return;

    final db = await _databaseProvider();
    await db.insert('kv_store', {
      'key': cacheKey,
      'value': jsonEncode(normalized),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
