import 'package:flutter/material.dart';
import '../components/sidebar.dart';
import 'admin_access_screen.dart';
import 'dashboard_screen.dart';
import 'dossiers_list_screen.dart';
import 'dossier_screen.dart';
import 'retirement_funds_screen.dart';
import 'wiki_screen.dart';
import '../models/types.dart';
import '../services/auth_service.dart';
import '../services/data_service.dart';

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
  String _activeView = 'dashboard';
  Dossier? _selectedDossier;
  List<Dossier> _dossiers = [];
  int _pendingSyncCount = 0;
  bool _isSyncing = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
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

    final didRefresh = await _dataService.refreshWorkspaceFromRemote();
    if (!didRefresh) return;

    final refreshedDossiers = _authService.filterDossiersForUser(
      await _dataService.fetchDossiers(),
      widget.currentUser,
    );
    final refreshedPendingOperations = await _dataService
        .fetchPendingOperations();
    if (!mounted) return;
    setState(() {
      _dossiers = refreshedDossiers;
      _pendingSyncCount = refreshedPendingOperations.length;
    });
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

  Future<void> _handleSyncNow() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    final result = await _dataService.runSync();
    final refreshedDossiers = _authService.filterDossiersForUser(
      await _dataService.fetchDossiers(),
      widget.currentUser,
    );
    final refreshedPendingOperations = await _dataService
        .fetchPendingOperations();

    if (!mounted) return;
    setState(() {
      _isSyncing = false;
      _dossiers = refreshedDossiers;
      _pendingSyncCount = refreshedPendingOperations.length;
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
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
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(),
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
          visits:
              [], // Visits not yet fetched from DB in DataService, passing empty for now or could add fetchVisits
          dossiersCount: _dossiers.length,
          dossiers: _dossiers,
          pendingSyncCount: _pendingSyncCount,
          isSyncing: _isSyncing,
          onSyncNow: _handleSyncNow,
          onSelectDossier: _handleSelectDossier,
        );
      case 'dossiers':
        return DossiersListScreen(
          dossiers: _dossiers,
          onSelectDossier: _handleSelectDossier,
        );
      case 'wiki':
        return const WikiScreen();
      case 'precos':
        return const RetirementFundsScreen();
      case 'admin':
        return widget.currentUser.role == LocalUserRole.admin
            ? const AdminAccessScreen()
            : const Center(child: Text('Accès administrateur requis'));
      default:
        return Center(child: Text("View: $_activeView"));
    }
  }
}
