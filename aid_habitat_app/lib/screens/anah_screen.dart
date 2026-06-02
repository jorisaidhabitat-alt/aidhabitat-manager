import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/brand_colors.dart';
import '../services/data_service.dart';
import '../services/external_launcher.dart';

/// ANAH module screen — embeds the MaPrimeAdapt' portal directly inside the
/// app via an in-app WebView. Fallback to Safari with a toolbar button if the
/// user prefers the native browser.
class AnahScreen extends StatefulWidget {
  const AnahScreen({super.key});

  @override
  State<AnahScreen> createState() => _AnahScreenState();
}

class _AnahScreenState extends State<AnahScreen> {
  final DataService _dataService = DataService();

  // Démarre en `false` avec les valeurs par défaut (URLs officielles
  // hardcodées) pour afficher la carte INSTANTANÉMENT à l'ouverture.
  // Le fetch réseau tourne en arrière-plan et met à jour silencieusement
  // si le serveur renvoie autre chose (feature flag désactivé, etc.).
  // Avant 2026-05-06 : on attendait le serveur (spinner pendant le cold
  // start Vercel pouvait durer 3-10 s à la 1ère ouverture après une
  // période d'inactivité). Demande utilisateur 2026-05-06 : « les pages
  // qui ne bougent quasiment pas type ANAH doivent être quasiment
  // instantanées même à la réouverture ».
  bool _loadingStatus = false;
  bool _available = true;
  String _registrationUrl = 'https://monprojet.anah.gouv.fr/';
  String _publicUrl = 'https://www.anah.gouv.fr/';
  String _reason = '';
  String? _statusError;

  // WebView state
  InAppWebViewController? _webController;
  double _webProgress = 0;
  bool _webLoading = true;
  String _currentUrl = 'https://monprojet.anah.gouv.fr/';
  bool _portalRuntimeKnown = false;
  bool _portalRuntimeAvailable = false;
  String? _portalRuntimeMessage;

  bool _matchesPrimaryPortalHost(String? host) {
    final normalizedHost = host?.trim().toLowerCase() ?? '';
    if (normalizedHost.isEmpty) return false;
    final candidates = <String>{
      Uri.tryParse(_registrationUrl)?.host.toLowerCase() ?? '',
      Uri.tryParse(_publicUrl)?.host.toLowerCase() ?? '',
      Uri.tryParse(_currentUrl)?.host.toLowerCase() ?? '',
    }..removeWhere((value) => value.isEmpty);

    for (final candidate in candidates) {
      if (normalizedHost == candidate ||
          normalizedHost.endsWith('.$candidate') ||
          candidate.endsWith('.$normalizedHost')) {
        return true;
      }
    }
    return false;
  }

  String _buildSecureConnectionRefusedMessage(String host) {
    final safeHost = host.trim().isEmpty ? 'ce portail' : host.trim();
    return 'La connexion securisee avec $safeHost a ete refusee. '
        'Ouvrez le portail dans Safari pour poursuivre.';
  }

  String _buildMainFrameLoadErrorMessage({
    required String description,
    String? url,
  }) {
    final parsedHost = Uri.tryParse(url ?? '')?.host.trim();
    final safeHost = (parsedHost != null && parsedHost.isNotEmpty)
        ? parsedHost
        : 'le portail';
    final normalizedDescription = description.trim();
    if (normalizedDescription.isEmpty) {
      return 'Le chargement securise de $safeHost a echoue. '
          'Ouvrez le portail dans Safari pour poursuivre.';
    }
    return 'Le chargement securise de $safeHost a echoue: '
        '$normalizedDescription. Ouvrez le portail dans Safari pour poursuivre.';
  }

  void _markPortalLoaded(String? url) {
    final host = Uri.tryParse(url ?? '')?.host;
    if (!_matchesPrimaryPortalHost(host)) return;
    _portalRuntimeKnown = true;
    _portalRuntimeAvailable = true;
    _portalRuntimeMessage = 'Portail chargé directement dans l’application.';
  }

  void _markPortalUnavailable(String message, {String? url, String? host}) {
    final effectiveHost = host ?? Uri.tryParse(url ?? '')?.host;
    if (effectiveHost != null && !_matchesPrimaryPortalHost(effectiveHost)) {
      return;
    }
    _portalRuntimeKnown = true;
    _portalRuntimeAvailable = false;
    _portalRuntimeMessage = message;
  }

  @override
  void initState() {
    super.initState();
    // Background fetch — silencieux, met à jour si différent. Pas de
    // setState `_loadingStatus = true` au départ : on garde l'UI déjà
    // rendue (avec valeurs par défaut) pour ne pas la flasher.
    _fetchStatus(silent: true);
  }

