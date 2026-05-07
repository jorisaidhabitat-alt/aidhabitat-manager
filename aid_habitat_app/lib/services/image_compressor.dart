import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Cible : 1600 px max de large. Au-delà, on resize en gardant le ratio.
/// Aligné sur l'ancien réglage `image_picker.maxWidth` qui produisait des
/// photos exploitables pour la VAD + le rapport PDF (864×1184 typique).
const int _kMaxWidthPx = 1600;

/// Qualité JPEG cible — sweet spot taille/qualité visuelle.
/// 80 = quasi-imperceptible visuellement, ~5-10× plus petit que PNG brut.
const int _kJpegQuality = 80;

/// Seuil sous lequel on ne touche PAS au fichier (évite la perte JPEG
/// inutile sur des photos déjà petites). 200 KB = ordre de grandeur
/// d'une photo iPhone iCloud déjà compressée.
const int _kSkipThresholdBytes = 200 * 1024;

/// Résultat de [compressImageForUpload].
class CompressedImage {
  /// Bytes prêts à uploader.
  final Uint8List bytes;

  /// Type MIME final ('image/jpeg' si recompressé, sinon le type d'origine).
  final String mimeType;

  /// Nom de fichier suggéré (extension corrigée si on a recompressé).
  final String fileName;

  /// True si on a effectivement recompressé. False = bytes inchangés
  /// (ex. fichier < 200KB ou format non supporté).
  final bool wasRecompressed;

  const CompressedImage({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    required this.wasRecompressed,
  });
}

/// Compresse une image avant upload. Décodage + resize + ré-encodage
/// JPEG en pur Dart — pas de canvas browser, donc pas vulnérable au
/// bug de troncature à 1 MiB qu'on a observé sur Safari macOS avec
/// `image_picker_for_web`.
///
/// Stratégie :
///   1. Si bytes < 200 KB → on ne fait rien (déjà petit, recompresser
///      ne ferait que dégrader la qualité sans gain de taille notable).
///   2. Si décodage échoue (format exotique, fichier corrompu) → on
///      retourne les bytes d'origine, le serveur valide ensuite.
///   3. Sinon → resize si largeur > 1600 px, encode JPEG quality 80,
///      retourne les nouveaux bytes.
///
/// Coût CPU sur Flutter web : ~500 ms-2 s pour une photo 3-5 MB. Le
/// bénéfice (300-700 KB → ~150 KB) compense largement le délai au
/// niveau de la sync Mac→iPad.
///
/// Tournant sur l'isolate principal (web n'a pas d'isolates utilisables).
/// Pour des photos > 10 MB sur web, on pourrait basculer sur
/// `compute()` mais on n'en a pas l'usage aujourd'hui.
Future<CompressedImage> compressImageForUpload({
  required Uint8List bytes,
  required String fileName,
  String? sourceMimeType,
}) async {
  final lowerName = fileName.toLowerCase();
  final originalMime = (sourceMimeType ?? '').toLowerCase();

  // Détection : seules JPEG/PNG/HEIC/WebP/BMP/GIF sont décodables par
  // le package `image`. Pour le reste (rare), on passe les bytes tels
  // quels — le serveur fera son boulot ou rejettera.
  final isJpeg = originalMime == 'image/jpeg'
      || lowerName.endsWith('.jpg')
      || lowerName.endsWith('.jpeg');
  final isPng = originalMime == 'image/png' || lowerName.endsWith('.png');
  final isHeic = originalMime.startsWith('image/heic')
      || originalMime.startsWith('image/heif')
      || lowerName.endsWith('.heic')
      || lowerName.endsWith('.heif');
  final isWebp = originalMime == 'image/webp' || lowerName.endsWith('.webp');
  final isBmp = originalMime == 'image/bmp' || lowerName.endsWith('.bmp');
  final isGif = originalMime == 'image/gif' || lowerName.endsWith('.gif');
  final supported = isJpeg || isPng || isHeic || isWebp || isBmp || isGif;

  if (!supported) {
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty
          ? originalMime
          : 'application/octet-stream',
      fileName: fileName,
      wasRecompressed: false,
    );
  }

  // Skip si déjà petit (sauf PNG : la recompression JPEG d'un PNG de
  // 100KB peut quand même diviser par 2 la taille, donc on tente).
  if (!isPng && bytes.length < _kSkipThresholdBytes) {
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
      fileName: fileName,
      wasRecompressed: false,
    );
  }

  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      // Format que le package `image` ne sait pas décoder (ex. HEIC sur
      // certains builds web). On tombe sur les bytes d'origine — le
      // serveur acceptera et stockera tel quel.
      return CompressedImage(
        bytes: bytes,
        mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
        fileName: fileName,
        wasRecompressed: false,
      );
    }

    img.Image working = decoded;
    if (working.width > _kMaxWidthPx) {
      working = img.copyResize(
        working,
        width: _kMaxWidthPx,
        // `interpolation` cubic = bonne qualité pour la réduction. Le
        // surcoût CPU est négligeable face à la transmission réseau
        // qu'on évite.
        interpolation: img.Interpolation.cubic,
      );
    }

    final encoded = img.encodeJpg(working, quality: _kJpegQuality);
    final result = Uint8List.fromList(encoded);

    // Garde-fou : si pour une raison X le re-encodage produit un fichier
    // PLUS GROS (rare, peut arriver sur des PNG très simples genre QR
    // codes), on retourne l'original. Sinon on perdrait de la qualité
    // pour rien.
    if (result.length >= bytes.length) {
      return CompressedImage(
        bytes: bytes,
        mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
        fileName: fileName,
        wasRecompressed: false,
      );
    }

    // Nom de fichier : on remplace l'extension par .jpg pour cohérence
    // avec le mime type final, sinon le serveur peut être confus
    // (extension .png mais bytes JPEG → certains decoders s'y perdent).
    String newFileName = fileName;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0) {
      newFileName = '${fileName.substring(0, dotIndex)}.jpg';
    } else {
      newFileName = '$fileName.jpg';
    }

    return CompressedImage(
      bytes: result,
      mimeType: 'image/jpeg',
      fileName: newFileName,
      wasRecompressed: true,
    );
  } catch (e) {
    // Décodage / encodage planté (mémoire, format exotique). On laisse
    // passer les bytes d'origine — le serveur tranchera.
    // ignore: avoid_print
    print('[image_compressor] échec recompression : $e — fallback bytes bruts');
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
      fileName: fileName,
      wasRecompressed: false,
    );
  }
}
