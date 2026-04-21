import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';

class WikiRepository {
  WikiRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<WikiItem>> fetchAllItems() async {
    final db = await _database.database;
    final rows = await db.query('wiki_items', orderBy: 'updated_at DESC');
    return rows.map(_mapRow).toList();
  }

  Future<void> mergeRemoteItems(List<WikiItem> remoteItems) async {
    if (remoteItems.isEmpty) return;
    final db = await _database.database;

    await db.transaction((txn) async {
      for (final item in remoteItems) {
        final now = DateTime.now().toIso8601String();
        await txn.insert('wiki_items', {
          'id': item.id,
          'title': item.title,
          'description': item.description,
          'image_url': item.imageUrl,
          'tags_json': jsonEncode(item.tags),
          'category': item.category,
          'created_at': item.createdAt,
          'updated_at': now,
          'last_synced_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  WikiItem _mapRow(Map<String, Object?> row) {
    final tagsJson = row['tags_json'] as String? ?? '[]';
    final tags = (jsonDecode(tagsJson) as List)
        .map((tag) => tag.toString())
        .toList();

    return WikiItem(
      id: row['id'] as String,
      title: row['title'] as String,
      description: row['description'] as String,
      imageUrl: row['image_url'] as String,
      tags: tags,
      category: row['category'] as String,
      createdAt: row['created_at'] as String,
      updatedAt: row['updated_at'] as String,
    );
  }
}
