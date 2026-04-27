import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'media_cache_service.dart';
import 'sync_engine.dart';

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

    // Set canonique des IDs remote — sert à purger les caisses
    // supprimées sur NocoDB (chantier sync #1).
    final remoteIds = remoteFunds.map((f) => f.id).toSet();

    await db.transaction((txn) async {
      for (final fund in remoteFunds) {
        final existing = await txn.query(
          'retirement_funds',
          columns: ['sync_state'],
          where: 'id = ?',
          whereArgs: [fund.id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final syncState = existing.first['sync_state'] as String?;
          if (syncState != null && syncState != SyncState.synced.name) {
            continue; // preserve local pending mutation
          }
        }
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
          'last_synced_at': now,
          'pending_logo_data_url': null,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Réconciliation des suppressions remote : on supprime localement
      // toute caisse `synced` qui n'apparaît plus côté NocoDB. Les
      // drafts (sync_state != synced) sont préservés.
      final placeholders = List.filled(remoteIds.length, '?').join(',');
      final deleted = await txn.delete(
        'retirement_funds',
        where: 'sync_state = ? AND id NOT IN ($placeholders)',
        whereArgs: [SyncState.synced.name, ...remoteIds],
      );
      if (deleted > 0) {
        // ignore: avoid_print
        print(
          '[reconcile] retirement_funds : $deleted ligne(s) purgée(s) '
          '(suppression remote)',
        );
      }
    });

    unawaited(_prefetchLogos(remoteFunds));
  }

  Future<void> _prefetchLogos(List<RetirementFund> funds) async {
    final urls = funds
        .map((f) => f.logoUrl.trim())
        .where((u) => u.isNotEmpty)
        .toSet();
    if (urls.isEmpty) return;
    try {
      await MediaCacheService.instance.prefetchAll(urls);
    } catch (_) {}
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
      'last_synced_at': now,
      'sync_state': SyncState.synced.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Offline-first update: writes the fund locally (sync_state = pendingSync)
  /// and enqueues a sync operation. Returns the updated fund so the UI can
  /// render it immediately.
  Future<RetirementFund> updateLocalFund(RetirementFund fund) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      await txn.update(
        'retirement_funds',
        {
          'name': fund.name,
          'phone': fund.phone,
          'audience': fund.audience,
          'request_method': fund.requestMethod,
          'request_delay': fund.requestDelay,
          'aid_amount': fund.aidAmount,
          'therapist_note': fund.therapistNote,
          'website': fund.website,
          'logo_url': fund.logoUrl,
          'last_edited_at': now,
          'sync_state': SyncState.pendingSync.name,
        },
        where: 'id = ?',
        whereArgs: [fund.id],
      );

      await txn.insert('sync_operations', {
        'id': 'rfund_update_${fund.id}_'
            '${DateTime.now().microsecondsSinceEpoch}',
        'entity_type': 'retirement_fund',
        'entity_local_id': fund.id,
        'operation_type': 'update',
        'payload_json': jsonEncode({
          'fundId': fund.id,
          'fund': {
            'name': fund.name,
            'phone': fund.phone,
            'audience': fund.audience,
            'requestMethod': fund.requestMethod,
            'requestDelay': fund.requestDelay,
            'aidAmount': fund.aidAmount,
            'therapistNote': fund.therapistNote,
            'website': fund.website,
            'logoUrl': fund.logoUrl,
          },
        }),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });

    SyncEngine().notify();
    return fund.copyWith(lastEditedAt: now);
  }

  /// Returns all fund names sorted A→Z from the local cache. Used to feed
  /// the retirement-fund picker on the beneficiary tab offline.
  Future<List<String>> fetchAllNames() async {
    final db = await _database.database;
    final rows = await db.query(
      'retirement_funds',
      columns: ['name'],
      orderBy: 'name ASC',
    );
    return rows
        .map((r) => (r['name'] as String?)?.trim() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
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
      // The local schema has no dedicated `created_at` column, so fall back
      // to the row's `last_synced_at` — the closest proxy for "known since" in
      // offline mode. When available, the remote `createdAt` will replace
      // this through the next sync.
      createdAt: row['last_synced_at'] as String?,
    );
  }
}
