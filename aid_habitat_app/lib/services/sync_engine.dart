import 'dart:async';
import 'dart:math';

import 'nocodb_sync_service.dart';
import 'sync_repository.dart';

/// Centralized sync engine with exponential backoff, automatic retry,
/// and reactive state for UI consumption.
///
/// Usage:
///   final engine = SyncEngine();
///   engine.stateStream.listen((state) => updateUI(state));
///   engine.requestSync();       // manual trigger
///   engine.onConnectivityBack(); // called when network returns
///   engine.dispose();            // cleanup on app shutdown
class SyncEngine {
  SyncEngine({
    NocodbSyncService? syncService,
    SyncRepository? syncRepository,
  })  : _syncService = syncService ?? NocodbSyncService(),
        _syncRepository = syncRepository ?? SyncRepository();

  final NocodbSyncService _syncService;
  final SyncRepository _syncRepository;

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  static const Duration _initialDelay = Duration(seconds: 5);
  static const Duration _maxDelay = Duration(minutes: 15);
  static const double _backoffMultiplier = 3.0;
  static const int _maxConsecutiveFailures = 20;

  /// Periodic background check interval when idle and online.
  static const Duration _periodicInterval = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final _stateController = StreamController<SyncEngineState>.broadcast();
  Stream<SyncEngineState> get stateStream => _stateController.stream;

  SyncEngineState _state = const SyncEngineState();
  SyncEngineState get currentState => _state;

  Timer? _retryTimer;
  Timer? _periodicTimer;
  bool _disposed = false;
  bool _running = false;
  int _consecutiveFailures = 0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start the engine: run an initial sync attempt and schedule periodic checks.
  void start() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      requestSync();
    });
    // Kick off immediately.
    requestSync();
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _periodicTimer?.cancel();
    _stateController.close();
  }

  // ---------------------------------------------------------------------------
  // Public triggers
  // ---------------------------------------------------------------------------

  /// Request a sync cycle. Safe to call frequently — concurrent calls are
  /// coalesced into a single run.
  void requestSync() {
    if (_disposed) return;
    _scheduleImmediate();
  }

  /// Called when network connectivity is restored. Resets backoff and triggers
  /// a sync.
  void onConnectivityBack() {
    if (_disposed) return;
    _consecutiveFailures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _scheduleImmediate();
  }

  // ---------------------------------------------------------------------------
  // Internal scheduling
  // ---------------------------------------------------------------------------

  void _scheduleImmediate() {
    if (_running) return;
    // Cancel any pending retry — we're going now.
    _retryTimer?.cancel();
    _retryTimer = null;
    _runSync();
  }

  void _scheduleRetry() {
    if (_disposed || _running) return;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _emitState(
        lastError: 'Trop de tentatives échouées. '
            'Appuyez sur Synchroniser pour réessayer.',
      );
      return;
    }

    final delay = _computeBackoff(_consecutiveFailures);
    _emitState(nextRetryAt: DateTime.now().add(delay));
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!_disposed) _runSync();
    });
  }

  Duration _computeBackoff(int failures) {
    if (failures <= 0) return _initialDelay;
    final seconds = _initialDelay.inSeconds *
        pow(_backoffMultiplier, min(failures - 1, 10));
    final capped = min(seconds.toInt(), _maxDelay.inSeconds);
    // Add jitter: ±25 % to avoid thundering herd.
    final jitter = (capped * 0.25 * (Random().nextDouble() * 2 - 1)).toInt();
    return Duration(seconds: max(1, capped + jitter));
  }

  // ---------------------------------------------------------------------------
  // Core sync cycle
  // ---------------------------------------------------------------------------

  Future<void> _runSync() async {
    if (_disposed || _running) return;
    _running = true;

    // Refresh pending count for UI.
    final pendingBefore = await _refreshPendingCount();
    _emitState(isSyncing: true, pendingCount: pendingBefore);

    try {
      final result = await _syncService.pushPendingChanges();
      final pendingAfter = await _refreshPendingCount();

      if (result.failedOperations > 0) {
        _consecutiveFailures += 1;
        _running = false;
        _emitState(
          isSyncing: false,
          pendingCount: pendingAfter,
          lastError: result.message,
          lastSyncAt: DateTime.now(),
        );
        _scheduleRetry();
      } else {
        _consecutiveFailures = 0;
        _running = false;

        // Purge completed operations older than 24h to prevent DB bloat.
        _syncRepository.purgeCompleted().catchError((_) => 0);

        _emitState(
          isSyncing: false,
          pendingCount: pendingAfter,
          lastError: null,
          lastSyncAt: DateTime.now(),
          nextRetryAt: null,
        );
        // If there are still pending operations (newly enqueued during sync),
        // run again after a short delay.
        if (pendingAfter > 0) {
          _retryTimer?.cancel();
          _retryTimer = Timer(const Duration(seconds: 2), () {
            if (!_disposed) _runSync();
          });
        }
      }
    } catch (e) {
      _consecutiveFailures += 1;
      final pendingAfter = await _refreshPendingCount();
      _running = false;
      _emitState(
        isSyncing: false,
        pendingCount: pendingAfter,
        lastError: e.toString(),
        lastSyncAt: DateTime.now(),
      );
      _scheduleRetry();
    }
  }

  Future<int> _refreshPendingCount() async {
    try {
      final ops = await _syncRepository.fetchRunnableOperations();
      return ops.length;
    } catch (_) {
      return _state.pendingCount;
    }
  }

  void _emitState({
    bool? isSyncing,
    int? pendingCount,
    String? lastError,
    DateTime? lastSyncAt,
    DateTime? nextRetryAt,
  }) {
    if (_disposed) return;
    _state = SyncEngineState(
      isSyncing: isSyncing ?? _state.isSyncing,
      pendingCount: pendingCount ?? _state.pendingCount,
      lastError: lastError ?? (isSyncing == true ? null : _state.lastError),
      lastSyncAt: lastSyncAt ?? _state.lastSyncAt,
      nextRetryAt: nextRetryAt ?? _state.nextRetryAt,
    );
    _stateController.add(_state);
  }
}

/// Immutable snapshot of the sync engine state, suitable for UI binding.
class SyncEngineState {
  final bool isSyncing;
  final int pendingCount;
  final String? lastError;
  final DateTime? lastSyncAt;
  final DateTime? nextRetryAt;

  const SyncEngineState({
    this.isSyncing = false,
    this.pendingCount = 0,
    this.lastError,
    this.lastSyncAt,
    this.nextRetryAt,
  });
}
