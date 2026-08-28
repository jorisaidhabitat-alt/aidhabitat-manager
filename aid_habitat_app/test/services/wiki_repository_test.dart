import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late WikiRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final localDatabase = LocalDatabase.forTesting(db);
    await localDatabase.createSchemaForTesting();
    repository = WikiRepository(database: localDatabase);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertSyncedWikiItem(String id) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('wiki_items', {
      'id': id,
      'title': 'Barre d’appui',
      'description': 'Description terrain',
      'image_url': '/wiki-access.svg',
      'tags_json': jsonEncode(['Salle de bain']),
      'category': 'Salle de bain',
      'created_at': now,
      'updated_at': now,
      'last_synced_at': now,
      'pending_image_data_url': null,
      'sync_state': SyncState.synced.name,
      'pending_delete': 0,
    });
  }

  test(
    'deleteLocalItem masque un élément synchronisé et enqueue le DELETE',
    () async {
      await insertSyncedWikiItem('wiki-1');

      await repository.deleteLocalItem('wiki-1');

      expect(await repository.fetchAllItems(), isEmpty);

      final itemRows = await db.query(
        'wiki_items',
        where: 'id = ?',
        whereArgs: const ['wiki-1'],
      );
      expect(itemRows, hasLength(1));
      expect(itemRows.single['pending_delete'], 1);
      expect(itemRows.single['sync_state'], SyncState.pendingSync.name);

      final operationRows = await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: const ['wiki_delete_wiki-1'],
      );
      expect(operationRows, hasLength(1));
      expect(operationRows.single['entity_type'], 'wiki_item');
      expect(operationRows.single['operation_type'], 'delete');

      final payload =
          jsonDecode(operationRows.single['payload_json'] as String)
              as Map<String, dynamic>;
      expect(payload['itemId'], 'wiki-1');
    },
  );

  test(
    'deleteLocalItem purge un brouillon local sans DELETE distant',
    () async {
      final draft = await repository.createLocalDraft(
        title: 'Siège de douche',
        description: 'Description',
        category: 'Salle de bain',
        tags: const ['Salle de bain'],
        imageUrl: '/wiki-bathroom.svg',
      );

      await repository.deleteLocalItem(draft.id);

      expect(await db.query('wiki_items'), isEmpty);
      expect(await db.query('sync_operations'), isEmpty);
    },
  );
}
