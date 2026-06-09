import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'media_cache_service.dart';
import 'offline_vault.dart';
import 'sync_engine.dart';

class WikiRepository {
  WikiRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  Future<List<WikiItem>> fetchAllItems() async {
    final db = await _database.database;
    // Alphabetical by title, case-insensitive (default collation folds
    // accents too on SQLite). Matches the user's expectation that the
    // Bibliothèque reads like a dictionary.
    final rows = await db.query('wiki_items', orderBy: 'LOWER(title) ASC');
    final out = <WikiItem>[];
    for (final row in rows) {
      out.add(await _mapRow(row));
    }
    return out;
  }

  /// Merges remote items into the local cache. Rows whose `sync_state` is
  /// not `synced` are skipped — they carry local pending mutations that
  /// haven't been pushed yet, and we must not clobber them with the server's
  /// stale view.
  Future<void> mergeRemoteItems(List<WikiItem> remoteItems) async {
    if (remoteItems.isEmpty) return;
    final db = await _database.database;

    // Set canonique des IDs remote — nécessaire pour purger les items
    // que NocoDB a supprimés (chantier sync #1).
    final remoteIds = remoteItems.map((i) => i.id).toSet();

    await db.transaction((txn) async {
      for (final item in remoteItems) {
        final existing = await txn.query(
          'wiki_items',
          columns: ['sync_state', 'updated_at'],
          where: 'id = ?',
          whereArgs: [item.id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final syncState = existing.first['sync_state'] as String?;
          if (syncState != null && syncState != SyncState.synced.name) {
            // Stratégie LWW (last-writer-wins) — fix 2026-05-07.
            // Avant : skip aveugle dès que la row était `pendingSync`,
            // ce qui bloquait définitivement la propagation cross-
            // device dès qu'une op restait orpheline en `failed`/
            // `pendingSync`. Désormais, on accepte le merge si la
            // version remote est strictement plus récente que la
            // version locale (timestamps ISO-8601). Voir
            // `_isRemoteUpdatedAtNewer` plus bas.
            final localUpdatedAt = existing.first['updated_at'] as String?;
            final remoteIsNewer = _isRemoteUpdatedAtNewer(
              remoteUpdatedAt: item.updatedAt,
              localUpdatedAt: localUpdatedAt,
            );
            if (!remoteIsNewer) {
              continue;
            }
          }
        }

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
          'pending_image_data_url': null,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // Réconciliation des suppressions remote : on supprime localement
      // toute fiche `synced` qui n'apparaît plus dans la liste NocoDB.
      // Les drafts (`local_draft_*` / sync_state != synced) sont
      // préservés. La garde `remoteIds.isNotEmpty` est implicitement
      // assurée par le `if (remoteItems.isEmpty) return;` plus haut.
      final placeholders = List.filled(remoteIds.length, '?').join(',');
      final deleted = await txn.delete(
        'wiki_items',
        where: 'sync_state = ? AND id NOT IN ($placeholders)',
        whereArgs: [SyncState.synced.name, ...remoteIds],
      );
      if (deleted > 0) {
        // ignore: avoid_print
        print(
          '[reconcile] wiki_items : $deleted ligne(s) purgée(s) '
          '(suppression remote)',
        );
      }
    });

    // Warm the media cache so wiki images display offline.
    unawaited(_prefetchImages(remoteItems));
  }

  Future<void> _prefetchImages(List<WikiItem> items) async {
    final urls = items
        .map((item) => item.imageUrl.trim())
        .where((u) => u.isNotEmpty)
        .toSet();
    if (urls.isEmpty) return;
    try {
      await MediaCacheService.instance.prefetchAll(urls);
    } catch (_) {
      // Best effort — don't fail the whole refresh when one image is down.
    }
  }

  /// Creates a wiki item locally with a temporary `local_draft_*` id and
  /// enqueues a sync operation. Returns the draft item immediately so the UI
  /// can render it offline. Once synced, the sync engine swaps the local id
  /// for the server-assigned one and clears `pending_image_data_url`.
  Future<WikiItem> createLocalDraft({
    required String title,
    required String description,
    required String category,
    required List<String> tags,
    String imageDataUrl = '',
  }) async {
    final db = await _database.database;
    final localId = _generateLocalDraftId();
    final now = DateTime.now().toIso8601String();

    final draft = WikiItem(
      id: localId,
      title: title,
      description: description,
      imageUrl: '',
      tags: tags,
      category: category,
      createdAt: now,
      updatedAt: now,
      pendingImageDataUrl: imageDataUrl,
    );

    await db.transaction((txn) async {
      await txn.insert('wiki_items', {
        'id': localId,
        'title': title,
        'description': description,
        'image_url': '',
        'tags_json': jsonEncode(tags),
        'category': category,
        'created_at': now,
        'updated_at': now,
        'last_synced_at': now,
        'pending_image_data_url': imageDataUrl.isEmpty
            ? null
            : await OfflineVault.instance.sealString(imageDataUrl),
        'sync_state': SyncState.pendingSync.name,
      });

      await _enqueueOperation(txn, {
        'id': 'wiki_create_$localId',
        'entity_type': 'wiki_item',
        'entity_local_id': localId,
        'operation_type': 'create',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'title': title,
            'description': description,
            'category': category,
            'tags': tags,
            'imageDataUrl': imageDataUrl,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    SyncEngine().notify();
    return draft;
  }

  /// Updates an existing wiki item locally and enqueues a sync operation.
  /// When [imageDataUrl] is null the image is preserved as-is. When it is
  /// a non-empty data URL, it's stored locally and pushed on next sync.
  Future<WikiItem> updateLocalItem(
    WikiItem item, {
    String? imageDataUrl,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final isDraft = item.id.startsWith('local_draft_');
    final previousRows = await db.query(
      'wiki_items',
      columns: ['title', 'description'],
      where: 'id = ?',
      whereArgs: [item.id],
      limit: 1,
    );
    final previousTitle = previousRows.isEmpty
        ? item.title
        : (previousRows.first['title'] as String? ?? item.title);
    final previousDescription = previousRows.isEmpty
        ? item.description
        : (previousRows.first['description'] as String? ?? item.description);

    await db.transaction((txn) async {
      final updates = <String, Object?>{
        'title': item.title,
        'description': item.description,
        'tags_json': jsonEncode(item.tags),
        'category': item.category,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };
      if (imageDataUrl != null && imageDataUrl.isNotEmpty) {
        updates['pending_image_data_url'] = await OfflineVault.instance
            .sealString(imageDataUrl);
      }
      await txn.update(
        'wiki_items',
        updates,
        where: 'id = ?',
        whereArgs: [item.id],
      );

      // If the row is still a local draft (never synced yet), fold the
      // edit into the existing `create` op rather than enqueueing an
      // update against an id the server has never heard of.
      if (isDraft) {
        final existingOps = await txn.query(
          'sync_operations',
          columns: ['id', 'payload_json', 'status'],
          where:
              'entity_type = ? AND entity_local_id = ? '
              'AND operation_type = ? AND status != ?',
          whereArgs: [
            'wiki_item',
            item.id,
            'create',
            SyncOperationStatus.completed.name,
          ],
          limit: 1,
        );
        if (existingOps.isNotEmpty) {
          final opId = existingOps.first['id'] as String;
          final oldPayloadRaw = await OfflineVault.instance.openString(
            existingOps.first['payload_json'] as String,
          );
          final oldPayload = jsonDecode(oldPayloadRaw) as Map<String, dynamic>;
          final mergedPayload = {
            'title': item.title,
            'description': item.description,
            'category': item.category,
            'tags': item.tags,
            'imageDataUrl': imageDataUrl ?? oldPayload['imageDataUrl'] ?? '',
          };
          await txn.update(
            'sync_operations',
            {
              'payload_json': await OfflineVault.instance.sealString(
                jsonEncode(mergedPayload),
              ),
              'status': SyncOperationStatus.pending.name,
              'updated_at': now,
              'last_error': null,
            },
            where: 'id = ?',
            whereArgs: [opId],
          );
          return;
        }
      }

      await _enqueueOperation(txn, {
        'id': 'wiki_update_${item.id}_${DateTime.now().microsecondsSinceEpoch}',
        'entity_type': 'wiki_item',
        'entity_local_id': item.id,
        'operation_type': 'update',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'itemId': item.id,
            'title': item.title,
            'description': item.description,
            'category': item.category,
            'tags': item.tags,
            if (imageDataUrl != null) 'imageDataUrl': imageDataUrl,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
    });

    await _propagateUpdateToVisitRecommendations(
      updatedItem: item.copyWith(updatedAt: now),
      previousTitle: previousTitle,
      previousDescription: previousDescription,
      now: now,
    );

    SyncEngine().notify();
    return item.copyWith(updatedAt: now);
  }

  Future<void> _propagateUpdateToVisitRecommendations({
    required WikiItem updatedItem,
    required String previousTitle,
    required String previousDescription,
    required String now,
  }) async {
    final db = await _database.database;
    final rows = await db.query('visit_recommendations');
    if (rows.isEmpty) return;

    final updatedTitle = updatedItem.title.trim();
    final previousTitleTrimmed = previousTitle.trim();
    final updatedDescription = _joinedDescriptions(updatedItem.description);
    final previousDescriptionOptions = _descriptionSyncOptions(
      previousDescription,
    );
    final updatedTags = updatedItem.tags;
    final updatedTag = updatedTags.isNotEmpty
        ? updatedTags.first
        : updatedItem.category;

    var changedAny = false;
    final rowUpdates = <_VisitRecommendationRowUpdate>[];

    for (final row in rows) {
      final dossierId = (row['dossier_local_id'] as String? ?? '').trim();
      final rawItemsJson = row['items_json'] as String? ?? '[]';
      if (dossierId.isEmpty) continue;

      final decoded = jsonDecode(rawItemsJson);
      if (decoded is! List) continue;

      var changedRow = false;
      final nextItems = decoded
          .map((entry) {
            if (entry is! Map<String, dynamic>) return entry;
            final item = VisitRecommendationItem.fromJson(entry);
            if (item.wikiItemId.trim() != updatedItem.id.trim()) {
              return item.toJson();
            }

            final currentCustomTitle = item.customTitle.trim();
            final shouldSyncTitle =
                currentCustomTitle.isEmpty ||
                currentCustomTitle == previousTitleTrimmed ||
                currentCustomTitle == item.wikiTitle.trim();
            final nextCustomTitle = shouldSyncTitle
                ? updatedTitle
                : item.customTitle;
            final nextNote = _syncedRecommendationNote(
              currentNote: item.note,
              previousOptions: previousDescriptionOptions,
              updatedDescription: updatedDescription,
            );
            final nextItem = item.copyWith(
              wikiTitle: updatedTitle,
              wikiImageUrl: updatedItem.imageUrl,
              wikiTag: updatedTag,
              wikiDescription: updatedDescription,
              customTitle: nextCustomTitle,
              note: nextNote,
              updatedAt: now,
            );

            final nextJson = nextItem.toJson();
            if (jsonEncode(nextJson) != jsonEncode(item.toJson())) {
              changedRow = true;
            }
            return nextJson;
          })
          .toList(growable: false);

      if (!changedRow) continue;
      changedAny = true;
      rowUpdates.add(
        _VisitRecommendationRowUpdate(
          dossierId: dossierId,
          itemsJson: jsonEncode(nextItems),
          syncItems: nextItems
              .whereType<Map<String, dynamic>>()
              .where((item) => (item['wikiItemId'] as String? ?? '').isNotEmpty)
              .toList(growable: false),
        ),
      );
    }

    if (!changedAny || rowUpdates.isEmpty) return;

    await db.transaction((txn) async {
      for (final update in rowUpdates) {
        await txn.update(
          'visit_recommendations',
          {
            'items_json': update.itemsJson,
            'updated_at': now,
            'sync_state': SyncState.pendingSync.name,
          },
          where: 'dossier_local_id = ?',
          whereArgs: [update.dossierId],
        );

        await txn.insert('sync_operations', {
          'id': 'visitrec_update_${update.dossierId}',
          'entity_type': 'visit_recommendations',
          'entity_local_id': update.dossierId,
          'operation_type': 'update',
          'payload_json': await OfflineVault.instance.sealString(
            jsonEncode({
              'dossierId': update.dossierId,
              'items': update.syncItems,
            }),
          ),
          'status': SyncOperationStatus.pending.name,
          'attempt_count': 0,
          'last_error': null,
          'created_at': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Returns the base64 data URL of the locally-stored pending image for
  /// [itemId], if any. Used by the UI to show the just-captured image while
  /// the sync hasn't uploaded it yet.
  Future<String?> fetchPendingImageDataUrl(String itemId) async {
    final db = await _database.database;
    final rows = await db.query(
      'wiki_items',
      columns: ['pending_image_data_url'],
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['pending_image_data_url'] as String?;
    if (value == null || value.isEmpty) return null;
    return OfflineVault.instance.openString(value);
  }

  Future<void> _enqueueOperation(
    Transaction txn,
    Map<String, Object?> row,
  ) async {
    final rowAtRest = Map<String, Object?>.from(row);
    final payload = rowAtRest['payload_json'];
    if (payload is String && payload.isNotEmpty) {
      rowAtRest['payload_json'] = await OfflineVault.instance.sealString(
        payload,
      );
    }
    await txn.insert(
      'sync_operations',
      rowAtRest,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String _generateLocalDraftId() {
    final rand = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => rand.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'local_draft_$suffix';
  }

  Future<WikiItem> _mapRow(Map<String, Object?> row) async {
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
      pendingImageDataUrl: await OfflineVault.instance.openString(
        (row['pending_image_data_url'] as String?) ?? '',
      ),
    );
  }

  /// Compare deux timestamps ISO-8601 pour décider si la version remote
  /// est strictement plus récente que la version locale. Renvoie `false`
  /// si timestamp manquant/invalide (= refuse le merge, comportement
  /// safe). Cf. parité avec note_repository / document_repository.
  bool _isRemoteUpdatedAtNewer({
    required String? remoteUpdatedAt,
    required String? localUpdatedAt,
  }) {
    if (remoteUpdatedAt == null || remoteUpdatedAt.isEmpty) return false;
    if (localUpdatedAt == null || localUpdatedAt.isEmpty) return true;
    final remote = DateTime.tryParse(remoteUpdatedAt);
    final local = DateTime.tryParse(localUpdatedAt);
    if (remote == null || local == null) return false;
    return remote.isAfter(local);
  }
}

class _VisitRecommendationRowUpdate {
  const _VisitRecommendationRowUpdate({
    required this.dossierId,
    required this.itemsJson,
    required this.syncItems,
  });

  final String dossierId;
  final String itemsJson;
  final List<Map<String, dynamic>> syncItems;
}

List<String> _descriptionsFromStored(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        return decoded
            .map((entry) => entry?.toString().trim() ?? '')
            .where((entry) => entry.isNotEmpty)
            .take(WikiItem.maxDescriptions)
            .toList(growable: false);
      }
    } catch (_) {
      // Legacy plain text fallback below.
    }
  }
  return [trimmed];
}

String _joinedDescriptions(String raw) {
  final descriptions = _descriptionsFromStored(raw);
  if (descriptions.isEmpty) return '';
  return descriptions.first;
}

Set<String> _descriptionSyncOptions(String raw) {
  final descriptions = _descriptionsFromStored(raw);
  final options = <String>{};
  final trimmed = raw.trim();
  if (trimmed.isNotEmpty) options.add(trimmed);
  options.addAll(descriptions);
  final joined = descriptions.join('\n\n').trim();
  if (joined.isNotEmpty) options.add(joined);
  return options;
}

String _syncedRecommendationNote({
  required String currentNote,
  required Set<String> previousOptions,
  required String updatedDescription,
}) {
  final trimmed = currentNote.trim();
  if (trimmed.isEmpty) return currentNote;
  if (!previousOptions.contains(trimmed)) return currentNote;
  return updatedDescription;
}
