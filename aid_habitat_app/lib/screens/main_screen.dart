import 'dart:async';

import 'package:flutter/material.dart';
import '../components/sidebar.dart';
import '../components/soft_transitions.dart';
import 'anah_screen.dart';
import 'create_beneficiary_screen.dart';
import 'dashboard_screen.dart';
import 'documents_screen.dart';
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

class _MainScreenState extends State<MainScreen>
    with WidgetsBindingObserver {
  final DataService _dataService = DataService();
  final AuthService _authService = AuthService();
  late final SyncEngine _syncEngine;
  StreamSubscription<SyncEngineState>? _syncSubscription;
  StreamSubscription<bool>? _connectivitySubscription;

  String _activeView = 'dashboard';
  Dossier? _selectedDossier;
  List<Dossier> _dossiers = [];
  // Pile d'historique de navigation : chaque entrée capture (view,
  // dossier) de l'écran quitté. La flèche "retour" des écrans profonds
  // (DossierScreen / VisitReportScreen) dépile pour ramener l'utilisateur
  // exactement où il était avant — ex. Dashboard → dossier → retour
  // revient sur le Dashboard, Dossiers → dossier → retour revient à la
  // liste. Limité à 50 entrées pour éviter la dérive mémoire.
  final List<_NavEntry> _navHistory = [];
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
    // Observer du cycle de vie de l'app — utilisé par le SyncEngine
    // pour adapter l'intervalle de pull (foreground actif 5s / idle
    // 30s / background 5min). Cf. SyncEngine.setAppLifecycleState.
    WidgetsBinding.instance.addObserver(this);
    _syncEngine = SyncEngine();
    final connectivity = ConnectivityService();
    connectivity.bindSyncEngine(_syncEngine);
    _isOffline = connectivity.isOffline;

    _syncSubscription = _syncEngine.stateStream.listen(_onSyncStateChanged);
    _connectivitySubscription = connectivity.offlineStream.listen((offline) {
      if (mounted) setState(() => _isOffline = offline);
    });
    // Préchargement parallèle de TOUTES les données du workspace dès
    // l'arrivée sur l'écran principal — sans bloquer le rendu. Sans ça,
    // chaque écran (Bibliothèque, Caisses de retraite, …) faisait son
    // propre fetch à sa première ouverture après login → l'user voyait
    // une grille vide pendant 1-3s sur iPad PWA.
    //
    // Maintenant : tout fetch en parallèle pendant que l'user regarde
    // le dashboard. Quand il navigue vers Bibliothèque ou Caisses, la
    // SQLite locale est déjà chaude → rendu instantané depuis le
    // cache, et le refresh remote interne au screen est un no-op (les
    // données sont déjà mergées).
    //
    // Ces appels sont best-effort : ils échouent silencieusement si on
    // est offline, et chaque écran a son propre fallback offline-first
    // sur le cache SQLite de toute façon.
    // ignore: discarded_futures
    ReferencesService().ensureLoaded();
    // ignore: discarded_futures
    _dataService.refreshWikiItemsFromRemote();
    // ignore: discarded_futures
    _dataService.refreshRetirementFundsFromRemote();
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncSubscription?.cancel();
    _connectivitySubscription?.cancel();
    // SyncEngine is a process-lifetime singleton — do not dispose it with the
    // screen, or later screens will lose the stream and the engine.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Notifie le SyncEngine pour qu'il adapte son intervalle de pull :
    //   - resumed (foreground) → 5s actif / 30s idle
    //   - inactive / paused / hidden / detached → 5min
    // Au retour foreground après un détour background, un pull immédiat
    // est aussi déclenché côté SyncEngine pour rattraper d'éventuelles
    // modifs distantes manquées (cf. setAppLifecycleState).
    _syncEngine.setAppLifecycleState(state);
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
    // Pousser l'écran courant dans l'historique seulement si on change
    // vraiment de vue (évite d'empiler les doublons lors d'un re-clic
    // sur l'onglet actif).
    if (view != _activeView) {
      _pushHistory();
    }
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
    _pushHistory();
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
    // Le dialog renvoie une string-clé d'action :
    //  • 'retry'   → relance la sync immédiatement (ne ferme pas l'op,
    //               la requeue pour un essai instantané, utile sur
    //               glitch réseau transitoire)
    //  • 'discard' → ignore définitivement la modif locale
    //  • null/autre → fermeture sans action (l'op reste en queue et
    //                  retentera au prochain cycle 5s)
    final action = await showSoftDialog<String>(
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
            const SizedBox(height: 12),
            // Hint UX : la plupart des "fetch failed" sont des glitches
            // réseau transitoires. On invite à réessayer avant de
            // proposer d'ignorer définitivement.
            const Text(
              'Astuce : si l\'erreur ressemble à un problème réseau '
              '("fetch failed", "timeout"…), réessaie maintenant. La '
              'modif est encore en queue, n\'ignore que si tu sais '
              'qu\'elle ne pourra jamais aboutir.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'close'),
            child: const Text('Fermer'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: const Text('Réessayer maintenant'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Ignorer cette modification'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'retry') {
      // Reset attempt_count + lastError de l'op fautive, puis kick le
      // sync engine pour un retry immédiat (sans attendre le tick).
      await _syncEngine.retryFailedOperations();
      _syncEngine.requestSync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Synchronisation relancée…')),
      );
      return;
    }
    if (action == 'discard') {
      final removed = await _syncEngine.discardFailedOperations();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$removed opération(s) ignorée(s)')),
      );
    }
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
    _pushHistory();
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
            // "dossier_detail", "visit_report" et "documents" remappent
            // à l'entrée Dossiers du menu latéral pour que la mise en
            // surbrillance reste cohérente — la sidebar est visible
            // pendant ces 3 écrans (cf. demande utilisateur 2026-04-29
            // qui voulait voir la sidebar sur Documents aussi).
            currentView: (_activeView == 'dossier_detail' ||
                    _activeView == 'visit_report' ||
                    _activeView == 'documents')
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
                            // Transition douce (fade + slide 8 px) entre
                            // chaque vue — on assigne une Key unique à
                            // `_buildContent()` pour que l'AnimatedSwitcher
                            // détecte un changement et joue l'animation.
                            Positioned.fill(
                              child: SoftSwitcher(
                                child: KeyedSubtree(
                                  key: ValueKey<String>(_contentKey()),
                                  child: _buildContent(),
                                ),
                              ),
                            ),
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
    // L'indicateur "Mode hors-ligne" n'apparaît plus globalement — il est
    // rendu uniquement dans [AccountDialog] (page "Compte local"). Ce
    // bandeau reste pour les échecs de synchronisation (rouge).
    if (_isOffline) {
      return const SizedBox.shrink();
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

  /// Clef stable utilisée par le [SoftSwitcher] pour détecter un
  /// changement de vue. Inclut l'id du dossier sélectionné pour que
  /// passer d'un dossier à un autre dans la même « vue » relance aussi
  /// l'animation (sinon AnimatedSwitcher réutiliserait le même widget).
  String _contentKey() {
    final base = _activeView;
    if ((_activeView == 'dossier_detail' ||
            _activeView == 'visit_report' ||
            _activeView == 'documents') &&
        _selectedDossier != null) {
      return '$base:${_selectedDossier!.id}';
    }
    return base;
  }

  Widget _buildContent() {
    if (_activeView == 'dossier_detail' && _selectedDossier != null) {
      return DossierScreen(
        dossier: _selectedDossier!,
        onBack: _goBack,
        // IMPORTANT (demande utilisateur 2026-04-29) : on RE-FETCH le
        // dossier depuis SQLite AVANT de basculer vers le relevé de
        // visite. Pourquoi : `DossierScreen._flushPendingSave()` est
        // appelé par le bouton VAD juste avant `onOpenVisitReport()`,
        // donc SQLite a la version fraîche du nom/prénom/adresse, mais
        // `_selectedDossier` (cet objet en mémoire) reste sur le
        // snapshot d'origine. Sans ce refresh, `VisitReportScreen` se
        // monte avec une `widget.dossier` STALE → la `BeneficiaryTab`
        // hydrate `_occupants` avec l'ancien nom → la 1ère save
        // déclenchée depuis le relevé (ex. changement de situation
        // familiale) ré-écrit le nom à sa valeur initiale. Symptôme
        // reporté : « si je change le nom prénom avant d'aller dans le
        // relevé de visite, que je change situation familiale, ça
        // rechange direct le nom à celui initial ».
        onOpenVisitReport: () async {
          final fresh =
              await _dataService.fetchDossierById(_selectedDossier!.id);
          if (!mounted) return;
          _pushHistory();
          setState(() {
            if (fresh != null) {
              _selectedDossier = fresh;
            }
            _activeView = 'visit_report';
          });
        },
        // Idem pour Documents (demande utilisateur 2026-04-29 :
        // « y'a toujours pas le menu vertical à gauche ») — on
        // route en interne pour rester dans le shell `MainScreen`
        // qui dessine la sidebar gauche, plutôt que faire un
        // `Navigator.push` qui empilerait Documents par-dessus la
        // sidebar et la masquerait. Refresh dossier identique au
        // VAD pour ne pas afficher des données stale.
        onOpenDocuments: () async {
          final fresh =
              await _dataService.fetchDossierById(_selectedDossier!.id);
          if (!mounted) return;
          _pushHistory();
          setState(() {
            if (fresh != null) {
              _selectedDossier = fresh;
            }
            _activeView = 'documents';
          });
        },
      );
    }
    if (_activeView == 'documents' && _selectedDossier != null) {
      return DocumentsScreen(
        dossier: _selectedDossier!,
        onBack: () async {
          // Re-fetch le dossier au retour pour que dossier_detail
          // voie les éventuelles modifs (rares — Documents écrit peu
          // de champs patient, mais ça reste cohérent avec VAD).
          final fresh =
              await _dataService.fetchDossierById(_selectedDossier!.id);
          if (!mounted) return;
          if (fresh != null) {
            setState(() => _selectedDossier = fresh);
          }
          _goBack();
          _refreshDossiers();
        },
      );
    }
    if (_activeView == 'visit_report' && _selectedDossier != null) {
      return VisitReportScreen(
        dossier: _selectedDossier!,
        onBack: () async {
          // Re-fetch the dossier pour que l'écran précédent voit les
          // éventuelles modifs (nom, ville…) faites dans le rapport.
          final fresh =
              await _dataService.fetchDossierById(_selectedDossier!.id);
          if (!mounted) return;
          if (fresh != null) {
            setState(() => _selectedDossier = fresh);
          }
          _goBack();
          _refreshDossiers();
        },
      );
    }

    switch (_activeView) {
      case 'dashboard':
        return DashboardScreen(
          visits: [],
          dossiers: _dossiers,
          pendingSyncCount: _pendingSyncCount,
          isSyncing: _isSyncing,
          onSyncNow: _handleSyncNow,
          onSelectDossier: _handleSelectDossier,
          userName: widget.currentUser.displayName,
          // Le bouton « Voir tout » du dashboard renvoie TOUJOURS vers
          // la liste plate « Mes dossiers » — on ne restaure pas le
          // dernier dossier visité (comportement par défaut de
          // `_handleViewChange('dossiers')` qui restaurerait le
          // dossier_detail mémorisé). On contourne en réinitialisant
          // d'abord l'état profond, puis on délègue.
          onNavigateToDossiers: () {
            _pushHistory();
            setState(() {
              _activeView = 'dossiers';
              _selectedDossier = null;
              _lastDossierTreeView = null;
              _lastDossierTreeSelected = null;
            });
          },
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
      // 'admin' : page retirée — la gestion des accès se fait directement
      // sur NocoDB pour éviter les conflits de sync (les ergos/admins
      // créés côté NocoDB sont propagés au `access_members` local via
      // `refreshAdminAccessMembersFromRemote`).
      case 'settings':
        return SettingsScreen(
          user: widget.currentUser,
          onLogout: widget.onLogout,
        );
      default:
        return Center(child: Text("View: $_activeView"));
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation history
  // ---------------------------------------------------------------------------

  /// Capture l'écran courant dans la pile d'historique. Appelé AVANT de
  /// changer de vue (ex: Dashboard → ouvre un dossier). La flèche de
  /// retour dépile pour restaurer exactement cet état.
  void _pushHistory() {
    _navHistory.add(_NavEntry(
      view: _activeView,
      dossier: _selectedDossier,
    ));
    if (_navHistory.length > 50) _navHistory.removeAt(0);
  }

  /// Dépile l'entrée précédente et y navigue. Si la pile est vide, on
  /// retombe sur le Dashboard (défaut raisonnable pour éviter un écran
  /// bloqué).
  void _goBack() {
    if (_navHistory.isEmpty) {
      setState(() {
        _activeView = 'dashboard';
        _selectedDossier = null;
      });
      return;
    }
    final prev = _navHistory.removeLast();
    setState(() {
      _activeView = prev.view;
      _selectedDossier = prev.dossier;
    });
  }
}

/// Entrée d'historique de navigation — capture l'écran actif + le
/// dossier sélectionné (null si on n'est pas dans l'arbre dossiers).
class _NavEntry {
  final String view;
  final Dossier? dossier;
  const _NavEntry({required this.view, required this.dossier});
}
