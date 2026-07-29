import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_engine.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';

void main() {
  test('le drain attend que la session distante soit restaurée', () async {
    final repository = _FakeSyncRepository();
    final service = _FakeSyncService();
    final sessionReady = Completer<bool>();
    final engine = SyncEngine.testing(
      syncService: service,
      syncRepository: repository,
    );
    engine.bindRemoteSessionPreparer(() => sessionReady.future);

    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(service.pushCalls, 0);

    sessionReady.complete(true);
    await _waitUntil(() => service.pushCalls == 1);

    expect(service.pushCalls, 1);
    engine.dispose();
  });

  test(
    'une restauration différée peut être relancée sans perdre la file',
    () async {
      final repository = _FakeSyncRepository();
      final service = _FakeSyncService();
      final engine = SyncEngine.testing(
        syncService: service,
        syncRepository: repository,
      );
      var attempts = 0;
      engine.bindRemoteSessionPreparer(() async {
        attempts += 1;
        return attempts > 1;
      });

      engine.start();
      await _waitUntil(() => attempts == 1);
      expect(service.pushCalls, 0);
      expect(repository.pendingCount, 1);

      engine.requestSync();
      await _waitUntil(() => service.pushCalls == 1);

      expect(attempts, 2);
      expect(service.pushCalls, 1);
      expect(repository.pendingCount, 1);
      engine.dispose();
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition non satisfaite avant le délai');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeSyncRepository extends SyncRepository {
  _FakeSyncRepository()
    : super(
        databaseProvider: () async {
          throw StateError('La base ne doit pas être ouverte dans ce test');
        },
      );

  int pendingCount = 1;

  @override
  Future<int> countPendingOperations() async => pendingCount;

  @override
  Future<Map<String, String?>?> fetchTopFailingOperation() async => null;

  @override
  Future<int> purgeCompleted({
    Duration maxAge = const Duration(hours: 24),
  }) async => 0;
}

class _FakeSyncService extends NocodbSyncService {
  int pushCalls = 0;

  @override
  Future<SyncRunResult> pushPendingChanges() async {
    pushCalls += 1;
    return const SyncRunResult(
      pushedOperations: 0,
      failedOperations: 0,
      message: 'Synchronisation terminée',
    );
  }
}
