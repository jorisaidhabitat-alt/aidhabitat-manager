#!/usr/bin/env bash
# Host-agnostic Flutter web build for the aid'habitat PWA.
#
# Produces the same `build/web/` bundle whether it runs on Vercel, a local
# workstation, a self-hosted CI, or any other Linux/macOS environment.
#
# Requirements:
#   - `flutter` on PATH (stable channel) — or pass FLUTTER_BIN=/path/to/flutter
#   - `AIDHABITAT_API_BASE_URL` env var pointing to the backend (defaults to
#     empty string → relative paths; fine when the API is same-origin)
#
# Usage:
#   ./tool/build_web.sh                # release build
#   AIDHABITAT_API_BASE_URL=https://api.example.com ./tool/build_web.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"

cd "$APP_DIR"

FLUTTER="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "[build_web] flutter not found on PATH (set FLUTTER_BIN= to override)" >&2
  exit 1
fi

"$FLUTTER" --version
"$FLUTTER" config --enable-web
"$FLUTTER" pub get

# Copy the SQLite WASM bundle (+ shared worker) into web/ so the PWA can
# run sqflite via IndexedDB in the browser.
dart run sqflite_common_ffi_web:setup

API_BASE_URL="${AIDHABITAT_API_BASE_URL:-}"

"$FLUTTER" build web --release \
  --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"

# Copy the seeded static libraries into the PWA output so requests to
# `/wiki-offline/...` and `/retirement-logos/...` resolve on the PWA origin.
# The single-page rewrite `/(.*) -> /index.html` used by most static hosts
# (Vercel, Netlify, Firebase, nginx try_files) would otherwise return the
# app shell instead of the actual image bytes.
for dir in wiki-offline retirement-logos; do
  src="$REPO_ROOT/public/$dir"
  if [ -d "$src" ]; then
    echo "[build_web] copying $dir into build/web/"
    rm -rf "build/web/$dir"
    cp -R "$src" "build/web/$dir"
  fi
done

echo "[build_web] build/web produced:"
ls -lah build/web | head -20
