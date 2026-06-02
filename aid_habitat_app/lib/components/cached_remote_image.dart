import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/media_cache_service.dart';
import '../services/url_resolver.dart';

/// Displays a remote image using a local disk cache so it keeps working when
/// the network or the Express server is unavailable.
///
/// Supports both raster formats (png/jpg/jpeg/webp/gif) and SVG. Falls back
/// to [placeholder] while loading and to [errorWidget] on failure.
///
/// When [pendingDataUrl] is a non-empty base64 data URL (e.g. an image
/// captured offline and not yet uploaded), it takes priority over [url] —
/// this keeps just-created items visible before their first sync.
class CachedRemoteImage extends StatefulWidget {
  const CachedRemoteImage({
    super.key,
    required this.url,
    this.pendingDataUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.onError,
  });

  final String url;
  final String? pendingDataUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;

  /// Called once when the image fails to load (after download attempt).
  /// Useful for multi-candidate fallback chains (e.g. try .png, then .jpg).
  final VoidCallback? onError;

  @override
  State<CachedRemoteImage> createState() => _CachedRemoteImageState();
}

class _CachedRemoteImageState extends State<CachedRemoteImage> {
  File? _file;
  Uint8List? _svgBytes;
  Uint8List? _pendingBytes;

  /// Raster (png/jpg/webp/gif) bytes downloaded via http — used on web where
  /// [File] isn't available. On native we rely on [MediaCacheService] + [_file].
  Uint8List? _webBytes;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!_primeInlineImage()) {
      _load();
    }
  }

  @override
  void didUpdateWidget(CachedRemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.pendingDataUrl != widget.pendingDataUrl) {
      _file = null;
      _svgBytes = null;
      _pendingBytes = null;
      _webBytes = null;
      _loading = true;
      _failed = false;
      final primed = _primeInlineImage();
      if (mounted) {
        setState(() {});
      }
      if (!primed) {
        _load();
      }
    }
  }

  Uint8List? _decodeDataUrl(String dataUrl) {
    try {
      final comma = dataUrl.indexOf(',');
      if (comma < 0) return null;
      final header = dataUrl.substring(0, comma);
      final payload = dataUrl.substring(comma + 1);
      if (header.toLowerCase().contains(';base64')) {
        return base64Decode(payload.replaceAll(RegExp(r'\s+'), ''));
      }
      final decoded = Uri.decodeComponent(payload);
      return Uint8List.fromList(utf8.encode(decoded));
    } catch (_) {
      return null;
    }
  }

  bool _primeInlineImage() {
    final pending = widget.pendingDataUrl?.trim() ?? '';
    if (pending.isNotEmpty) {
      final bytes = _decodeDataUrl(pending);
      if (bytes != null) {
        _pendingBytes = bytes;
        _loading = false;
        _failed = false;
        return true;
      }
    }

    final inlineUrl = widget.url.trim();
    if (!inlineUrl.startsWith('data:')) return false;
    final bytes = _decodeDataUrl(inlineUrl);
    if (bytes == null) return false;
    if (isSvgUrl(inlineUrl)) {
      _svgBytes = bytes;
    } else {
      _webBytes = bytes;
    }
    _loading = false;
    _failed = false;
    return true;
  }

  Future<void> _load() async {
    // Les data URLs inline (logos générés, images pending locales) sont
    // déjà prises en charge synchroniquement par `_primeInlineImage()`
    // afin d'éviter le flash placeholder → image au premier rendu.
    if (_primeInlineImage()) {
      if (mounted) {
        setState(() {});
      }
      return;
    }

    final svg = isSvgUrl(widget.url);
    // Audit sécu 2026-05-15 (P0 #2) : depuis le gating de `/uploads/*`
    // côté serveur, les images internes (profile-photos, documents,
    // visit-plans, wiki-library) exigent désormais le header
    // `X-App-Session`. `authHeadersFor` ne renvoie le token QUE pour les
    // URLs qui pointent vers notre Express (apiBase) — les URLs externes
    // (logos tiers de caisses retraite, etc.) restent fetch sans auth
    // pour ne pas leaker le token.
    final authHeaders = MediaCacheService.authHeadersFor(widget.url);
    try {
      if (kIsWeb) {
        // Web has no filesystem, but MediaCacheService.webCachedFetch
        // persists bytes in SQLite → wiki & retirement logos keep working
        // offline after a single online load.
        final bytes = await MediaCacheService.instance.webCachedFetch(
          widget.url,
          headers: authHeaders.isEmpty ? null : authHeaders,
        );
        if (!mounted) return;
        if (bytes == null) {
          setState(() {
            _failed = true;
            _loading = false;
          });
          widget.onError?.call();
          return;
        }
        setState(() {
          if (svg) {
            _svgBytes = bytes;
          } else {
            _webBytes = bytes;
          }
          _loading = false;
        });
        return;
      }
      if (svg) {
        final bytes = await MediaCacheService.instance.readBytes(
          widget.url,
          headers: authHeaders.isEmpty ? null : authHeaders,
        );
        if (!mounted) return;
        if (bytes == null) {
          setState(() {
            _failed = true;
            _loading = false;
          });
          widget.onError?.call();
          return;
        }
        setState(() {
          _svgBytes = Uint8List.fromList(bytes);
          _loading = false;
        });
      } else {
        final file = await MediaCacheService.instance.fetch(
          widget.url,
          headers: authHeaders.isEmpty ? null : authHeaders,
        );
        if (!mounted) return;
        if (file == null) {
          setState(() {
            _failed = true;
            _loading = false;
          });
          widget.onError?.call();
          return;
        }
        setState(() {
          _file = file;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
      widget.onError?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return widget.placeholder ?? const _DefaultPlaceholder();
    if (_pendingBytes != null) {
      return Image.memory(
        _pendingBytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            widget.errorWidget ?? const _DefaultError(),
      );
    }
    if (_webBytes != null) {
      return Image.memory(
        _webBytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            widget.errorWidget ?? const _DefaultError(),
      );
    }
    if (_failed) return widget.errorWidget ?? const _DefaultError();
    if (_svgBytes != null) {
      return SvgPicture.memory(
        _svgBytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        placeholderBuilder: (context) =>
            widget.placeholder ?? const _DefaultPlaceholder(),
      );
    }
    if (_file != null) {
      return Image.file(
        _file!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) {
          // The file was downloaded (HTTP 200) but can't be decoded as an
          // image — likely the server returned HTML as a SPA fallback. Drop
          // the poisoned cache entry and let the caller try another URL.
          _file!.delete().ignore();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onError?.call();
          });
          return widget.errorWidget ?? const _DefaultError();
        },
      );
    }
    return widget.errorWidget ?? const _DefaultError();
  }
}

class _DefaultPlaceholder extends StatelessWidget {
  const _DefaultPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF2F4F6),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF8A939D),
        ),
      ),
    );
  }
}

class _DefaultError extends StatelessWidget {
  const _DefaultError();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF2F4F6),
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported_outlined,
        color: Color(0xFF8A939D),
      ),
    );
  }
}
