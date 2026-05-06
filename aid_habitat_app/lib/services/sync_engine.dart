import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'connectivity_service.dart';
import 'data_service.dart';
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
  // Adaptive pull (cross-device sync) — demande utilisateur 2026-04-29
  // « tout ce que je fais sur macOS s'actualise sur iPad et inversement
  // en moins de 5 secondes » (Option B : polling adaptatif).
  // ---------------------------------------------------------------------------

  /// Délai entre 2 pulls quand l'utilisateur est ACTIF (a sauvegardé
  /// quelque chose dans la dernière minute). Cible la sensation
  /// « instant » sur le device qui regarde — l'autre device pousse à
  /// NocoDB en ~500ms, le poll de 5s récupère à 5500ms max.
  static const Duration _pullIntervalActive = Duration(seconds: 5);

  /// Délai entre 2 pulls quand un écran « focus haute fréquence » est
  /// ouvert (ex. VisitReportScreen via [enterActiveContext]). Cible
  /// la sensation « tape sur iPad → apparait sur Mac » sub-3 sec.
  /// L'intervalle reste raisonnable pour ne pas marteler NocoDB ni
  /// vider la batterie iPad — push iPad ~600 ms + poll Mac max 2 s
  /// = lag visible < 3 s au pire (demande utilisateur 2026-05-06 :
  /// note écrite VAD doit s'actualiser quasi-instantanément Mac↔iPad).
  static const Duration _pullIntervalUltraActive = Duration(seconds: 2);

  /// Délai entre 2 pulls quand l'utilisateur est IDLE (pas de save
  /// depuis ≥ 1 minute). Économise la bande passante quand personne ne
  /// modifie côté autre device — l'app reste à jour sans spammer.
  static const Duration _pullIntervalIdle = Duration(seconds: 30);

  /// Délai entre 2 pulls quand l'app est en arrière-plan. Préserve la
  /// batterie + le quota cellulaire — au retour foreground on
  /// déclenche un pull immédiat dans `setAppLifecycleState`.
  static const Duration _pullIntervalBackground = Duration(minutes: 5);

  /// Seuil au-delà duquel on bascule de "active" à "idle" (mesuré
  /// depuis la dernière mutation `notify()`).
  static const Duration _idleThreshold = Duration(minutes: 1);

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

  // Pull adaptatif (cross-device).
  Timer? _pullTimer;
  bool _pullRunning = false;
  DateTime _lastInteractionAt = DateTime.now();
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  /// Compteur d'écrans ayant déclaré un focus haute fréquence via
  /// [enterActiveContext]. Tant qu'il est > 0, [_currentPullInterval]
  /// renvoie [_pullIntervalUltraActive] (2 s) au lieu de 5 s/30 s.
  /// Ref-counted pour gérer plusieurs écrans empilés (ex. VAD ouvre
  /// le NotesWindow → 2 demandes, 1 seule vraiment active).
  int _activeContextRefCount = 0;

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
    // Lance le pull adaptatif (cross-device sync).
    _schedulePull();
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _periodicTimer?.cancel();
    _debounceTimer?.cancel();
    _pullTimer?.cancel();
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
    // Marque l'utilisateur comme "actif" — utilisé par le pull adaptatif
    // pour passer en intervalle 5s (au lieu de 30s idle).
    _lastInteractionAt = DateTime.now();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_notifyDebounce, () {
      _scheduleImmediate();
    });
  }

  /// À appeler par l'app (`WidgetsBindingObserver.didChangeAppLifecycleState`)
  /// pour informer le SyncEngine de l'état foreground / background. Au
  /// retour en foreground on force un pull immédiat (le device a peut-être
  /// raté plusieurs minutes de modifs côté autre client).
  void setAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final wasBackground = _appLifecycle != AppLifecycleState.resumed;
    _appLifecycle = state;
    final isResumed = state == AppLifecycleState.resumed;
    if (wasBackground && isResumed) {
      // Reprend l'app après une mise en arrière-plan → pull immédiat
      // pour rattraper d'éventuelles modifs distantes.
      _runPullSafe();
    }
    // Dans tous les cas, re-planifie le prochain pull avec le bon
    // intervalle (active 5s / idle 30s / background 5min).
    _schedulePull();
  }

  /// Déclare qu'un écran sensible aux modifs distantes vient d'être
  /// ouvert — tant qu'il y a au moins un appelant en cours, le pull
  /// passe en mode ultra-actif (2 s) pour donner une sensation
  /// quasi-instantanée Mac↔iPad. À appeler dans `initState`, à
  /// équilibrer avec [leaveActiveContext] dans `dispose`.
  ///
  /// Idempotent côté ref-count, mais chaque enter doit avoir son leave
  /// pour ne pas figer le mode ultra-actif quand l'écran disparait.
  /// Re-planifie immédiatement le prochain pull avec le nouvel
  /// intervalle (sinon on attend la fin du timer 30 s en cours).
  void enterActiveContext() {
    if (_disposed) return;
    _activeContextRefCount += 1;
    if (_activeContextRefCount == 1) {
      _schedulePull();
    }
  }

  /// Pendant inverse de [enterActiveContext]. Le compteur ne descend
  /// jamais en dessous de 0 (sécurité contre un dispose() appelé sans
  /// initState() correspondant — ex. hot reload qui rejoue dispose).
  void leaveActiveContext() {
    if (_disposed) return;
    if (_activeContextRefCount > 0) {
      _activeContextRefCount -= 1;
    }
    if (_activeContextRefCount == 0) {
      _schedulePull();
    }
  }

  /// Calcule l'intervalle entre 2 pulls en fonction de l'état courant :
  ///   - background → 5min
  ///   - écran « focus haute fréquence » ouvert → 2s (ultra-actif)
  ///   - foreground actif (save < 1min) → 5s
  ///   - foreground idle → 30s
  Duration _currentPullInterval() {
    if (_appLifecycle != AppLifecycleState.resumed) {
      return _pullIntervalBackground;
    }
    if (_activeContextRefCount > 0) return _pullIntervalUltraActive;
    final idle = DateTime.now().difference(_lastInteractionAt);
    if (idle < _idleThreshold) return _pullIntervalActive;
    return _pullIntervalIdle;
  }

  /// (Re)planifie le prochain pull. Pattern récursif (pas Timer.periodic)
  /// pour pouvoir adapter l'intervalle à chaque tick selon l'état actif/idle.
  void _schedulePull() {
    if (_disposed) return;
    _pullTimer?.cancel();
    _pullTimer = Timer(_currentPullInterval(), () async {
      await _runPullSafe();
      _schedulePull();
    });
  }

  /// Exécute un pull workspace si online + non disposé + pas déjà en cours.
  /// Toutes les erreurs sont avalées (le pull est best-effort, ne doit
  /// jamais bloquer l'utilisateur).
  ///
  /// IMPORTANT 2026-05-06 : émet un état avec `lastSyncAt = now` à
  /// chaque pull RÉUSSI, pour que les écrans ouverts (VisitReportScreen,
  /// NotesWidget, MainScreen…) puissent re-fetch SQLite et afficher les
  /// changements arrivés depuis l'autre device. Sans cette émission, le
  /// pull mettait à jour SQLite « en silence » et l'UI continuait à
  /// rendre le snapshot du moment de l'ouverture (symptôme reporté :
  /// date de naissance + notes BALS Joris non synchronisées entre Mac
  /// et iPad sur l'écran VAD).
  Future<void> _runPullSafe() async {
    if (_disposed || _pullRunning) return;
    if (ConnectivityService().isOffline) return;
    _pullRunning = true;
    try {
      final didRefresh = await DataService().refreshWorkspaceFromRemote();
      if (didRefresh && !_disposed) {
        _emitState(lastSyncAt: DateTime.now());
      }
    } catch (_) {
      // Best-effort — un échec ne bloque pas, on retente au prochain tick.
    } finally {
      _pullRunning = false;
    }
  }

  /// Renvoie un résumé de la première opération en échec (pour UI).
  Future<Map<String, String?>?> inspectTopFailure() =>
      _syncRepository.fetchTopFailingOperation();

  /// Re-queue toutes les opérations en `failed` (passe à `pending`,
  /// reset attempt_count) → utilisé par le bouton « Réessayer
  /// maintenant » du dialog d'erreur sync. Le caller appelle
  /// généralement `requestSync()` juste après pour kick le retry sans
  /// attendre le prochain tick.
  Future<int> retryFailedOperations() async {
    final reset = await _syncRepository.resetFailedToPending();
    _consecutiveFailures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    final pending = await _refreshPendingCount();
    _emitState(
      pendingCount: pending,
      clearError: true,
      nextRetryAt: null,
    );
    return reset;
  }

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
