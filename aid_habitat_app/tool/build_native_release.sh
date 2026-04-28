#!/usr/bin/env bash
# Native release builds (iOS / macOS / Android) avec obfuscation Dart
# pour l'App Store / TestFlight / Play Store.
#
# L'obfuscation `--obfuscate --split-debug-info=...` :
#   - rend le bytecode Dart illisible (les noms de classes/méthodes
#     deviennent des hash) → protège la logique métier dans l'IPA/AAB
#   - sépare les symbols dans un dossier annexe → on peut désobfusquer
#     les stack traces de production via `flutter symbolize -i ...`
#
# Sans obfuscation, l'App Store accepte le binaire mais n'importe qui
# peut décompiler l'IPA et lire le code Dart. Apple recommande
# explicitement l'obfuscation pour les apps métier.
#
# Usage :
#   ./tool/build_native_release.sh ios       # produit build/ios/archive/
#   ./tool/build_native_release.sh macos     # produit build/macos/Build/Products/Release/
#   ./tool/build_native_release.sh android   # produit build/app/outputs/bundle/release/
#
# Variables d'env :
#   AIDHABITAT_API_BASE_URL : URL du backend Aid'Habitat (obligatoire)
#   AIDHABITAT_DEBUG_INFO   : dossier où stocker les symbols
#                             (défaut : build/debug-symbols/<platform>/<git-sha>/)
#
# IMPORTANT :
#   - Conserver les fichiers de `debug-symbols/` ! Sans eux, impossible
#     de déchiffrer les crash reports remontés par TestFlight ou Apple.
#   - Les ajouter à un système de stockage durable (S3, Drive, etc.),
#     PAS au repo Git (trop volumineux).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

PLATFORM="${1:-}"
if [ -z "$PLATFORM" ]; then
  echo "Usage: $0 {ios|macos|android}" >&2
  exit 1
fi

FLUTTER="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "[build_native] flutter not found on PATH" >&2
  exit 1
fi

API_BASE_URL="${AIDHABITAT_API_BASE_URL:-}"
if [ -z "$API_BASE_URL" ]; then
  echo "[build_native] WARN: AIDHABITAT_API_BASE_URL non défini — l'app pointera sur l'origine relative (cassé en natif)." >&2
fi

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DEBUG_INFO_DIR="${AIDHABITAT_DEBUG_INFO:-build/debug-symbols/$PLATFORM/$GIT_SHA}"
mkdir -p "$DEBUG_INFO_DIR"

"$FLUTTER" --version
"$FLUTTER" pub get

case "$PLATFORM" in
  ios)
    echo "[build_native] iOS release archive (signing géré par Xcode)..."
    "$FLUTTER" build ipa --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"
    echo "[build_native] IPA produit dans build/ios/ipa/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    echo "[build_native] Étape suivante : ouvrir Xcode > Window > Organizer > Distribute App"
    ;;
  macos)
    echo "[build_native] macOS release..."
    "$FLUTTER" build macos --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"
    echo "[build_native] .app produit dans build/macos/Build/Products/Release/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    ;;
  android)
    echo "[build_native] Android App Bundle (Play Store) release..."
    "$FLUTTER" build appbundle --release \
      --obfuscate \
      --split-debug-info="$DEBUG_INFO_DIR" \
      --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"
    echo "[build_native] AAB produit dans build/app/outputs/bundle/release/"
    echo "[build_native] Symbols dans $DEBUG_INFO_DIR — À CONSERVER"
    ;;
  *)
    echo "[build_native] Plateforme inconnue : $PLATFORM" >&2
    echo "Usage: $0 {ios|macos|android}" >&2
    exit 1
    ;;
esac

echo "[build_native] OK — déchiffrer les crashs avec :"
echo "  $FLUTTER symbolize -i <stacktrace.txt> -d $DEBUG_INFO_DIR/app.android-arm64.symbols"
