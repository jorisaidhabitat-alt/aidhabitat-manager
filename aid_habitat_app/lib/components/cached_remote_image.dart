import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/media_cache_service.dart';
import '../services/url_resolver.dart';

/// Displays a remote image using a local disk cache so it keeps working when
/// the network or the Express server is unavailable.
///
/// Supports both raster formats (png/jpg/jpeg/webp/gif) and SVG. Falls back
/// to [placeholder] while loading and to [errorWidget] on failure.
class CachedRemoteImage extends StatefulWidget {
  const CachedRemoteImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.onError,
  });

  final String url;
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
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CachedRemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      setState(() {
        _file = null;
        _svgBytes = null;
        _loading = true;
        _failed = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final svg = isSvgUrl(widget.url);
    try {
      if (svg) {
        final bytes = await MediaCacheService.instance.readBytes(widget.url);
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
        final file = await MediaCacheService.instance.fetch(widget.url);
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
    if (_failed) return widget.errorWidget ?? const _DefaultError();
    if (_svgBytes != null) {
      return SvgPicture.memory(
        _svgBytes!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        placeholderBuilder: (_) =>
            widget.placeholder ?? const _DefaultPlaceholder(),
      );
    }
    if (_file != null) {
      return Image.file(
        _file!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) {
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
      color: const Color(0xFFF1F5F9),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF94A3B8),
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
      color: const Color(0xFFF1F5F9),
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported_outlined,
        color: Color(0xFF94A3B8),
      ),
    );
  }
}