  Future<void> _fetchStatus({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loadingStatus = true;
        _statusError = null;
      });
    }
    try {
      final status = await _dataService.fetchAnahStatus();
      if (!mounted) return;
      setState(() {
        _available = status['available'] as bool? ?? true;
        _registrationUrl =
            status['registrationUrl']?.toString() ??
            'https://monprojet.anah.gouv.fr/';
        _publicUrl =
            status['publicUrl']?.toString() ?? 'https://www.anah.gouv.fr/';
        _reason = status['reason']?.toString() ?? '';
        _currentUrl = _registrationUrl;
        _loadingStatus = false;
        _statusError = null;
      });
    } catch (err) {
      if (!mounted) return;
      // En silent mode (fetch background), un échec ne doit PAS faire
      // basculer l'UI en erreur — on garde les valeurs par défaut déjà
      // affichées. L'erreur ne s'affiche que si l'utilisateur a cliqué
      // explicitement sur « Réessayer ».
      if (silent) return;
      setState(() {
        _statusError = err.toString();
        _currentUrl = _registrationUrl;
        _loadingStatus = false;
      });
    }
  }

  Future<void> _openExternal(String url) async {
    // Sur web PWA iPad, `url_launcher` passe par `window.open` que iOS
    // Safari standalone signale parfois comme "connexion non sécurisée /
    // se fait passer pour …" (faux positif). `openExternalUrl` crée et
    // clique un `<a target="_blank">` — pattern accepté sans prompt.
    final ok = await openExternalUrl(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Impossible d\'ouvrir $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          // Sur web/PWA iPad, `flutter_inappwebview` ne sait pas embedder
          // le portail (et anah.gouv.fr bloque l'iframe via
          // `X-Frame-Options: DENY`). On affiche une carte propre avec les
          // deux liens officiels + un CTA qui ouvre MaPrimeAdapt' dans un
          // nouvel onglet Safari — la seule solution réaliste côté web.
          Expanded(
            child: kIsWeb ? _buildWebExternalCard() : _buildWebViewCard(),
          ),
        ],
      ),
    );
  }

  /// Carte affichée sur web (PWA iPad, navigateur Safari/Chrome) pour
  /// rediriger vers MaPrimeAdapt' dans un nouvel onglet.
  Widget _buildWebExternalCard() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE4E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEE7F2),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    LucideIcons.home,
                    size: 44,
                    color: kBrandPurple,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "MaPrimeAdapt'",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0E1116),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  "Le portail officiel de l'Agence nationale de l'habitat "
                  "ne peut pas être affiché directement dans l'application "
                  "(politique de sécurité du site gouv.fr).",
                  style: TextStyle(
                    color: Color(0xFF2B323A),
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _openExternal(_registrationUrl),
                    icon: const Icon(LucideIcons.externalLink, size: 18),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        "Ouvrir MaPrimeAdapt'",
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: kBrandPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openExternal(_publicUrl),
                    icon: const Icon(LucideIcons.globe, size: 16),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        "Site institutionnel anah.gouv.fr",
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF2B323A),
                      side: const BorderSide(color: Color(0xFFB9C0C7)),
                    ),
                  ),
                ),
                if (_statusError != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _statusError!,
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Header (titre + statut + boutons)
  // -----------------------------------------------------------------------

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Portail MaPrimeAdapt\' — Agence nationale de l\'habitat',
              style: TextStyle(color: Color(0xFF2B323A), fontSize: 13),
            ),
          ],
        ),
        const Spacer(),
        _buildStatusBadge(),
        // Les boutons back/forward/reload n'ont de sens qu'avec la WebView
        // native — sur web la carte affiche simplement le CTA externe.
        if (!kIsWeb) ...[
          const SizedBox(width: 12),
          IconButton(
            onPressed: _webController == null
                ? null
                : () => _webController!.goBack(),
            icon: const Icon(LucideIcons.arrowLeft, size: 18),
            tooltip: 'Précédent',
          ),
          IconButton(
            onPressed: _webController == null
                ? null
                : () => _webController!.goForward(),
            icon: const Icon(LucideIcons.arrowRight, size: 18),
            tooltip: 'Suivant',
          ),
          IconButton(
            onPressed: _webController == null
                ? null
                : () => _webController!.reload(),
            icon: const Icon(LucideIcons.refreshCw, size: 18),
            tooltip: 'Recharger',
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _openExternal(
              _currentUrl.isEmpty ? _registrationUrl : _currentUrl,
            ),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Ouvrir dans Safari'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2B323A),
              side: const BorderSide(color: Color(0xFFB9C0C7)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatusBadge() {
    final bool shouldShowRuntimeCheck =
        !kIsWeb && _webLoading && !_portalRuntimeKnown && _statusError == null;
    if (_loadingStatus || shouldShowRuntimeCheck) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Color(0xFFF2F4F6),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: kBrandPurple,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Vérification…',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF2B323A),
              ),
            ),
          ],
        ),
      );
    }
    final bool hasRuntimeStatus = !kIsWeb && _portalRuntimeKnown;
    final bool effectiveAvailable = hasRuntimeStatus
        ? _portalRuntimeAvailable
        : _available;
    final bg = effectiveAvailable
        ? const Color(0xFFD1FAE5)
        : const Color(0xFFFEE2E2);
    final fg = effectiveAvailable
        ? const Color(0xFF047857)
        : const Color(0xFFB91C1C);
    final icon = effectiveAvailable
        ? LucideIcons.checkCircle
        : LucideIcons.xCircle;
    final label = hasRuntimeStatus
        ? (effectiveAvailable ? 'Portail chargé' : 'Portail indisponible')
        : (_available ? 'Service disponible' : 'Service indisponible');
    final tooltipMessage = hasRuntimeStatus
        ? (_portalRuntimeMessage?.isNotEmpty == true
              ? _portalRuntimeMessage!
              : label)
        : (_reason.isNotEmpty ? _reason : label);
    return Tooltip(
      message: tooltipMessage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Carte WebView intégrée
  // -----------------------------------------------------------------------

  Widget _buildWebViewCard() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE4E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Mini barre d'adresse (read-only)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7FA),
              border: Border(bottom: BorderSide(color: Color(0xFFE4E7EB))),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.lock, size: 12, color: Color(0xFF5C6670)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _currentUrl.isEmpty ? _registrationUrl : _currentUrl,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFF2B323A), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          // Barre de progression du chargement
          if (_webLoading && _webProgress < 1)
            LinearProgressIndicator(
              value: _webProgress == 0 ? null : _webProgress,
              minHeight: 2,
              color: kBrandPurple,
              backgroundColor: Colors.transparent,
            ),
          // WebView
          Expanded(child: _buildWebView()),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    if (_loadingStatus) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_statusError != null) {
      return _buildErrorPanel(_statusError!);
    }
    return Container(
      color: Colors.white,
      // Workaround macOS : le WKWebView sous flutter_inappwebview rend blanc
      // tant que le layer parent ne s'est pas rafraîchi. On force un re-layout
      // 500 ms après le premier onLoadStop via `_forceRepaint`, ce qui
      // déclenche un redraw du layer WebKit.
      child: _WebViewHost(
        url: _registrationUrl,
        onLoadStart: (url) {
          // ignore: avoid_print
          print('[ANAH] load start: $url');
          if (!mounted) return;
          setState(() {
            _webLoading = true;
            _webProgress = 0;
            _statusError = null;
            if (url != null) _currentUrl = url;
          });
        },
        onLoadStop: (url) {
          // ignore: avoid_print
          print('[ANAH] load stop: $url');
          if (!mounted) return;
          setState(() {
            _webLoading = false;
            _webProgress = 1;
            _markPortalLoaded(url);
            if (url != null) _currentUrl = url;
          });
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _webProgress = progress / 100);
        },
        onError: (type, description, url, isMainFrame) {
          // ignore: avoid_print
          print(
            '[ANAH] error: $type $description url=$url mainFrame=$isMainFrame',
          );
          if (!mounted) return;
          if (!isMainFrame) return;
          setState(() {
            _webLoading = false;
            _webProgress = 0;
            if (url != null && url.isNotEmpty) _currentUrl = url;
            final message = _buildMainFrameLoadErrorMessage(
              description: description,
              url: url,
            );
            _markPortalUnavailable(message, url: url);
            _statusError = message;
          });
        },
        onHttpError: (statusCode, url, isMainFrame) {
          // ignore: avoid_print
          print(
            '[ANAH] http error: $statusCode url=$url mainFrame=$isMainFrame',
          );
          if (!mounted || !isMainFrame) return;
          setState(() {
            _webLoading = false;
            _webProgress = 0;
            if (url != null && url.isNotEmpty) _currentUrl = url;
            final message =
                'Le portail a renvoye une erreur HTTP '
                '$statusCode. Ouvrez le portail dans Safari pour poursuivre.';
            _markPortalUnavailable(message, url: url);
            _statusError = message;
          });
        },
        onServerTrustError: (host) {
          if (!mounted || !_matchesPrimaryPortalHost(host)) return;
          setState(() {
            _webLoading = false;
            _webProgress = 0;
            final message = _buildSecureConnectionRefusedMessage(host);
            _markPortalUnavailable(message, host: host);
            _statusError = message;
          });
        },
        onControllerCreated: (ctrl) => _webController = ctrl,
      ),
    );
  }

  Widget _buildErrorPanel(String message) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                LucideIcons.wifiOff,
                size: 48,
                color: Color(0xFFB91C1C),
              ),
              const SizedBox(height: 12),
              const Text(
                'Impossible de charger le portail',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF2B323A), fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: _fetchStatus,
                    child: const Text('Réessayer'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => _openExternal(_publicUrl),
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('Ouvrir dans Safari'),
                    style: FilledButton.styleFrom(
                      backgroundColor: kBrandPurple,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WebView host avec workaround macOS : force un redraw du layer WKWebView
// après le premier chargement pour résoudre le rendu blanc connu sur macOS
// 14+ avec flutter_inappwebview 6.x.
// ---------------------------------------------------------------------------

class _WebViewHost extends StatefulWidget {
  final String url;
  final void Function(String? url)? onLoadStart;
  final void Function(String? url)? onLoadStop;
  final void Function(int progress)? onProgress;
  final void Function(
    dynamic type,
    String description,
    String? url,
    bool isMainFrame,
  )?
  onError;
  final void Function(int statusCode, String? url, bool isMainFrame)?
  onHttpError;
  final void Function(String host)? onServerTrustError;
  final void Function(InAppWebViewController ctrl)? onControllerCreated;

  const _WebViewHost({
    required this.url,
    this.onLoadStart,
    this.onLoadStop,
    this.onProgress,
    this.onError,
    this.onHttpError,
    this.onServerTrustError,
    this.onControllerCreated,
  });

  @override
  State<_WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends State<_WebViewHost> {
  InAppWebViewController? _ctrl;
  bool _firstLoadDone = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return SizedBox.fromSize(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: false,
              userAgent:
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
                  '(KHTML, like Gecko) Version/17.0 Safari/605.1.15',
              javaScriptCanOpenWindowsAutomatically: true,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              useShouldOverrideUrlLoading: false,
              isInspectable: true,
            ),
            onWebViewCreated: (c) {
              _ctrl = c;
              widget.onControllerCreated?.call(c);
              // ignore: avoid_print
              print('[ANAH] WebView created');
            },
            onLoadStart: (c, url) => widget.onLoadStart?.call(url?.toString()),
            onLoadStop: (c, url) async {
              widget.onLoadStop?.call(url?.toString());
              // Sonde JS : vérifie que le DOM est réel.
              try {
                final size = await c.evaluateJavascript(
                  source: 'document.body.innerHTML.length',
                );
                // ignore: avoid_print
                print('[ANAH] DOM size after load: $size');
              } catch (_) {}
              // Workaround macOS : force un reflow CSS via JS au premier load
              // uniquement — secoue le compositor WebKit pour afficher le
              // contenu, sans détruire la WebView.
              if (!_firstLoadDone) {
                _firstLoadDone = true;
                await Future<void>.delayed(const Duration(milliseconds: 150));
                try {
                  await c.evaluateJavascript(
                    source: '''
                    (function() {
                      var b = document.body;
                      if (!b) return;
                      var prev = b.style.transform;
                      b.style.transform = 'translateZ(0)';
                      void b.offsetHeight;
                      requestAnimationFrame(function() {
                        b.style.transform = prev;
                      });
                    })();
                  ''',
                  );
                } catch (_) {}
              }
            },
            onProgressChanged: (c, p) => widget.onProgress?.call(p),
            onReceivedError: (c, req, err) => widget.onError?.call(
              err.type,
              err.description,
              req.url.toString(),
              req.isForMainFrame ?? false,
            ),
            onReceivedHttpError: (c, req, resp) => widget.onHttpError?.call(
              resp.statusCode ?? 0,
              req.url.toString(),
              req.isForMainFrame ?? false,
            ),
            onReceivedServerTrustAuthRequest: (c, challenge) async {
              final host = challenge.protectionSpace.host.toLowerCase();
              widget.onServerTrustError?.call(host);
              // ignore: avoid_print
              print('[ANAH] trust challenge for $host -> CANCEL');
              return ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.CANCEL,
              );
            },
            onConsoleMessage: (c, m) {
              // ignore: avoid_print
              print('[ANAH console] ${m.messageLevel}: ${m.message}');
            },
          ),
        );
      },
    );
  }

  InAppWebViewController? get controller => _ctrl;
}
