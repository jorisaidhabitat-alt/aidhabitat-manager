import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:pdfx/pdfx.dart';

import '../models/types.dart';
import '../services/app_config.dart';
import '../services/media_cache_service.dart';

/// Couleur primaire utilisée par les vignettes pour les icônes de fallback
/// (image manquante / placeholder). Extrait de `documents_screen.dart`
/// 2026-05-15 (audit P0 #9, suite). Préfixée `k` pour signaler qu'elle
/// est publique et partagée avec le reste du module documents.
const Color kDocThumbnailPurple = Color(0xFF8B6FA0);

// =============================================================================
// DocThumbnail — vignette polymorphe selon le type du document
//
// Image  → Image.memory si bytes en cache,
//          Image.file pour les locaux,
//          RemoteImage pour le distant.
// PDF    → 1) aplat d'annotation page 1 s'il existe (priorité),
//          2) PdfThumbnail (path filesystem natif),
//          3) PdfThumbnailFromBytes (web ou bytes en mémoire).
// Autre  → icône placeholder colorée.
// =============================================================================

class DocThumbnail extends StatefulWidget {
  final DocItem doc;

  const DocThumbnail({super.key, required this.doc});

  @override
  State<DocThumbnail> createState() => _DocThumbnailState();
}

class _DocThumbnailState extends State<DocThumbnail> {
  /// Cache des bytes décodés par `doc.id` — partagé entre toutes les
  /// instances pour que la grille ne refasse pas de `base64Decode` à
  /// chaque rebuild (c'est cette ré-décoding qui faisait clignoter les
  /// vignettes : Flutter voyait un nouvel `Uint8List` à chaque frame et
  /// rechargeait le décodeur d'image).
  static final Map<String, Uint8List> _bytesCache = {};

  /// Cache partagé des aplats d'annotation (PNG bytes décodés) keyed
  /// par `doc.id`. Invalidé quand `doc.annotationsJson` change (cf.
  /// `didUpdateWidget`) pour que la vignette reflète immédiatement la
  /// dernière save.
  static final Map<String, Uint8List> _annotationOverlayCache = {};
  static final Map<String, String> _annotationCacheJsonKey = {};

