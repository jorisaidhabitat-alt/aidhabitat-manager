import 'dart:async';

import 'package:flutter/material.dart';
import '../components/sidebar.dart';
import 'admin_access_screen.dart';
import 'anah_screen.dart';
import 'create_beneficiary_screen.dart';
import 'dashboard_screen.dart';
import 'dossiers_list_screen.dart';
import 'dossier_screen.dart';
import 'retirement_funds_screen.dart';
import 'settings_screen.dart';
import 'wiki_screen.dart';
import '../models/types.dart';
import '../services/auth_service.dart';
import '../services/connectivity_service.dart';
import '../services/data_service.dart';
import '../services/sync_engine.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.currentUser,
    required this.onLogout,
  });

  final LocalAppUser currentUser;
  final Future<void> Function() onLogout;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final DataService _dataService = DataService();
  final AuthService _authService = AuthService();
  late final SyncEngine _syncEngine;
  StreamSubscription<SyncEngineState>? _syncSubscription;
  StreamSubscription<bool>? _connectivitySubscription;

  String _activeView = 'dashboard';
  Dossier? _selectedDossier;
  List<Dossier> _dossiers = [];
  int _pendingSyncCount = 0;
  bool _isSyncing = false;
  bool _isLoading = true;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _syncEngine = SyncEngine();
    final connectivity = ConnectivityService();
    connectivity.bindSyncEngine(_syncEngine);
    _isOffline = connectivity.isOffline;

    _syncSubscription = _syncEngine.stateStream.listen(_onSyncStateChanged);
    _connectivitySubscription = connectivity.offlineStream.listen((offline) {
      if (mounted) setState(() => _isOffline = offline);
    });
    _loadData();
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    _connectivitySubscription?.cancel();
    // SyncEngine is a process-lifetime singleton — do not dispose it with the
    // screen, or later screens will lose the stream and the engine.
    super.dispose();
  }

  void _onSyncStateChanged(SyncEngineState state) {
    if (!mounted) return;

    final wasSyncing = _isSyncing;
    setState(() {
      _pendingSyncCount = state.pendingCount;
      _isSyncing = state.isSyncing;
    });

    // When a sync run finishes, refresh the dossier list to reflect any
    // remote changes that were pulled or local states that were updated.
    if (wasSyncing && !state.isSyncing) {
      _refreshDossiers();
    }
  }

  Future<void> _refreshDossiers() async {
    final dossiers = _authService.filterDossiersForUser(
      await _dataService.fetchDossiers(),
      widget.currentUser,
    );
    if (!mounted) return;
    setState(() => _dossiers = dossiers);
  }

  Future<void> _loadData() async {
    final dossiers = _authService.filterDossiersForUser(
      await _dataService.fetchDossiers(),
      widget.currentUser,
    );
    final pendingOperations = await _dataService.fetchPendingOperations();
    if (mounted) {
      setState(() {
        _dossiers = dossiers;
        _pendingSyncCount = pendingOperations.length;
        _isLoading = false;
      });
    }

    // Start the sync engine — it will handle initial push + periodic refresh.
    _syncEngine.start();

    // Also pull remote dossiers for the initial view.
    final didRefresh = await _dataService.refreshWorkspaceFromRemote();
    if (!didRefresh || !mounted) return;
    await _refreshDossiers();
  }

  void _handleViewChange(String view) {
    setState(() {
      _activeView = view;
      if (view != 'dossier_detail') {
        _selectedDossier = null;
      }
    });
  }

  void _handleSelectDossier(Dossier dossier) {
    setState(() {
      _selectedDossier = dossier;
      _activeView = 'dossier_detail';
    });
  }

  void _handleSyncNow() {
    _syncEngine.requestSync();
  }

  void _handleCreateNew() {
    setState(() => _activeView = 'create_beneficiary');
  }

  Future<void> _handleBeneficiaryCreated(
    String firstName,
    String lastName,
  ) async {
    final ergoId = widget.currentUser.ergoLabel ?? '';
    final dossier = await _dataService.createDossierOffline(
      firstName: firstName,
      lastName: lastName,
      ergoId: ergoId,
    );

    // Refresh the dossier list and navigate to the new dossier.
    await _refreshDossiers();
    if (!mounted) return;

    // Trigger a sync attempt for the newly created dossier.
    _syncEngine.requestSync();

    setState(() {
      _selectedDossier = dossier;
      _activeView = 'dossier_detail';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Sidebar(
            currentUser: widget.currentUser,
            currentView: _activeView == 'dossier_detail'
                ? 'dossiers'
                : _activeView,
            onNavigate: _handleViewChange,
            onLogout: widget.onLogout,
            pendingSyncCount: _pendingSyncCount,
            isSyncing: _isSyncing,
            onSyncTap: _handleSyncNow,
          ),
          Expanded(
            child: Column(
              children: [
                // Offline banner
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  child: _isOffline
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          color: const Color(0xFF475569), // slate-600
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.wifi_off_rounded,
                                size: 16,
                                color: Colors.white70,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Mode hors ligne — les modifications seront synchronisees au retour du reseau',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _buildContent(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_activeView == 'dossier_detail' && _selectedDossier != null) {
      return DossierScreen(
        dossier: _selectedDossier!,
        onBack: () => _handleViewChange('dossiers'),
      );
    }

    switch (_activeView) {
      case 'dashboard':
        return DashboardScreen(
          visits: [],
          dossiersCount: _dossiers.length,
          dossiers: _dossiers,
          pendingSyncCount: _pendingSyncCount,
          isSyncing: _isSyncing,
          onSyncNow: _handleSyncNow,
          onSelectDossier: _handleSelectDossier,
          userName: widget.currentUser.displayName,
          onNavigateToDossiers: () => _handleViewChange('dossiers'),
        );
      case 'create_beneficiary':
        return CreateBeneficiaryScreen(
          onCreated: _handleBeneficiaryCreated,
          onCancel: () => _handleViewChange('dossiers'),
        );
      case 'dossiers':
        return DossiersListScreen(
          dossiers: _dossiers,
          onSelectDossier: _handleSelectDossier,
          onCreateNew: _handleCreateNew,
        );
      case 'wiki':
        return const WikiScreen();
      case 'precos':
        return const RetirementFundsScreen();
      case 'anah':
        return const AnahScreen();
      case 'admin':
        return widget.currentUser.role == LocalUserRole.admin
            ? const AdminAccessScreen()
            : const Center(child: Text('Accès administrateur requis'));
      case 'settings':
        return SettingsScreen(
          user: widget.currentUser,
          onLogout: widget.onLogout,
        );
      default:
        return Center(child: Text("View: $_activeView"));
    }
  }

}
