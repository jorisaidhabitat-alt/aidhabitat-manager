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
import 'visit_report_screen.dart';
import 'wiki_screen.dart';
import '../models/types.dart';
import '../services/auth_service.dart';
import '../services/connectivity_service.dart';
import '../services/data_service.dart';
import '../services/references_service.dart';
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
  // Dernier état "profond" visité dans l'arbre Dossiers (dossier_detail
  // ou visit_report). Utilisé pour restaurer le contexte quand l'user
  // clique à nouveau sur "Dossiers" dans la sidebar après être allé
  // ailleurs (wiki, anah, dashboard…). Un 2e clic consécutif = reset
  // vers la liste.
  String? _lastDossierTreeView;
  Dossier? _lastDossierTreeSelected;
  int _pendingSyncCount = 0;
  bool _isSyncing = false;
  bool _isLoading = true;
  bool _isOffline = false;
  String? _lastSyncError;
  // True dès que l'utilisateur a cliqué sur Anah au moins une fois — la
  // WebView est alors maintenue vivante (Offstage) pour préserver la session.
  bool _anahEverVisited = false;

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
    // Preload reference data (communes, barèmes ANAH, ...) in the
    // background so the beneficiary autocomplete + income auto-calc work
    // as soon as the user opens a dossier.
    ReferencesService().ensureLoaded();
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
    final previousPendingCount = _pendingSyncCount;
    setState(() {
      _pendingSyncCount = state.pendingCount;
      _isSyncing = state.isSyncing;
      _lastSyncError = state.lastError;
    });

    // Refresh the dossier list in two situations:
    //  1) After a sync run completes (remote pulls may have updated data).
    //  2) As soon as a new local op is enqueued (pending count goes up).
    //     This makes name / firstName / city edits visible immediately
    //     everywhere in the app, even while offline — without waiting for
    //     NocoDB to acknowledge the push.
    final newOpEnqueued = state.pendingCount > previousPendingCount;
    if ((wasSyncing && !state.isSyncing) || newOpEnqueued) {
      _refreshDossiers();
    }
  }

  Future<void> _refreshDossiers() async {
    final dossiers = _authService.filterDossiersForUser(
      await _dataService.fetchDossiers(),
      widget.currentUser,
    );
    if (!mounted) return;
    // Keep _selectedDossier in sync with the refreshed list so any edit
    // done in the dossier card (ex: numberPeople, firstName, city…) is
    // immediately visible when the user opens the visit report.
    Dossier? refreshedSelected = _selectedDossier;
    if (_selectedDossier != null) {
      try {
        refreshedSelected = dossiers.firstWhere(
          (d) => d.id == _selectedDossier!.id,
        );
      } catch (_) {
        // Not in list anymore (deleted?) — keep the last snapshot.
      }
    }
    setState(() {
      _dossiers = dossiers;
      _selectedDossier = refreshedSelected;
    });
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

    // IMPORTANT: pull BEFORE starting the sync engine. If we pushed first,
    // any lingering pending operation (captured by a previous app version
    // with potentially stale field values) would overwrite the current
    // remote state before we even saw the fresh server data.
    //
    // Running the refresh first is safe even offline: it simply returns
    // false and we fall through to starting the sync engine which will
    // push the user's legitimate offline edits as soon as connectivity
    // returns.
    final didRefresh = await _dataService.refreshWorkspaceFromRemote();
    if (didRefresh && mounted) {
      await _refreshDossiers();
    }

    // Only now kick off the sync engine. It will push any legitimate local
    // pending operations (e.g. offline edits) and schedule periodic checks.
    _syncEngine.start();
  }

  bool _isDossierTreeView(String view) =>
      view == 'dossier_detail' || view == 'visit_report';

  void _handleViewChange(String view) {
    setState(() {
      // Cas spécial : clic sur "Dossiers" dans la sidebar.
      if (view == 'dossiers') {
        final comingFromOutside = !_isDossierTreeView(_activeView)
            && _activeView != 'dossiers';
        // 1er clic après être parti ailleurs + un état profond sauvegardé
        // → restaurer exactement la page où on était (dossier_detail ou
        // visit_report du dernier bénéficiaire ouvert).
        if (comingFromOutside
            && _lastDossierTreeView != null
            && _lastDossierTreeSelected != null) {
          _activeView = _lastDossierTreeView!;
          _selectedDossier = _lastDossierTreeSelected;
          return;
        }
        // Sinon (déjà dans l'arbre, déjà sur la liste, ou pas d'état
        // sauvegardé) → liste plate. Un 2e clic consécutif tombe ici.
        _activeView = 'dossiers';
        _selectedDossier = null;
        _lastDossierTreeView = null;
        _lastDossierTreeSelected = null;
        return;
      }

      // Cas : on quitte l'arbre dossiers (vers wiki / anah / dashboard…).
      // Mémoriser le dernier état profond pour pouvoir le restaurer.
      if (_isDossierTreeView(_activeView) && !_isDossierTreeView(view)) {
        _lastDossierTreeView = _activeView;
        _lastDossierTreeSelected = _selectedDossier;
      }

      _activeView = view;
      if (view == 'anah') _anahEverVisited = true;
      if (!_isDossierTreeView(view)) {
        _selectedDossier = null;
      }
    });
  }

  void _handleSelectDossier(Dossier dossier) {
    setState(() {
      _selectedDossier = dossier;
      _activeView = 'dossier_detail';
      // Ouvrir un nouveau dossier remplace l'état profond mémorisé.
      _lastDossierTreeView = 'dossier_detail';
      _lastDossierTreeSelected = dossier;
    });
  }

  void _handleSyncNow() {
    _syncEngine.requestSync();
  }

  /// Affiche un dialog décrivant l'opération sync en échec + propose de
  /// l'ignorer définitivement. Indispensable pour débloquer le bandeau rouge
  /// quand une modif n'aboutira jamais (ressource supprimée côté serveur,
  /// payload rejeté par un backend plus strict, etc).
  Future<void> _showFailingOpDetails() async {
    final info = await _syncEngine.inspectTopFailure();
    if (!mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune opération en échec détectée.')),
      );
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Opération en échec'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('Type', '${info['entityType']} · ${info['operationType']}'),
            _kv('ID local', info['entityLocalId'] ?? '-'),
            _kv('Tentatives', info['attemptCount'] ?? '0'),
            const SizedBox(height: 8),
            const Text(
              'Erreur retournée :',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SelectableText(
                info['lastError'] ?? '(aucune)',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Fermer'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ignorer cette modification'),
          ),
        ],
      ),
    );
    if (!mounted || discard != true) return;
    final removed = await _syncEngine.discardFailedOperations();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$removed opération(s) ignorée(s)')),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 13, color: Colors.black87),
            children: [
              TextSpan(
                text: '$k : ',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: v),
            ],
          ),
        ),
      );

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
            // "dossier_detail" et "visit_report" remappent à l'entrée
            // Dossiers du menu latéral pour que la mise en surbrillance reste
            // cohérente — le menu est visible pendant ces deux écrans.
            currentView: (_activeView == 'dossier_detail' ||
                    _activeView == 'visit_report')
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
                  child: _buildConnectivityBanner(),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(
                          children: [
                            Positioned.fill(child: _buildContent()),
                            // Anah WebView : on la garde en arrière-plan dès
                            // qu'elle a été visitée au moins une fois, pour
                            // préserver la session et le scroll entre deux
                            // visites.
                            if (_anahEverVisited)
                              Positioned.fill(
                                child: Offstage(
                                  offstage: _activeView != 'anah',
                                  child: TickerMode(
                                    enabled: _activeView == 'anah',
                                    child: const AnahScreen(),
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Banner at the top of the shell. Three cases (priority order):
  ///  - offline → blue "mode hors ligne" bar
  ///  - online but sync has errors → red "sync en échec" bar with message
  ///  - online, synced → nothing
  Widget _buildConnectivityBanner() {
    if (_isOffline) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: const Color(0xFF475569),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_rounded, size: 16, color: Colors.white70),
            SizedBox(width: 8),
            Text(
              'Mode hors ligne — les modifications seront synchronisées au retour du réseau',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    if (!_isSyncing &&
        _pendingSyncCount > 0 &&
        (_lastSyncError?.isNotEmpty ?? false)) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: const Color(0xFFDC2626), // red-600
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Synchronisation en échec',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    _lastSyncError ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _showFailingOpDetails,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 2),
              ),
              child: const Text('Détails'),
            ),
            TextButton(
              onPressed: _handleSyncNow,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 2),
              ),
              child: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildContent() {
    if (_activeView == 'dossier_detail' && _selectedDossier != null) {
      return DossierScreen(
        dossier: _selectedDossier!,
        onBack: () => _handleViewChange('dossiers'),
        onOpenVisitReport: () =>
            setState(() => _activeView = 'visit_report'),
      );
    }
    if (_activeView == 'visit_report' && _selectedDossier != null) {
      return VisitReportScreen(
        dossier: _selectedDossier!,
        onBack: () async {
          // Re-fetch the dossier so the back-to-dossier view sees the
          // fresh name / city edits made inside the visit report.
          final fresh =
              await _dataService.fetchDossierById(_selectedDossier!.id);
          if (!mounted) return;
          setState(() {
            if (fresh != null) _selectedDossier = fresh;
            _activeView = 'dossier_detail';
          });
          _refreshDossiers();
        },
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
        // Le widget est géré par le Stack dans le build() — on renvoie un
        // placeholder transparent pour que l'Offstage visible prenne le focus.
        return const SizedBox.shrink();
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