  /// Retourne les bytes PNG de l'aplat « page 1 + traits ergo » si
  /// disponibles dans `documents.annotations_json` (clé "1"). null si
  /// le doc n'a pas d'annotation pour la page 1, ou si le JSON est
  /// invalide. Cache mémoire pour éviter de re-decode chaque frame.
  static Uint8List? _firstPageAnnotationBytes(DocItem doc) {
    final raw = doc.annotationsJson;
    if (raw == null || raw.isEmpty) return null;
    // Cache hit ssi le JSON brut n'a pas changé.
    if (_annotationCacheJsonKey[doc.id] == raw) {
      final cached = _annotationOverlayCache[doc.id];
      if (cached != null) return cached;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final dataUrl = decoded['1'];
      if (dataUrl is! String || dataUrl.isEmpty) return null;
      final bytes = _decodeDataUrl(dataUrl);
      if (bytes == null || bytes.isEmpty) return null;
      _annotationOverlayCache[doc.id] = bytes;
      _annotationCacheJsonKey[doc.id] = raw;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _primeBytes();
  }

  @override
  void didUpdateWidget(covariant DocThumbnail old) {
    super.didUpdateWidget(old);
    if (old.doc.id != widget.doc.id ||
        old.doc.dataUrl != widget.doc.dataUrl) {
      // Invalidate le cache mémoire pour cet `id` quand le dataUrl a
      // changé (cas typique : l'utilisateur vient d'annoter + sauver →
      // `enqueueAnnotatedReuploadBytes` a écrit un nouveau data URL en
      // SQLite). Sans ça, `_primeBytes` retournait l'ancien décodage
      // et la vignette restait sur l'image pré-annotation.
      if (old.doc.dataUrl != widget.doc.dataUrl) {
        _bytesCache.remove(widget.doc.id);
      }
      _primeBytes();
    }
    // Invalidate aussi le cache d'aplat d'annotation quand le JSON a
    // changé (l'ergo vient de saver une annotation page 1) — sinon la
    // vignette PDF restait sur l'aplat précédent (ou pas d'aplat du tout).
    if (old.doc.annotationsJson != widget.doc.annotationsJson) {
      _annotationOverlayCache.remove(widget.doc.id);
      _annotationCacheJsonKey.remove(widget.doc.id);
    }
  }

  void _primeBytes() {
    final dataUrl = widget.doc.dataUrl;
    if (dataUrl == null || dataUrl.isEmpty) {
      setState(() => _bytes = null);
      return;
    }
    final cached = _bytesCache[widget.doc.id];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    final decoded = _decodeDataUrl(dataUrl);
    if (decoded != null) {
      _bytesCache[widget.doc.id] = decoded;
    }
    setState(() => _bytes = decoded);
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    if (doc.type == 'image') {
      // BoxFit.contain (vs cover historique) — demande utilisateur
      // 2026-05-06 : « je n'ai pas l'image complète, une partie est
      // coupée ». Avec cover, une photo portrait dans une tile carrée
      // perdait haut+bas. contain = lettrebox éventuel mais image
      // entière visible → l'ergo reconnaît son contenu d'un coup d'œil.
      if (_bytes != null) {
        return Image.memory(
          _bytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true, // évite le flash blanc au rebuild
          errorBuilder: _fallback,
        );
      }
      if (!kIsWeb &&
          doc.localPath != null &&
          doc.localPath!.isNotEmpty) {
        final file = File(doc.localPath!);
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: _fallback,
          );
        }
      }
      if (doc.url != null && doc.url!.isNotEmpty) {
        // Télécharge via MediaCacheService (cache persistant offline-first).
        return RemoteImage(
          url: doc.url!,
          fit: BoxFit.contain,
          fallback: _iconPlaceholder(doc.type),
        );
      }
    }
    if (doc.type == 'pdf') {
      // 1) PRIORITÉ : si l'ergo a annoté la page 1 du PDF, on affiche
      //    directement l'aplat PNG (PDF page 1 + traits) stocké dans
      //    `documents.annotations_json` sous la clé "1". Évite à
      //    l'utilisateur d'ouvrir le doc pour voir qu'il y a une note
      //    par-dessus — cf. demande utilisateur 2026-04-28.
      //
      //    Le décodage est mis en cache mémoire (statique partagé)
      //    pour que les rebuilds de la grille ne re-decode pas chaque
      //    frame (pareil que `_bytesCache` pour les images).
      final overlayBytes = _firstPageAnnotationBytes(doc);
      if (overlayBytes != null) {
        return Image.memory(
          overlayBytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: _fallback,
        );
      }
      // Web : on a soit les bytes en mémoire (upload web → dataUrl
      // décodé par `_primeBytes`), soit on les récupère depuis la
      // cache MediaCacheService (`webCachedFetch`) en passant l'URL
      // signée et le token X-App-Session. Dans les deux cas on rend
      // la 1re page en PNG via pdfx (qui pédale sur PDF.js côté web).
      //
      // Native : on garde le chemin filesystem qui marche déjà via
      // `PdfDocument.openFile`.
      //
      // Plus de fallback "icône PDF par défaut" sur la card : tant
      // qu'on n'a pas confirmé l'échec du rendu, on affiche le
      // placeholder neutre (gris-blanc + icône) — dès que les bytes
      // arrivent on swap. Voir `PdfThumbnailFromBytes`.
      if (!kIsWeb &&
          doc.localPath != null &&
          doc.localPath!.isNotEmpty &&
          File(doc.localPath!).existsSync()) {
        return PdfThumbnail(path: doc.localPath!);
      }
      // Bytes déjà en mémoire (upload web pas encore synced) : on
      // les passe directement, pas de round-trip réseau.
      if (kIsWeb && _bytes != null) {
        final pdfBytes = _bytes!;
        return PdfThumbnailFromBytes(
          docId: doc.id,
          bytesProvider: () async => pdfBytes,
          fallback: _iconPlaceholder('pdf'),
        );
      }
      // Sinon : fetch via cache (webCachedFetch persiste en SQLite,
      // hit instantané au prochain visit).
      final url = doc.url?.trim() ?? '';
      if (url.isNotEmpty) {
        return PdfThumbnailFromBytes(
          docId: doc.id,
          bytesProvider: () async {
            if (kIsWeb) {
              return await MediaCacheService.instance.webCachedFetch(
                url,
                headers: {'X-App-Session': AppConfig.appSessionToken},
              );
            }
            // Native : MediaCacheService.fetch renvoie un File ; on
            // lit ses bytes pour les passer à pdfx.openData. Permet
            // l'aperçu sur les docs téléchargés mais pas encore
            // ouverts (donc pas encore décodés en localPath).
            final file = await MediaCacheService.instance.fetch(
              url,
              headers: MediaCacheService.authHeaders(),
            );
            if (file == null) return null;
            try {
              return await file.readAsBytes();
            } catch (_) {
              return null;
            }
          },
          fallback: _iconPlaceholder('pdf'),
        );
      }
    }
    return _iconPlaceholder(doc.type);
  }

  /// Decodes a `data:<mime>;base64,<...>` URL into raw bytes. Returns null
  /// if malformed (missing `,` separator or invalid base64).
  static Uint8List? _decodeDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  Widget _fallback(BuildContext ctx, Object err, StackTrace? st) =>
      _iconPlaceholder(widget.doc.type);

  Widget _iconPlaceholder(String type) {
    final IconData icon;
    final Color color;
    switch (type) {
      case 'pdf':
        icon = LucideIcons.fileText;
        color = Colors.red.shade300;
        break;
      case 'image':
        icon = LucideIcons.image;
        color = kDocThumbnailPurple;
        break;
      default:
        icon = LucideIcons.file;
        color = const Color(0xFF8A939D);
    }
    return Container(
      color: const Color(0xFFFAFAFA),
      child: Center(
        child: Icon(icon, size: 56, color: color),
      ),
    );
  }
}

