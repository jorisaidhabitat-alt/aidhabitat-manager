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
  SyncEngine._internal({
    NocodbSyncService? syncService,
    SyncRepository? syncRepository,
  })  : _syncService = syncService ?? NocodbSyncService(),
        _syncRepository = syncRepository ?? SyncRepository();

  static final SyncEngine _instance = SyncEngine._internal();

  /// Singleton accessor. Repositories call [SyncEngine()] to notify the engine
  /// after enqueuing a local mutation.
  factory SyncEngine({
    NocodbSyncService? syncService,
    SyncRepository? syncRepository,
  }) => _instance;

  final NocodbSyncService _syncService;
  final SyncRepository _syncRepository;

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  static const Duration _initialDelay = Duration(seconds: 2);
  static const Duration _maxDelay = Duration(minutes: 5);
  static const double _backoffMultiplier = 2.5;
  static const int _maxConsecutiveFailures = 10;

  /// Debounce window for push-on-mutation. Rapid successive mutations (e.g.
  /// while the user types) collapse into a single sync cycle.
  static const Duration _notifyDebounce = Duration(milliseconds: 200);

  /// Periodic background check interval when idle and online. Short safety net
  /// — push-on-mutation should handle most cases.
  static const Duration _periodicInterval = Duration(seconds: 60);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final _stateController = StreamController<SyncEngineState>.broadcast();
  Stream<SyncEngineState> get stateStream => _stateController.stream;

  SyncEngineState _state = const SyncEngineState();
  SyncEngineState get currentState => _state;

  Timer? _retryTimer;
  Timer? _periodicTimer;
  Timer? _debounceTimer;
  bool _disposed = false;
  bool _running = false;
  bool _rerunRequested = false;
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
    _debounceTimer?.cancel();
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

  /// Push-on-mutation entry point. Called by repositories right after they
  /// enqueue a `sync_operations` row. Debounces rapid bursts so the engine
  /// fires exactly one sync cycle shortly after a flurry of edits.
  void notify() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_notifyDebounce, () {
      _scheduleImmediate();
    });
  }

  /// Renvoie un résumé de la première opération en échec (pour UI).
  Future<Map<String, String?>?> inspectTopFailure() =>
      _syncRepository.fetchTopFailingOperation();

  /// Supprime toutes les opérations en `failed` et réinitialise le compteur
  /// de retries → débloque le bandeau rouge quand une modif ne pourra jamais
  /// aboutir (ex: doc déjà supprimé côté serveur).
  Future<int> discardFailedOperations() async {
    final removed = await _syncRepository.discardFailedOperations();
    _consecutiveFailures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    final pending = await _refreshPendingCount();
    _emitState(
      pendingCount: pending,
      clearError: true,
      nextRetryAt: null,
    );
    return removed;
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
    if (_running) {
      // A sync is already in flight. Queue another cycle so any mutations
      // that land during this run get pushed right after.
      _rerunRequested = true;
      return;
    }
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
          clearError: true,
          lastSyncAt: DateTime.now(),
          nextRetryAt: null,
        );
        // Ne relance immédiatement QUE si :
        //  - une nouvelle mutation est arrivée pendant le cycle, OU
        //  - on a effectivement poussé quelque chose ET il reste des
        //    ops en file (il y a peut-être un follow-up à envoyer).
        // Si le cycle n'a rien poussé (p. ex. toutes les ops restantes
        // sont en backoff transitoire), on laisse le timer périodique
        // les reprendre plus tard — évite un tight-loop qui spammerait
        // CPU + serveur pour rien.
        final shouldRerun = _rerunRequested ||
            (result.pushedOperations > 0 && pendingAfter > 0);
        if (shouldRerun) {
          _rerunRequested = false;
          scheduleMicrotask(() {
            if (!_disposed) _scheduleImmediate();
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
      // Total des ops `pending`/`failed`, indépendamment du backoff.
      // L'UI doit refléter qu'il y a toujours du travail en file même
      // si rien n'est exécuté pour l'instant (ops en cours de backoff).
      return await _syncRepository.countPendingOperations();
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
    bool clearError = false,
  }) {
    if (_disposed) return;
    _state = SyncEngineState(
      isSyncing: isSyncing ?? _state.isSyncing,
      pendingCount: pendingCount ?? _state.pendingCount,
      lastError: clearError
          ? null
          : (lastError ?? (isSyncing == true ? null : _state.lastError)),
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
