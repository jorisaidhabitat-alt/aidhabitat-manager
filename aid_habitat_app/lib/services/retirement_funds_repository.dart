import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class RetirementFundsRepository {
  RetirementFundsRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<RetirementFund>> fetchAllFunds() async {
    final db = await _database.database;
    final rows = await db.query('retirement_funds', orderBy: 'name ASC');
    return rows.map(_mapRow).toList();
  }

  Future<void> mergeRemoteFunds(List<RetirementFund> remoteFunds) async {
    if (remoteFunds.isEmpty) return;
    final db = await _database.database;

    await db.transaction((txn) async {
      for (final fund in remoteFunds) {
        final now = DateTime.now().toIso8601String();
        await txn.insert('retirement_funds', {
          'id': fund.id,
          'name': fund.name,
          'phone': fund.phone,
          'audience': fund.audience,
          'request_method': fund.requestMethod,
          'request_delay': fund.requestDelay,
          'aid_amount': fund.aidAmount,
          'therapist_note': fund.therapistNote,
          'website': fund.website,
          'logo_url': fund.logoUrl,
          'last_edited_at': fund.lastEditedAt,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> upsertFund(RetirementFund fund) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.insert('retirement_funds', {
      'id': fund.id,
      'name': fund.name,
      'phone': fund.phone,
      'audience': fund.audience,
      'request_method': fund.requestMethod,
      'request_delay': fund.requestDelay,
      'aid_amount': fund.aidAmount,
      'therapist_note': fund.therapistNote,
      'website': fund.website,
      'logo_url': fund.logoUrl,
      'last_edited_at': fund.lastEditedAt,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  RetirementFund _mapRow(Map<String, Object?> row) {
    return RetirementFund(
      id: row['id'] as String,
      name: row['name'] as String,
      phone: row['phone'] as String,
      audience: row['audience'] as String,
      requestMethod: row['request_method'] as String,
      requestDelay: row['request_delay'] as String,
      aidAmount: row['aid_amount'] as String,
      therapistNote: row['therapist_note'] as String,
      website: row['website'] as String,
      logoUrl: row['logo_url'] as String,
      lastEditedAt: row['last_edited_at'] as String?,
    );
  }
}