// =============================================================================
// PdfThumbnail — rend la 1re page d'un PDF (path filesystem natif).
// Les bytes sont mémoïsés par chemin pour éviter de re-render à chaque
// rebuild de la grille.
// =============================================================================

class PdfThumbnail extends StatefulWidget {
  final String path;
  const PdfThumbnail({super.key, required this.path});

  @override
  State<PdfThumbnail> createState() => _PdfThumbnailState();
}

class _PdfThumbnailState extends State<PdfThumbnail> {
  static final Map<String, Uint8List> _cache = {};

  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfThumbnail old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final cached = _cache[widget.path];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _bytes = cached);
      return;
    }
    try {
      final doc = await PdfDocument.openFile(widget.path);
      final page = await doc.getPage(1);
      final rendered = await page.render(
        width: page.width * 1.5,
        height: page.height * 1.5,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      await page.close();
      await doc.close();
      if (!mounted) return;
      if (rendered?.bytes != null) {
        _cache[widget.path] = rendered!.bytes;
        setState(() => _bytes = rendered.bytes);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Container(
        color: const Color(0xFFFAFAFA),
        child: Center(
          child: Icon(
            LucideIcons.fileText,
            size: 56,
            color: Colors.red.shade300,
          ),
        ),
      );
    }
    if (_bytes == null) {
      return Container(
        color: const Color(0xFFFAFAFA),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Container(
      color: Colors.white,
      alignment: Alignment.topCenter,
      child: Image.memory(
        _bytes!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => Container(
          color: const Color(0xFFFAFAFA),
          child: Center(
            child: Icon(
              LucideIcons.fileText,
              size: 56,
              color: Colors.red.shade300,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// PdfThumbnailFromBytes — rend la 1re page d'un PDF à partir de bytes en
// mémoire (web ou natif). Même comportement que PdfThumbnail mais accepte
// un fournisseur asynchrone de bytes plutôt qu'un chemin filesystem.
//
// Le rendu PNG est mémoïsé par `docId` dans une map statique → après le
// 1er rendu pour un doc, toutes les cards qui référencent ce doc
// s'affichent en O(1). Cache vidé seulement à reload de l'app.
// =============================================================================

class PdfThumbnailFromBytes extends StatefulWidget {
  /// Identifiant stable du document — clé du cache mémoire des PNG
  /// rendus. Doit être unique par PDF.
  final String docId;

  /// Fournisseur asynchrone des bytes PDF. Appelé uniquement si le
  /// PNG n'est pas déjà en cache pour [docId].
  final Future<Uint8List?> Function() bytesProvider;

  /// Widget affiché quand on n'a pas pu produire de preview (bytes
  /// manquants OU pdfx en échec). Habituellement l'icône PDF rouge.
  final Widget fallback;

  const PdfThumbnailFromBytes({
    super.key,
    required this.docId,
    required this.bytesProvider,
    required this.fallback,
  });

  @override
  State<PdfThumbnailFromBytes> createState() => _PdfThumbnailFromBytesState();
}

class _PdfThumbnailFromBytesState extends State<PdfThumbnailFromBytes> {
  /// Cache mémoire partagé entre toutes les instances : 1 PNG rendu
  /// par docId. Évite de re-décoder le PDF à chaque rebuild de la
  /// grille (scroll, sélection multiple, refresh polling, …).
  static final Map<String, Uint8List> _previewCache = {};

  /// Inflight Future par docId — si plusieurs cards demandent le
  /// preview du même doc en même temps (scroll rapide, polling),
  /// elles partagent une seule décod/render au lieu de décoder en
  /// parallèle.
  static final Map<String, Future<Uint8List?>> _inflight = {};

  Uint8List? _png;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfThumbnailFromBytes old) {
    super.didUpdateWidget(old);
    if (old.docId != widget.docId) {
      _png = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    // 1. Cache mémoire — instantané.
    final cached = _previewCache[widget.docId];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _png = cached);
      return;
    }

    // 2. Inflight ? on attend l'autre instance.
    final pending = _inflight[widget.docId];
    if (pending != null) {
      try {
        final png = await pending;
        if (!mounted) return;
        if (png != null) {
          setState(() => _png = png);
        } else {
          setState(() => _failed = true);
        }
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
      return;
    }

    // 3. On lance le rendu — un seul Future en vol pour ce docId.
    final renderFuture = _renderPreview();
    _inflight[widget.docId] = renderFuture;
    try {
      final png = await renderFuture;
      if (!mounted) return;
      if (png != null) {
        _previewCache[widget.docId] = png;
        setState(() => _png = png);
      } else {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _inflight.remove(widget.docId);
    }
  }

  /// Récupère les bytes du PDF (via `bytesProvider`), ouvre le doc
  /// avec pdfx, rend la page 1 en PNG. Renvoie null si étape échoue.
  Future<Uint8List?> _renderPreview() async {
    final bytes = await widget.bytesProvider();
    if (bytes == null || bytes.isEmpty) return null;
    PdfDocument? doc;
    PdfPage? page;
    try {
      doc = await PdfDocument.openData(bytes);
      page = await doc.getPage(1);
      final rendered = await page.render(
        // Facteur de scale 1.5x → preview lisible mais pas obèse
        // (la card fait ~200×260 px sur grille typique iPad).
        width: page.width * 1.5,
        height: page.height * 1.5,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      return rendered?.bytes;
    } catch (_) {
      return null;
    } finally {
      try {
        await page?.close();
      } catch (_) {}
      try {
        await doc?.close();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_png == null) {
      // Loading state : on affiche le fallback (icône PDF) plutôt
      // qu'un spinner agressif. Au scroll, l'apparence reste stable
      // jusqu'à ce que la preview arrive (généralement < 200 ms).
      return widget.fallback;
    }
    return Container(
      color: Colors.white,
      alignment: Alignment.topCenter,
      child: Image.memory(
        _png!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
      ),
    );
  }
}

// =============================================================================
// RemoteImage — télécharge une image depuis [url] avec cache disque/mémoire,
// fallback authentifié pour les URLs privées. Affiche un loader pendant le
// fetch initial puis l'image depuis le cache à chaque rebuild suivant
// (offline-first).
// =============================================================================

class RemoteImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final Widget fallback;

  const RemoteImage({
    super.key,
    required this.url,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  File? _file;
  Uint8List? _bytes;
  bool _failed = false;

  // Cache en mémoire pour éviter de refetch à chaque rebuild de card.
  static final Map<String, Uint8List> _memCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _file = null;
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    // 1. Cache mémoire → instantané.
    final cached = _memCache[widget.url];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _bytes = cached);
      return;
    }

    // 2. Web : cache SQLite (persistant + offline). Passe le header
    //    `X-App-Session` en cas de miss réseau pour les URLs privées.
    if (kIsWeb) {
      final bytes = await MediaCacheService().webCachedFetch(
        widget.url,
        headers: {'X-App-Session': AppConfig.appSessionToken},
      );
      if (!mounted) return;
      if (bytes != null) {
        _memCache[widget.url] = bytes;
        setState(() => _bytes = bytes);
        return;
      }
      setState(() => _failed = true);
      return;
    }

    // 3. Native : MediaCacheService (cache filesystem). On lui passe
    //    directement le header `X-App-Session` pour les URLs privées
    //    (`/api/mobile-documents/<id>/content`) — sinon le 1er download
    //    renvoie 401 et on perd un round-trip avant de retomber sur le
    //    fallback authentifié ci-dessous.
    final file = await MediaCacheService().fetch(
      widget.url,
      headers: MediaCacheService.authHeaders(),
    );
    if (!mounted) return;
    if (file != null) {
      setState(() => _file = file);
      return;
    }

    // 4. Fallback final : si même la fetch authentifiée a échoué (URL
    //    inaccessible, déconnexion, etc.), on tente un dernier http.get
    //    pour disposer des bytes en mémoire le temps de la session — le
    //    but est de servir l'image quand le filesystem ne peut pas être
    //    écrit (ex: quota plein) plutôt que d'afficher l'icône d'erreur.
    try {
      final uri = _buildAuthedUri(widget.url);
      if (uri == null) throw Exception('bad url');
      final resp = await http.get(
        uri,
        headers: {'X-App-Session': AppConfig.appSessionToken},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.bodyBytes.isNotEmpty) {
        _memCache[widget.url] = resp.bodyBytes;
        if (!mounted) return;
        setState(() => _bytes = resp.bodyBytes);
        return;
      }
      // ignore: avoid_print
      print('[docs img] HTTP ${resp.statusCode} for ${widget.url}');
    } catch (e) {
      // ignore: avoid_print
      print('[docs img] fetch failed for ${widget.url}: $e');
    }
    if (!mounted) return;
    setState(() => _failed = true);
  }

  /// Construit l'URI absolue pour les URLs relatives (préfixe apiBaseUrl).
  static Uri? _buildAuthedUri(String raw) {
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Uri.tryParse(raw);
    }
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final path = raw.startsWith('/') ? raw : '/$raw';
    return Uri.tryParse('$base$path');
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_file != null) {
      return Image.file(
        _file!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        fit: widget.fit,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return Container(
      color: const Color(0xFFF2F4F6),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
