import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/data_service.dart';

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

  bool _loadingStatus = true;
  bool _available = false;
  String _registrationUrl = 'https://monprojet.anah.gouv.fr/';
  String _publicUrl = 'https://www.anah.gouv.fr/';
  String _reason = '';
  String? _statusError;

  // WebView state
  InAppWebViewController? _webController;
  double _webProgress = 0;
  bool _webLoading = true;
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _fetchStatus();
  }

  Future<void> _fetchStatus() async {
    setState(() {
      _loadingStatus = true;
      _statusError = null;
    });
    try {
      final status = await _dataService.fetchAnahStatus();
      if (!mounted) return;
      setState(() {
        _available = status['available'] as bool? ?? false;
        _registrationUrl = status['registrationUrl']?.toString() ??
            'https://monprojet.anah.gouv.fr/';
        _publicUrl =
            status['publicUrl']?.toString() ?? 'https://www.anah.gouv.fr/';
        _reason = status['reason']?.toString() ?? '';
        _currentUrl = _registrationUrl;
        _loadingStatus = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _statusError = err.toString();
        _currentUrl = _registrationUrl;
        _loadingStatus = false;
      });
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible d\'ouvrir $url')),
      );
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
          Expanded(child: _buildWebViewCard()),
        ],
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
            const Text(
              'Anah',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            Text(
              'Portail MaPrimeAdapt\' — Agence nationale de l\'habitat',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],
        ),
        const Spacer(),
        _buildStatusBadge(),
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
          onPressed: () => _openExternal(_currentUrl.isEmpty
              ? _registrationUrl
              : _currentUrl),
          icon: const Icon(LucideIcons.externalLink, size: 16),
          label: const Text('Ouvrir dans Safari'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF334155),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge() {
    if (_loadingStatus) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
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
                color: Color(0xFF907CA1),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Vérification…',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      );
    }
    final bg = _available ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2);
    final fg = _available ? const Color(0xFF047857) : const Color(0xFFB91C1C);
    final icon = _available ? LucideIcons.checkCircle : LucideIcons.xCircle;
    final label = _available ? 'Service disponible' : 'Service indisponible';
    return Tooltip(
      message: _reason.isNotEmpty ? _reason : label,
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
        border: Border.all(color: const Color(0xFFE2E8F0)),
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
              color: const Color(0xFFF8FAFC),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.lock,
                  size: 12,
                  color: Colors.grey.shade500,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _currentUrl.isEmpty ? _registrationUrl : _currentUrl,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
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
              color: const Color(0xFF907CA1),
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
            if (url != null) _currentUrl = url;
          });
        },
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _webProgress = progress / 100);
        },
        onError: (type, description, url) {
          // ignore: avoid_print
          print('[ANAH] error: $type $description url=$url');
          if (!mounted) return;
          setState(() => _webLoading = false);
        },
        onHttpError: (statusCode, url) {
          // ignore: avoid_print
          print('[ANAH] http error: $statusCode url=$url');
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
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
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
                      backgroundColor: const Color(0xFF907CA1),
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
  final void Function(dynamic type, String description, String? url)? onError;
  final void Function(int statusCode, String? url)? onHttpError;
  final void Function(InAppWebViewController ctrl)? onControllerCreated;

  const _WebViewHost({
    required this.url,
    this.onLoadStart,
    this.onLoadStop,
    this.onProgress,
    this.onError,
    this.onHttpError,
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
                  await c.evaluateJavascript(source: '''
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
                  ''');
                } catch (_) {}
              }
            },
            onProgressChanged: (c, p) => widget.onProgress?.call(p),
            onReceivedError: (c, req, err) => widget.onError?.call(
              err.type,
              err.description,
              req.url.toString(),
            ),
            onReceivedHttpError: (c, req, resp) => widget.onHttpError?.call(
              resp.statusCode ?? 0,
              req.url.toString(),
            ),
            onReceivedServerTrustAuthRequest: (c, challenge) async {
              // Accepte tous les certs pour permettre à la page de charger
              // ses ressources externes (wikimedia, vae.gouv.fr, etc.) —
              // certains échouent à la validation dans le sandbox macOS.
              final host = challenge.protectionSpace.host.toLowerCase();
              // ignore: avoid_print
              print('[ANAH] trust challenge for $host → PROCEED');
              return ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.PROCEED,
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
