import 'dart:convert';
import 'dart:typed_data';

class WikiShareImageFormat {
  const WikiShareImageFormat({required this.extension, required this.mimeType});

  final String extension;
  final String mimeType;
}

Uint8List? decodeWikiImageDataUrl(String value) {
  final dataUrl = value.trim();
  if (!dataUrl.startsWith('data:image/')) return null;
  final comma = dataUrl.indexOf(',');
  if (comma <= 0) return null;
  try {
    final header = dataUrl.substring(0, comma).toLowerCase();
    final payload = dataUrl.substring(comma + 1);
    if (header.contains(';base64')) {
      return base64Decode(payload.replaceAll(RegExp(r'\s+'), ''));
    }
    return Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
  } catch (_) {
    return null;
  }
}

WikiShareImageFormat? detectWikiShareImageFormat(
  Uint8List bytes, {
  String sourceHint = '',
}) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return const WikiShareImageFormat(extension: 'jpg', mimeType: 'image/jpeg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return const WikiShareImageFormat(extension: 'png', mimeType: 'image/png');
  }
  if (bytes.length >= 6 && String.fromCharCodes(bytes.take(6)) == 'GIF89a' ||
      bytes.length >= 6 && String.fromCharCodes(bytes.take(6)) == 'GIF87a') {
    return const WikiShareImageFormat(extension: 'gif', mimeType: 'image/gif');
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return const WikiShareImageFormat(
      extension: 'webp',
      mimeType: 'image/webp',
    );
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if ({'heic', 'heix', 'hevc', 'hevx', 'mif1'}.contains(brand)) {
      return const WikiShareImageFormat(
        extension: 'heic',
        mimeType: 'image/heic',
      );
    }
  }

  final sampleLength = bytes.length.clamp(0, 256);
  final sample = utf8
      .decode(bytes.sublist(0, sampleLength), allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  if (sample.startsWith('<svg') ||
      (sample.startsWith('<?xml') && sample.contains('<svg'))) {
    return const WikiShareImageFormat(
      extension: 'svg',
      mimeType: 'image/svg+xml',
    );
  }

  final hintedExtension = _imageExtensionFromHint(sourceHint);
  return switch (hintedExtension) {
    'jpg' || 'jpeg' => const WikiShareImageFormat(
      extension: 'jpg',
      mimeType: 'image/jpeg',
    ),
    'png' => const WikiShareImageFormat(
      extension: 'png',
      mimeType: 'image/png',
    ),
    'gif' => const WikiShareImageFormat(
      extension: 'gif',
      mimeType: 'image/gif',
    ),
    'webp' => const WikiShareImageFormat(
      extension: 'webp',
      mimeType: 'image/webp',
    ),
    'svg' => const WikiShareImageFormat(
      extension: 'svg',
      mimeType: 'image/svg+xml',
    ),
    'heic' => const WikiShareImageFormat(
      extension: 'heic',
      mimeType: 'image/heic',
    ),
    _ => null,
  };
}

String wikiShareImageFileName(String title, WikiShareImageFormat format) {
  var base = title
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty) base = 'image';
  base = base.replaceFirst(
    RegExp(r'\.(?:jpe?g|png|gif|webp|svg|heic)$', caseSensitive: false),
    '',
  );
  return '$base.${format.extension}';
}

String _imageExtensionFromHint(String hint) {
  final path = Uri.tryParse(hint.trim())?.path ?? hint.trim();
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return '';
  return path.substring(dot + 1).toLowerCase();
}
