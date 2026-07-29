import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aid_habitat_app/services/principal_retirement_fund_cache.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE sync_operations (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_local_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE kv_store (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE note_pages (
        local_id TEXT PRIMARY KEY,
        sync_state TEXT NOT NULL
      )
    ''');
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertOperation({
    required String id,
    required String status,
    required String payload,
    int attempts = 0,
    String? error,
    DateTime? updatedAt,
  }) {
    final now = DateTime.now();
    return db.insert('sync_operations', {
      'id': id,
      'entity_type': 'note_page',
      'entity_local_id': 'note_test_0',
      'operation_type': 'upsert',
      'payload_json': payload,
      'status': status,
      'attempt_count': attempts,
      'last_error': error,
      'created_at': now.subtract(const Duration(days: 5)).toIso8601String(),
      'updated_at': (updatedAt ?? now.subtract(const Duration(days: 4)))
          .toIso8601String(),
    });
  }

  group('file de synchronisation offline', () {
    test(
      'une opération interrompue survit au redémarrage avec son gros payload',
      () async {
        final payload = '{"previewDataUrl":"${'x' * 600000}"}';
        await insertOperation(
          id: 'sync_large_drawing',
          status: 'running',
          payload: payload,
          attempts: 4,
        );

        // Une nouvelle instance simule le repository recréé au redémarrage.
        final repositoryAfterRestart = SyncRepository(
          databaseProvider: () async => db,
        );
        final repaired = await repositoryAfterRestart
            .purgeStalePendingOperations(
              maxRunningAge: const Duration(hours: 1),
            );

        expect(repaired, 1);
        final rows = await db.query(
          'sync_operations',
          where: 'id = ?',
          whereArgs: const ['sync_large_drawing'],
        );
        expect(rows, hasLength(1));
        expect(rows.single['status'], 'pending');
        expect(rows.single['payload_json'], payload);
        expect(rows.single['attempt_count'], 0);

        final runnable = await repositoryAfterRestart.fetchRunnableOperations();
        expect(runnable, hasLength(1));
        expect(runnable.single.payloadJson, payload);
      },
    );

    test('un gros payload rejeté définitivement reste récupérable', () async {
      final payload = '{"documentData":"${'y' * 700000}"}';
      await insertOperation(
        id: 'sync_rejected_document',
        status: 'failed',
        payload: payload,
        attempts: 5,
        error: 'Remote upload failed (413): Content Too Large',
      );

      final repository = SyncRepository(databaseProvider: () async => db);
      await repository.purgeStalePendingOperations();

      final rows = await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: const ['sync_rejected_document'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'failed');
      expect(rows.single['payload_json'], payload);
      expect(await repository.fetchRunnableOperations(), isEmpty);
    });

    test('un échec réseau est réhabilité sans perdre son payload', () async {
      const payload = '{"field":"value entered offline"}';
      await insertOperation(
        id: 'sync_transient',
        status: 'failed',
        payload: payload,
        attempts: 3,
        error: 'Remote update failed (500)',
      );

      final repository = SyncRepository(databaseProvider: () async => db);
      await repository.purgeStalePendingOperations();

      final runnable = await repository.fetchRunnableOperations();
      expect(runnable, hasLength(1));
      expect(runnable.single.id, 'sync_transient');
      expect(runnable.single.payloadJson, payload);
    });

    test('une opération conservée peut terminer après la reconnexion', () async {
      await db.insert('note_pages', {
        'local_id': 'note_test_0',
        'sync_state': 'pendingSync',
      });
      await insertOperation(
        id: 'sync_after_reconnect',
        status: 'pending',
        payload: '{"drawingJson":"offline strokes"}',
      );

      final repository = SyncRepository(databaseProvider: () async => db);
      final operation = (await repository.fetchRunnableOperations()).single;
      await repository.markRunning(operation.id);

      // Simule la réponse distante réussie du cycle déclenché au retour réseau.
      await repository.markCompleted(
        operationId: operation.id,
        entityType: operation.entityType,
        entityLocalId: operation.entityLocalId,
      );

      final operationRows = await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: const ['sync_after_reconnect'],
      );
      final noteRows = await db.query(
        'note_pages',
        where: 'local_id = ?',
        whereArgs: const ['note_test_0'],
      );
      expect(operationRows.single['status'], 'completed');
      expect(noteRows.single['sync_state'], 'synced');
    });
  });

  test(
    'le référentiel des caisses principales survit au redémarrage',
    () async {
      final firstInstance = PrincipalRetirementFundCache(
        databaseProvider: () async => db,
      );
      await firstInstance.write(const [
        {
          'id': 'fund-1',
          'name': 'Assurance retraite',
          'phone': '3960',
          'logoUrl': 'https://example.test/logo.png',
        },
        {'id': 'fund-2', 'name': 'MSA', 'phone': '', 'logoUrl': ''},
      ]);

      final instanceAfterRestart = PrincipalRetirementFundCache(
        databaseProvider: () async => db,
      );
      final cached = await instanceAfterRestart.read();
      final names = await instanceAfterRestart.readNames();

      expect(cached, hasLength(2));
      expect(cached.first['phone'], '3960');
      expect(names, ['Assurance retraite', 'MSA']);
    },
  );
}
