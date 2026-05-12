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
  ///
  /// Réduit à 50 ms (vs 200 ms historique) le 2026-05-06 — l'utilisateur
  /// veut que la frappe iPad apparaisse sur Mac quasi-instantanément.
  /// 50 ms suffit pour collapser une rafale de keystrokes (~1 par 100 ms
  /// pour un dactylo rapide) sans ajouter de lag perceptible.
  static const Duration _notifyDebounce = Duration(milliseconds: 50);

  /// Périodicité du `_periodicTimer` — relance le drain de la queue
  /// `sync_operations` si des opérations sont restées en `failed` après
  /// un échec réseau. Ne pousse PAS de pull (cf. refactor 2026-05-12 :
  /// suppression du polling adaptatif pour soulager NocoDB Easypanel).
  /// 5 min = compromis "retry tardif mais pas oublié" sans charge constante.
  static const Duration _periodicInterval = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // Sync model — refactor 2026-05-12
  // ---------------------------------------------------------------------------
  //
  // Avant : polling adaptatif (2s / 5s / 30s / 5min) qui consommait
  // ~9 000 calls/h/ergo vers NocoDB → saturation CPU NocoDB Easypanel
  // et explosion du quota Vercel Fast Origin Transfer.
  //
  // Maintenant : pull "à la (re)connexion" UNIQUEMENT. Aucun timer
  // récurrent. Les pulls sont déclenchés par 4 événements :
  //   1. Boot de l'app (`start()`)
  //   2. Retour foreground (`setAppLifecycleState(resumed)`)
  //   3. Retour réseau (`onConnectivityBack()`)
  //   4. Demande explicite (`requestPull()` exposé pour pull-to-refresh)
  //
  // Le PUSH (drain queue `sync_operations`) reste immédiat sur chaque
  // mutation via `notify()` (debounce 50 ms) + safety retry toutes les
  // 5 min via `_periodicTimer` pour les opérations échouées.
  //
  // Conséquence UX : sync cross-device Mac↔iPad n'est plus
  // automatique. L'utilisateur voit les modifs de l'autre device au
  // foreground return ou à la déconnexion/reconnexion. Workflow validé
  // par l'utilisateur 2026-05-12 : « on annule sync engine, il ne faut
  // pas augmenter le délai simplement actualisé à la reconnexion sur
  // l'appli ».

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

  // Pull (manuel, événementiel — plus de polling depuis 2026-05-12).
  bool _pullRunning = false;
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start the engine: run an initial sync + pull, and arm the safety net
  /// retry timer (5 min) pour rejouer les ops `failed` de la queue.
  void start() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_periodicInterval, (_) {
      // Safety net : on rejoue les `sync_operations` en attente (push
      // uniquement, pas de pull) au cas où une mutation aurait échoué
      // depuis le dernier `notify()`. Pas de pull ici — il faut un
      // événement explicite (boot/foreground/reconnect/pull-to-refresh).
      requestSync();
    });
    // Boot : sync push + pull initial pour rattraper l'état serveur.
    requestSync();
    // ignore: discarded_futures
    _runPullSafe();
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
  ///
  /// NB : ne déclenche PAS de pull. Le push immédiat suffit côté écrivain ;
  /// le device qui LIT (autre Mac/iPad) verra les modifs au prochain
  /// événement de (re)connexion ou pull-to-refresh.
  void notify() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_notifyDebounce, () {
      _scheduleImmediate();
    });
  }

  /// À appeler par l'app (`WidgetsBindingObserver.didChangeAppLifecycleState`)
  /// pour informer le SyncEngine de l'état foreground / background. Au
  /// retour en foreground on force un pull immédiat (le device a peut-être
  /// raté plusieurs minutes de modifs côté autre client).
  ///
  /// Refactor 2026-05-12 : c'est désormais l'UN DES SEULS moments où le pull
  /// se déclenche (avec boot, reconnexion réseau, et pull-to-refresh).
  void setAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final wasBackground = _appLifecycle != AppLifecycleState.resumed;
    _appLifecycle = state;
    final isResumed = state == AppLifecycleState.resumed;
    if (wasBackground && isResumed) {
      // Reprend l'app après une mise en arrière-plan → pull immédiat
      // pour rattraper d'éventuelles modifs distantes.
      // ignore: discarded_futures
      _runPullSafe();
    }
  }

  /// Pull explicite — déclenché par un pull-to-refresh utilisateur ou
  /// par tout autre point d'entrée qui veut forcer une lecture serveur.
  /// Best-effort, retourne `true` si le pull a abouti.
  Future<bool> requestPull() async {
    if (_disposed) return false;
    return _runPullSafe();
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
  Future<bool> _runPullSafe() async {
    if (_disposed || _pullRunning) return false;
    if (ConnectivityService().isOffline) return false;
    _pullRunning = true;
    try {
      final didRefresh = await DataService().refreshWorkspaceFromRemote();
      if (didRefresh && !_disposed) {
        _emitState(lastSyncAt: DateTime.now());
      }
      return didRefresh;
    } catch (_) {
      // Best-effort — un échec ne bloque pas. Le prochain événement
      // (foreground/reconnect/pull-to-refresh) retentera.
      return false;
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

  /// Called when network connectivity is restored. Resets backoff,
  /// drains the push queue, AND pulls workspace pour rattraper les
  /// modifs distantes pendant l'offline.
  ///
  /// Refactor 2026-05-12 : ajout explicite du pull (avant, seul le push
  /// était relancé — on aurait pu rester avec des données stales jusqu'au
  /// prochain foreground return).
  void onConnectivityBack() {
    if (_disposed) return;
    _consecutiveFailures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _scheduleImmediate();
    // Pull aussi pour rattraper les modifs distantes (autre Mac/iPad).
    // ignore: discarded_futures
    _runPullSafe();
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
