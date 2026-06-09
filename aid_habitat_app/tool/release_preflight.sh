#!/usr/bin/env bash
# Checks the local machine and project settings before attempting an
# App Store / Play Store release build. This script intentionally does not
# print secret values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

failures=0
warnings=0
enough_disk=1

ok() {
  printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"
}

fail() {
  failures=$((failures + 1))
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$1"
}

version_major() {
  printf '%s' "${1%%.*}"
}

echo "Aid'Habitat release preflight"
echo "================================"

if command -v flutter >/dev/null 2>&1; then
  flutter_version_output="$(flutter --version 2>/dev/null || true)"
  flutter_version_line="${flutter_version_output%%$'\n'*}"
  ok "Flutter disponible ($flutter_version_line)"
else
  fail "Flutter introuvable sur le PATH."
fi

api_url="${AIDHABITAT_API_BASE_URL:-}"
if [[ "$api_url" =~ ^https://[^[:space:]]+$ ]]; then
  ok "AIDHABITAT_API_BASE_URL est configuree en HTTPS."
else
  fail "AIDHABITAT_API_BASE_URL doit etre definie en HTTPS pour un build natif release."
fi

if plutil -lint ios/Runner/Info.plist ios/Runner/PrivacyInfo.xcprivacy >/dev/null; then
  ok "Info.plist et PrivacyInfo.xcprivacy valides."
else
  fail "Info.plist ou PrivacyInfo.xcprivacy invalide."
fi

available_kb="$(df -Pk "$APP_DIR" | awk 'NR == 2 {print $4}')"
required_kb=$((20 * 1024 * 1024))
available_gb="$(awk -v kb="$available_kb" 'BEGIN {printf "%.1f", kb / 1024 / 1024}')"
if [ "$available_kb" -ge "$required_kb" ]; then
  ok "Espace disque suffisant (${available_gb} GiB libres)."
else
  enough_disk=0
  fail "Espace disque insuffisant (${available_gb} GiB libres). Prevoir au moins 20 GiB pour archives iOS/Android."
fi

echo
echo "iOS / App Store"
echo "---------------"

if command -v xcodebuild >/dev/null 2>&1; then
  xcode_version_output="$(xcodebuild -version 2>/dev/null || true)"
  xcode_version="$(awk '/Xcode/ {print $2; exit}' <<< "$xcode_version_output")"
  if [ -n "$xcode_version" ] && [ "$(version_major "$xcode_version")" -ge 26 ]; then
    ok "Xcode $xcode_version disponible."
  else
    fail "Xcode 26 ou plus est requis pour les uploads App Store actuels."
  fi

  ios_sdk="$(xcodebuild -version -sdk iphoneos SDKVersion 2>/dev/null || true)"
  if [ -n "$ios_sdk" ] && [ "$(version_major "$ios_sdk")" -ge 26 ]; then
    ok "SDK iOS $ios_sdk disponible."
  else
    fail "SDK iOS 26 ou plus introuvable."
  fi

  destinations="$(xcodebuild -showdestinations -project ios/Runner.xcodeproj -scheme Runner -configuration Release 2>&1 || true)"
  if printf '%s' "$destinations" | grep -q 'Ineligible destinations'; then
    fail "Xcode refuse la destination iOS. Ouvrir Xcode > Settings > Components et installer/reparer iOS."
  else
    ok "Destination iOS eligible pour le scheme Runner."
  fi
else
  fail "xcodebuild introuvable."
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Distribution'; then
  ok "Certificat Apple Distribution trouve dans le trousseau."
else
  fail "Aucun certificat Apple Distribution valide trouve dans le trousseau."
fi

if rg -q 'DEVELOPMENT_TEAM = [A-Z0-9]+' ios/Runner.xcodeproj/project.pbxproj; then
  ok "DEVELOPMENT_TEAM configure dans le projet iOS."
else
  warn "DEVELOPMENT_TEAM non configure dans le projet iOS. Xcode pourra le renseigner via Signing & Capabilities."
fi

if rg -q 'TARGETED_DEVICE_FAMILY = "1,2"|TARGETED_DEVICE_FAMILY = 2' ios/Runner.xcodeproj/project.pbxproj; then
  ok "La cible iOS inclut bien l'iPad."
else
  fail "La cible iOS n'inclut pas l'iPad."
fi

if /usr/libexec/PlistBuddy -c 'Print :UIApplicationSupportsIndirectInputEvents' ios/Runner/Info.plist 2>/dev/null | grep -q '^true$'; then
  ok "Le support clavier/trackpad iPad est active."
else
  warn "UIApplicationSupportsIndirectInputEvents absent ou desactive."
fi

if /usr/libexec/PlistBuddy -c 'Print :UIRequiresFullScreen' ios/Runner/Info.plist 2>/dev/null | grep -q '^false$'; then
  ok "Le multitache iPad (Split View / Stage Manager) est autorise."
else
  warn "UIRequiresFullScreen ne permet pas clairement le multitache iPad."
fi

if rg -q 'PencilDoubleTapPlugin\.register\(with: (self|pencilRegistrar)\)' ios/Runner/AppDelegate.swift; then
  ok "Le bridge Apple Pencil natif est branche."
else
  warn "Le bridge Apple Pencil n'est pas encore enregistre dans AppDelegate.swift."
fi

if rg -q 'DocumentScannerPlugin\.register\(with: (self|scannerRegistrar)\)' ios/Runner/AppDelegate.swift; then
  ok "Le scanner de documents natif iPad est branche."
else
  warn "Le scanner de documents natif n'est pas encore enregistre dans AppDelegate.swift."
fi

echo
echo "Android / Play Store"
echo "--------------------"

java_bin="${JAVA_HOME:-}/bin/java"
if [ -n "${JAVA_HOME:-}" ] && [ -x "$java_bin" ]; then
  java_output="$("$java_bin" -version 2>&1 || true)"
else
  java_output="$(java -version 2>&1 || true)"
fi
java_version="$(awk -F\" '/version/ {print $2; exit}' <<< "$java_output")"
java_major="$(version_major "${java_version:-0}")"
if [ "$java_major" = "1" ]; then
  java_major="$(printf '%s' "$java_version" | cut -d. -f2)"
fi
if [ -n "$java_major" ] && [ "$java_major" -ge 17 ] && [ "$java_major" -le 24 ]; then
  ok "Java $java_version compatible."
else
  fail "Java 17 ou 21 recommande. Version detectee: ${java_version:-inconnue}."
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
flutter_config_output="$(flutter config --list 2>/dev/null || true)"
flutter_android_sdk="$(awk -F: '/android-sdk/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' <<< "$flutter_config_output")"
if [ -z "$android_sdk" ]; then
  android_sdk="$flutter_android_sdk"
fi
if [ -z "$android_sdk" ] && [ -d "/opt/homebrew/share/android-commandlinetools" ]; then
  android_sdk="/opt/homebrew/share/android-commandlinetools"
fi
if [ -n "$android_sdk" ] && [ -d "$android_sdk/platforms/android-36" ]; then
  ok "Android SDK 36 disponible ($android_sdk)."
elif [ -n "$android_sdk" ] && [ -d "$android_sdk/platforms/android-35" ]; then
  ok "Android SDK 35 disponible ($android_sdk)."
else
  fail "Android SDK 35/36 introuvable."
fi

if [ -f android/key.properties ]; then
  missing_key_fields=0
  for key in storeFile storePassword keyAlias keyPassword; do
    if ! grep -q "^$key=" android/key.properties; then
      missing_key_fields=$((missing_key_fields + 1))
    fi
  done
  store_file="$(awk -F= '/^storeFile=/ {print $2; exit}' android/key.properties)"
  if [ "$missing_key_fields" -eq 0 ] && [ -n "$store_file" ] && [ -f "$store_file" ]; then
    ok "Signature Android release configuree."
  else
    fail "android/key.properties existe mais est incomplet ou storeFile est introuvable."
  fi
else
  fail "android/key.properties manquant: impossible de produire un AAB Play Store signe."
fi

if [ "$enough_disk" -eq 0 ]; then
  warn "Check Gradle Android ignore tant que l'espace disque est insuffisant."
else
  if (
    cd android
    JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
      PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" \
      ./gradlew -q :app:properties >/dev/null 2>&1
  ); then
    ok "Gradle Android repond correctement."
  else
    fail "Gradle Android ne repond pas correctement."
  fi
fi

echo
echo "Resultat"
echo "--------"
if [ "$failures" -eq 0 ]; then
  ok "Preflight pret pour release (${warnings} warning(s))."
  exit 0
fi

fail "$failures blocage(s), $warnings warning(s). Corriger avant archive store."
exit 1
