import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/media_cache_service.dart';

/// Displays an image that works 100% offline:
///   1. If `pendingDataUrl` is a non-empty base64 data URL (e.g. a photo
///      captured offline and not yet uploaded), decode and show it directly.
///   2. Otherwise, fetch the remote [url] through [MediaCacheService] — this
///      hits the on-disk cache first and only falls back to the network when
///      the cache is cold. If both fail, [placeholder] (or a default icon)
///      is rendered.
///
/// On web, we can't persist files to the filesystem, so we fall back to
/// [Image.network] (the browser's HTTP cache handles offline-PWA cases).
class CachedMediaImage extends StatefulWidget {
  const CachedMediaImage({
    super.key,
    required this.url,
    this.pendingDataUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
  });

  final String url;
  final String? pendingDataUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;

  @override
  State<CachedMediaImage> createState() => _CachedMediaImageState();
}

class _CachedMediaImageState extends State<CachedMediaImage> {
  Future<File?>? _fetchFuture;
  Uint8List? _pendingBytes;

  @override
  void initState() {
    super.initState();
    _primeImage();
  }

  @override
  void didUpdateWidget(covariant CachedMediaImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.pendingDataUrl != widget.pendingDataUrl) {
      _primeImage();
    }
  }

  void _primeImage() {
    // Priority 1: locally-captured image not yet synced.
    final pending = widget.pendingDataUrl?.trim() ?? '';
    if (pending.isNotEmpty) {
      _pendingBytes = _decodeDataUrl(pending);
      _fetchFuture = null;
      return;
    }
    _pendingBytes = null;

    final url = widget.url.trim();
    if (url.isEmpty) {
      _fetchFuture = null;
      return;
    }
    if (kIsWeb) {
      // Web has no filesystem cache — the browser's HTTP cache handles PWA
      // offline, so we just render Image.network directly.
      _fetchFuture = null;
      return;
    }
    _fetchFuture = MediaCacheService.instance.fetch(url);
  }

  Uint8List? _decodeDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    final b64 = dataUrl.substring(comma + 1);
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingBytes != null) {
      return Image.memory(
        _pendingBytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }

    if (kIsWeb || _fetchFuture == null) {
      final url = widget.url.trim();
      if (url.isEmpty) return _buildPlaceholder();
      return Image.network(
        url,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }

    return FutureBuilder<File?>(
      future: _fetchFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final file = snapshot.data;
        if (file == null) return _buildPlaceholder();
        return Image.file(
          file,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    if (widget.placeholder != null) return widget.placeholder!;
    return Container(
      width: widget.width,
      height: widget.height,
      color: const Color(0xFFF1F5F9),
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, color: Colors.black54, size: 42),
    );
  }
}
