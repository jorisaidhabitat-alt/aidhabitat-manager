#!/usr/bin/env bash
# Vercel build script for the Flutter web (PWA) target.
# Vercel's Linux build image does not ship Flutter, so we clone the stable
# channel on every build (cached across deploys when possible) and build
# the web bundle into `build/web` (pointed at by `vercel.json`).
set -euo pipefail

if [ ! -d "flutter" ]; then
  echo "[vercel-build] cloning Flutter stable..."
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git
fi

export PATH="$PATH:$(pwd)/flutter/bin:$(pwd)/flutter/bin/cache/dart-sdk/bin"
# Git considers the cloned flutter/ dir "unsafe" under Vercel's user — mark
# it as safe so `flutter --version` (which runs git rev-parse) doesn't fail.
git config --global --add safe.directory "$(pwd)/flutter"

flutter --version
flutter config --enable-web
flutter pub get

# Copy the SQLite WASM bundle (+ shared worker) into web/ so the PWA can
# run sqflite via IndexedDB in the browser.
dart run sqflite_common_ffi_web:setup

# Inject the public API URL at build time. Must be set in Vercel Project
# Settings → Environment Variables (AIDHABITAT_API_BASE_URL).
: "${AIDHABITAT_API_BASE_URL:?AIDHABITAT_API_BASE_URL must be set in Vercel env}"

flutter build web --release \
  --dart-define=AIDHABITAT_API_BASE_URL="$AIDHABITAT_API_BASE_URL"

# Copy the wiki offline image library into the PWA output so `Image.network`
# calls to `/wiki-offline/...` resolve on the PWA origin (otherwise the
# Vercel rewrite `/(.*)→/index.html` would serve the SPA shell instead of
# the actual JPEG/PNG bytes).
if [ -d "../public/wiki-offline" ]; then
  echo "[vercel-build] copying wiki-offline library into build/web/"
  cp -R ../public/wiki-offline build/web/wiki-offline
fi
if [ -d "../public/retirement-logos" ]; then
  echo "[vercel-build] copying retirement-logos into build/web/"
  cp -R ../public/retirement-logos build/web/retirement-logos
fi

echo "[vercel-build] build/web produced:"
ls -lah build/web | head -20
