import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'sync_engine.dart';

class ConnectivityService {
  ConnectivityService._internal();

  static final ConnectivityService _instance = ConnectivityService._internal();

  factory ConnectivityService() => _instance;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _wasOffline = false;
  bool _isCurrentlyOffline = true;

  SyncEngine? _syncEngine;
  final _offlineController = StreamController<bool>.broadcast();

  /// Bind a [SyncEngine] so connectivity changes trigger sync automatically.
  void bindSyncEngine(SyncEngine engine) {
    _syncEngine = engine;
  }

  /// Whether the device currently has no network connectivity.
  bool get isOffline => _isCurrentlyOffline;

  /// Stream of connectivity state changes (true = offline).
  Stream<bool> get offlineStream => _offlineController.stream;

  Future<void> initialize() async {
    final results = await _connectivity.checkConnectivity();
    _wasOffline = _isOffline(results);
    _isCurrentlyOffline = _wasOffline;

    _subscription = _connectivity.onConnectivityChanged.listen(_onChanged);
  }

  void _onChanged(List<ConnectivityResult> results) {
    final offline = _isOffline(results);
    final changed = offline != _isCurrentlyOffline;
    _isCurrentlyOffline = offline;

    if (changed) {
      _offlineController.add(offline);
    }

    if (_wasOffline && !offline) {
      _syncEngine?.onConnectivityBack();
    }

    _wasOffline = offline;
  }

  bool _isOffline(List<ConnectivityResult> results) {
    return results.every((r) => r == ConnectivityResult.none);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
