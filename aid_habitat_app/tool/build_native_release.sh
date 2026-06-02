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
  echo "[build_native] ERROR: AIDHABITAT_API_BASE_URL est obligatoire pour un build natif release." >&2
  echo "[build_native] Exemple: AIDHABITAT_API_BASE_URL=https://api.aid-habitat.fr $0 $PLATFORM" >&2
  exit 1
fi
if [[ ! "$API_BASE_URL" =~ ^https://[^[:space:]]+$ ]]; then
  echo "[build_native] ERROR: AIDHABITAT_API_BASE_URL doit être une URL HTTPS en release native." >&2
  echo "[build_native] Reçu: $API_BASE_URL" >&2
  exit 1
fi
API_BASE_URL="${API_BASE_URL%/}"

if [ "$PLATFORM" = "android" ]; then
  if [ ! -f "android/key.properties" ]; then
    echo "[build_native] ERROR: android/key.properties manquant — signature Android release non configurée." >&2
    echo "[build_native] Créez ce fichier avec storeFile, storePassword, keyAlias et keyPassword." >&2
    exit 1
  fi
  HOMEBREW_JDK21="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
  if [ -d "$HOMEBREW_JDK21" ]; then
    export JAVA_HOME="$HOMEBREW_JDK21"
    export PATH="$JAVA_HOME/bin:$PATH"
  fi
  HOMEBREW_ANDROID_SDK="/opt/homebrew/share/android-commandlinetools"
  if [ -d "$HOMEBREW_ANDROID_SDK" ]; then
    export ANDROID_HOME="${ANDROID_HOME:-$HOMEBREW_ANDROID_SDK}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
  fi
  JAVA_VERSION_RAW="$(java -version 2>&1 | awk -F\" '/version/ {print $2; exit}')"
  JAVA_MAJOR="${JAVA_VERSION_RAW%%.*}"
  if [ "$JAVA_MAJOR" = "1" ]; then
    JAVA_MAJOR="$(echo "$JAVA_VERSION_RAW" | cut -d. -f2)"
  fi
  if [ -n "$JAVA_MAJOR" ] && [ "$JAVA_MAJOR" -ge 25 ]; then
    echo "[build_native] ERROR: Java $JAVA_VERSION_RAW détecté, incompatible avec la toolchain Android/Kotlin actuelle." >&2
    echo "[build_native] Utilisez un JDK LTS supporté, idéalement Java 17 ou 21, puis relancez." >&2
    exit 1
  fi
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
