import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:sqflite/sqflite.dart';

import '../services/app_config.dart';
import '../services/local_database.dart';
import '../services/nocodb_api_client.dart';

/// Page « Caisses de retraite principales » — référentiel partagé.
///
/// Source : table NocoDB `caisses_de_retraite` (15 entrées) exposée
/// par `GET /api/retirement-funds-principal`. Le serveur set un
/// Cache-Control HTTP de 5 min fresh + 30 min stale-while-revalidate
/// pour réduire la pression sur le Fast Origin Transfer Vercel.
///
/// Design dérivé de `RetirementFundsScreen` (caisses complémentaires)
/// mais simplifié : la table source ne contient que `nom` et
/// `numero_telephone_contact`, donc on retire les champs
/// audience/démarche/montant/site web/logo et on affiche des cartes
/// plus compactes (juste nom + téléphone). Demande utilisateur
/// 2026-05-12.
class RetirementFundsPrincipalScreen extends StatefulWidget {
  const RetirementFundsPrincipalScreen({super.key});

  @override
  State<RetirementFundsPrincipalScreen> createState() =>
      _RetirementFundsPrincipalScreenState();
}

class _RetirementFundsPrincipalScreenState
    extends State<RetirementFundsPrincipalScreen> {
  final TextEditingController _searchController = TextEditingController();
  // Conservé pour le dialog `_NewPrincipalFundDialog` qui fait son
  // POST direct avec ses propres headers.
  final http.Client _client = http.Client();
  final NocodbApiClient _api = NocodbApiClient();
  final LocalDatabase _localDb = LocalDatabase.instance;

  /// Clé du cache `kv_store` pour la liste des caisses principales.
  /// Pattern identique à `references_service.dart` (`refs_payload_v1`).
  static const String _cacheKey = 'principal_retirement_funds_v1';

  List<_PrincipalFund> _funds = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFunds();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _client.close();
    super.dispose();
  }

  /// Stratégie offline-first identique à `RetirementFundsScreen` (caisses
  /// complémentaires) :
  ///   1. Lit le cache local `kv_store` → affichage INSTANTANÉ (pas de
  ///      spinner si on a déjà visité la page une fois).
  ///   2. Refresh remote en arrière-plan → met à jour l'UI quand la
  ///      réponse arrive.
  ///   3. Persiste la réponse remote pour le prochain cold start.
  ///
  /// Demande utilisateur 2026-05-12 : « les caisses de retraite
  /// principales chargent à l'affichage alors que ça devrait être
  /// instantané comme caisse de retraite complémentaire ».
  Future<void> _loadFunds() async {
    // 1. Lecture cache local — instantané.
    final cached = await _readFromCache();
    if (cached != null && cached.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _funds = cached;
        _isLoading = false;
        _error = null;
      });
    }

    // 2. Refresh remote en arrière-plan (pas de spinner si on a déjà
    // affiché le cache).
    try {
      final raw = await _api.fetchPrincipalRetirementFunds();
      final funds = raw
          .map((m) => _PrincipalFund(
                id: m['id'] ?? '',
                name: m['name'] ?? '',
                phone: m['phone'] ?? '',
                logoUrl: m['logoUrl'] ?? '',
              ))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _funds = funds;
        _isLoading = false;
        _error = null;
      });
      // 3. Persiste pour le prochain cold start. Fire-and-forget.
      unawaited(_writeToCache(funds));
    } catch (error, stack) {
      // ignore: avoid_print
      print('[retirement_principal] fetch error: $error');
      // ignore: avoid_print
      print(stack);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        // N'affiche d'erreur que si on n'a RIEN à montrer (ni cache, ni
        // remote). Sinon on garde l'affichage cache silencieusement.
        _error = _funds.isEmpty
            ? 'Chargement impossible — $error'
            : null;
      });
    }
  }

  Future<List<_PrincipalFund>?> _readFromCache() async {
    try {
      final db = await _localDb.database;
      final rows = await db.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: [_cacheKey],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['value'] as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((e) => _PrincipalFund.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeToCache(List<_PrincipalFund> funds) async {
    try {
      final db = await _localDb.database;
      final encoded = jsonEncode(
        funds
            .map((f) => {
                  'id': f.id,
                  'name': f.name,
                  'phone': f.phone,
                  'logoUrl': f.logoUrl,
                })
            .toList(),
      );
      await db.insert(
        'kv_store',
        {
          'key': _cacheKey,
          'value': encoded,
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // Silent — un cache absent n'est pas fatal.
    }
  }

  List<_PrincipalFund> get _filteredFunds {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _funds;
    return _funds
        .where((fund) =>
            '${fund.name} ${fund.phone}'.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _callPhone(String phone) async {
    final sanitized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (sanitized.isEmpty) return;
    final uri = Uri.parse('tel:$sanitized');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Ouvre une popup détail de la caisse (logo + nom + bouton Appeler).
  /// Demande utilisateur 2026-05-12 : tap sur une carte doit ouvrir une
  /// popup et NON déclencher l'appel direct — parité avec le dialog
  /// `_RetirementFundDialog` des caisses complémentaires.
  Future<void> _openFund(_PrincipalFund fund) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => _PrincipalFundDialog(
        fund: fund,
        onCallPhone: () => _callPhone(fund.phone),
      ),
    );
  }

  /// Ouvre un dialog de création (nom + téléphone). Demande utilisateur
  /// 2026-05-12 : parité avec Caisses complémentaires.
  Future<void> _createFund() async {
    final created = await showDialog<_PrincipalFund>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => _NewPrincipalFundDialog(
        client: _client,
      ),
    );
    if (created == null || !mounted) return;
    // Re-pull la liste pour avoir la version triée serveur (et garder
    // le cache HTTP cohérent).
    await _loadFunds();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildContent(),
        // Bouton « + Ajouter une caisse de retraite » — parité 1:1 avec
        // la page Caisses complémentaires.
        Positioned(
          right: 24,
          bottom: 24,
          child: FloatingActionButton.extended(
            onPressed: _createFund,
            backgroundColor: const Color(0xFF7C6DAA),
            foregroundColor: Colors.white,
            elevation: 4,
            shape: const StadiumBorder(),
            icon: const Icon(LucideIcons.plus, size: 22),
            label: const Text(
              'Ajouter une caisse de retraite',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête : titre + barre de recherche pill (parité 1:1 avec
          // la page Caisses complémentaires).
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'Caisses de retraite principales',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: 320,
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.search,
                          size: 18, color: Color(0xFF64748B)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText: 'CARSAT, MSA, CNRACL...',
                            hintStyle:
                                TextStyle(color: Color(0xFF94A3B8)),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            isCollapsed: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loadFunds,
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            )
          else if (_filteredFunds.isEmpty)
            const Expanded(
              child: Center(child: Text('Aucune caisse trouvée')),
            )
          else
            Expanded(
              child: GridView.builder(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 280,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  // 130 (hero logo agrandi) + 12 padding + ~20 nom + 8 +
                  // ~30 chip téléphone + 12 padding ≈ 240. +10 vs
                  // complémentaires (230) pour laisser plus de place
                  // aux wordmarks larges — demande user 2026-05-12.
                  mainAxisExtent: 240,
                ),
                itemCount: _filteredFunds.length,
                itemBuilder: (context, index) {
                  final fund = _filteredFunds[index];
                  return _PrincipalFundCard(
                    fund: fund,
                    onOpen: () => _openFund(fund),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Carte avec logo en hero + nom + chip téléphone tappable.
///
/// Design 2026-05-12 : parité 1:1 avec `_FundCard` (caisses
/// complémentaires) — logo 120 pt full-width au top (BoxFit.contain,
/// fond blanc), nom 16 pt w800, chip téléphone sous le nom. Le tap
/// ouvre une popup détail (cf. `_PrincipalFundDialog`), il NE déclenche
/// PAS l'appel direct — demande utilisateur 2026-05-12.
class _PrincipalFundCard extends StatefulWidget {
  final _PrincipalFund fund;
  final VoidCallback onOpen;

  const _PrincipalFundCard({
    required this.fund,
    required this.onOpen,
  });

  @override
  State<_PrincipalFundCard> createState() => _PrincipalFundCardState();
}

class _PrincipalFundCardState extends State<_PrincipalFundCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fund = widget.fund;
    final hasPhone = fund.phone.trim().isNotEmpty;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: _hover
            ? (Matrix4.identity()..translateByDouble(0.0, -3.0, 0.0, 1.0))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: const Color(0xFF7C6DAA).withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onOpen,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- Hero logo ----------
              // Fond blanc uni, padding réduit (8 vs 14 auparavant) +
              // suppression du padding horizontal interne — laisse plus
              // d'espace utile aux wordmarks larges (CPRP SNCF, CNRACL,
              // SRE, etc.). BoxFit.contain préserve l'aspect ratio donc
              // les logos carrés ne sont pas déformés. Demande user
              // 2026-05-12 : « agrandis les logos qui sont facilement
              // agrandissables sans déborder comme celui de CPRP SNCF ».
              Container(
                height: 130,
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                // _PrincipalFundLogo sans `size` → SizedBox.expand →
                // remplit toute la zone padded (~110 h × ~220 w). Avec
                // BoxFit.contain, les wordmarks larges (CPRP SNCF,
                // CNRACL) prennent toute la largeur disponible au lieu
                // d'être bornés à un carré 110×110.
                child: _PrincipalFundLogo(logoUrl: fund.logoUrl),
              ),
              // ---------- Text content ----------
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fund.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (hasPhone)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(50),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  LucideIcons.phone,
                                  size: 12,
                                  color: Color(0xFF475569),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    fund.phone,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        const Text(
                          'Téléphone non renseigné',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Logo pour la card / dialog. Accepte :
///  • Un data URI `data:image/svg+xml` (encodé URL ou base64) → SVG inline
///    rendu via flutter_svg.
///  • Un data URI bitmap (`data:image/png;base64,...`) → Image.memory.
///  • Une URL HTTP terminant par `.svg` → `SvgPicture.network` (flutter_svg
///    supporte le téléchargement direct).
///  • Une URL HTTP bitmap → `Image.network`.
///  • Vide → placeholder gris.
///
/// `BoxFit.contain` partout (les logos brandés ont du whitespace interne
/// et doivent respirer dans le hero plutôt qu'être rognés). Si `size`
/// est fourni, on fixe une boîte carrée — sinon le widget remplit son
/// parent (pour permettre aux wordmarks larges d'utiliser toute la
/// largeur du hero, demande user 2026-05-12).
class _PrincipalFundLogo extends StatelessWidget {
  final String logoUrl;
  final double? size;

  const _PrincipalFundLogo({required this.logoUrl, this.size});

  @override
  Widget build(BuildContext context) {
    final child = _buildContent();
    if (size != null) {
      return SizedBox(width: size, height: size, child: child);
    }
    // Pas de size fixée → on remplit l'espace dispo du parent.
    return SizedBox.expand(child: child);
  }

  Widget _buildContent() {
    if (logoUrl.isEmpty) {
      return _placeholder();
    }
    if (logoUrl.startsWith('data:image/svg+xml')) {
      // SVG inline — décode et rend avec flutter_svg.
      final svgString = _decodeSvgDataUri(logoUrl);
      if (svgString == null) return _placeholder();
      return SvgPicture.string(svgString, fit: BoxFit.contain);
    }
    if (logoUrl.startsWith('data:image/')) {
      // Bitmap inline (PNG / JPEG base64).
      final bytes = _decodeBitmapDataUri(logoUrl);
      if (bytes == null) return _placeholder();
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    // URL HTTP — si .svg utilise flutter_svg.network (Image.network
    // ne décode pas le SVG), sinon Image.network classique.
    final lowerUrl = logoUrl.toLowerCase();
    final isSvgUrl = lowerUrl.endsWith('.svg') || lowerUrl.contains('.svg?');
    if (isSvgUrl) {
      return SvgPicture.network(
        logoUrl,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => _placeholder(),
      );
    }
    return Image.network(
      logoUrl,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: const Icon(LucideIcons.building,
            size: 32, color: Color(0xFF94A3B8)),
      );

  String? _decodeSvgDataUri(String dataUri) {
    final commaIdx = dataUri.indexOf(',');
    if (commaIdx < 0) return null;
    final meta = dataUri.substring(0, commaIdx);
    final payload = dataUri.substring(commaIdx + 1);
    try {
      if (meta.contains(';base64')) {
        return utf8.decode(base64Decode(payload));
      }
      // sinon URL-encoded (cas du serveur : encodeURIComponent).
      return Uri.decodeComponent(payload);
    } catch (_) {
      return null;
    }
  }

  Uint8List? _decodeBitmapDataUri(String dataUri) {
    final commaIdx = dataUri.indexOf(',');
    if (commaIdx < 0) return null;
    final payload = dataUri.substring(commaIdx + 1);
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }
}

class _PrincipalFund {
  final String id;
  final String name;
  final String phone;
  // Data URI SVG (logo auto-généré côté serveur : initiales +
  // dégradé déterministe). Vide si non fourni — la card affiche
  // un placeholder dans ce cas.
  final String logoUrl;

  const _PrincipalFund({
    required this.id,
    required this.name,
    required this.phone,
    this.logoUrl = '',
  });

  factory _PrincipalFund.fromJson(Map<String, dynamic> json) =>
      _PrincipalFund(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        logoUrl: json['logoUrl']?.toString() ?? '',
      );
}

/// Popup détail d'une caisse principale.
///
/// Demande utilisateur 2026-05-12 : « quand je clique dessus cela doit
/// ouvrir une pop up pas appeler direct ». Pattern dérivé de
/// `_RetirementFundDialog` (caisses complémentaires) mais simplifié :
/// la table source n'a que `nom` + `numero_telephone_contact`, donc
/// pas de sections À propos / Note ergo / Site web. On garde juste :
///  • Header : logo carré + nom + bouton fermer
///  • Section Contact : gros bouton « Appeler » tappable (si téléphone)
class _PrincipalFundDialog extends StatelessWidget {
  const _PrincipalFundDialog({
    required this.fund,
    required this.onCallPhone,
  });

  final _PrincipalFund fund;
  final Future<void> Function() onCallPhone;

  @override
  Widget build(BuildContext context) {
    final hasPhone = fund.phone.trim().isNotEmpty;
    return Dialog(
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: Colors.white,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------- Header ----------
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF8F4FB), Color(0xFFFDFCFE)],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Logo carré 64×64 (laisse aussi respirer les wordmarks
                  // larges grâce au padding interne + BoxFit.contain dans
                  // _PrincipalFundLogo).
                  Container(
                    height: 64,
                    width: 84,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: _PrincipalFundLogo(
                      logoUrl: fund.logoUrl,
                      size: 64,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      fund.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Bouton fermer — rond gris clair, parité avec le
                  // dialog des caisses complémentaires.
                  Tooltip(
                    message: 'Fermer',
                    child: Material(
                      color: const Color(0xFFF1F5F9),
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: () => Navigator.of(context).pop(),
                        customBorder: const CircleBorder(),
                        child: const SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            LucideIcons.x,
                            size: 18,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ---------- Body : Contact ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEDE8F5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          LucideIcons.phoneCall,
                          size: 15,
                          color: Color(0xFF7C6DAA),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Contact',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          height: 1,
                          color: const Color(0xFFE2E8F0),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Bouton Appeler — violet plein si téléphone, gris
                  // disabled sinon. Tap déclenche `launchUrl(tel:...)`.
                  Opacity(
                    opacity: hasPhone ? 1.0 : 0.5,
                    child: Material(
                      color: hasPhone
                          ? const Color(0xFF7C6DAA)
                          : const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        onTap: hasPhone ? () => onCallPhone() : null,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 16),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  LucideIcons.phone,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Appeler',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      hasPhone
                                          ? fund.phone
                                          : 'Aucun numéro renseigné',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white
                                            .withValues(alpha: 0.85),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (hasPhone)
                                Icon(
                                  LucideIcons.arrowUpRight,
                                  size: 16,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog de création d'une caisse principale. Demande utilisateur
/// 2026-05-12 : bouton « Ajouter une caisse de retraite » sur la page
/// Principales (parité avec Complémentaires). Schema simple : nom
/// (obligatoire) + téléphone — c'est tout ce que la table NocoDB
/// `caisses_de_retraite` stocke.
class _NewPrincipalFundDialog extends StatefulWidget {
  const _NewPrincipalFundDialog({required this.client});

  final http.Client client;

  @override
  State<_NewPrincipalFundDialog> createState() =>
      _NewPrincipalFundDialogState();
}

class _NewPrincipalFundDialogState extends State<_NewPrincipalFundDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Le nom est obligatoire');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
      final response = await widget.client.post(
        Uri.parse('$base/api/retirement-funds-principal'),
        headers: {
          'X-App-Session': AppConfig.appSessionToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'name': name,
          'phone': _phoneController.text.trim(),
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final data = (payload['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final fundJson = (data['fund'] as Map?)?.cast<String, dynamic>();
      if (fundJson == null) {
        throw Exception('Réponse serveur invalide');
      }
      if (!mounted) return;
      Navigator.of(context).pop(_PrincipalFund.fromJson(fundJson));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Création impossible : $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C6DAA).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.plus,
                      color: Color(0xFF7C6DAA),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Nouvelle caisse de retraite',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 20),
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _PrincipalLabeledField(
                label: 'Nom *',
                controller: _nameController,
                hint: 'ex. CARSAT Bretagne, MSA, CNRACL…',
                autofocus: true,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: 12),
              _PrincipalLabeledField(
                label: 'Téléphone',
                controller: _phoneController,
                hint: 'ex. 39 60',
                enabled: !_isSubmitting,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF7C6DAA),
                    ),
                    onPressed: _isSubmitting ? null : _submit,
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Créer'),
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

class _PrincipalLabeledField extends StatelessWidget {
  const _PrincipalLabeledField({
    required this.label,
    required this.controller,
    this.hint,
    this.autofocus = false,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF7C6DAA),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          autofocus: autofocus,
          enabled: enabled,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF7C6DAA), width: 1.4),
            ),
          ),
        ),
      ],
    );
  }
}
