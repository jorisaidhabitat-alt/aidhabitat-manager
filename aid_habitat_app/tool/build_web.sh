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
#
# The setup step occasionally crashes with a webdev/build_daemon mismatch
# on recent Dart SDKs ("dart compile does not support build hooks"). When
# that happens we fall back to the copies already present in web/ from a
# previous run — they're shared-worker JS + a pinned SQLite WASM, neither
# depends on the app code, so a cached bundle is fine.
if [ -f "web/sqflite_sw.js" ] && [ -f "web/sqlite3.wasm" ]; then
  echo "[build_web] sqflite WASM bundle already in web/ — skipping setup."
else
  dart run sqflite_common_ffi_web:setup || {
    echo "[build_web] sqflite_common_ffi_web:setup failed and no cached" \
         "bundle is present. Run this script once on a workstation where" \
         "setup succeeds, then commit web/sqflite_sw.js + web/sqlite3.wasm." >&2
    exit 1
  }
fi

API_BASE_URL="${AIDHABITAT_API_BASE_URL:-}"

"$FLUTTER" build web --release \
  --dart-define=AIDHABITAT_API_BASE_URL="$API_BASE_URL"

# Copy the seeded static libraries into the PWA output so requests to
# `/wiki-offline/...` and `/retirement-logos/...` resolve on the PWA origin.
# The single-page rewrite `/(.*) -> /index.html` used by most static hosts
# (Vercel, Netlify, Firebase, nginx try_files) would otherwise return the
# app shell instead of the actual image bytes.
#
# Sources are looked up in order:
#   1. `$REPO_ROOT/public/<dir>` — canonical source at the monorepo root.
#      Used on workstations so edits made in public/ are always fresh.
#   2. `$APP_DIR/web-assets/<dir>` — vendored copy committed with the PWA
#      project. Used on Vercel when the project's rootDirectory is
#      aid_habitat_app/ (the monorepo root isn't uploaded there, so the
#      parent public/ folder isn't available to the build runner).
#
# TODO: keep web-assets/ in sync with public/ — run `cp -R public/…
# aid_habitat_app/web-assets/` before a PWA deploy, or set up a pre-commit
# hook to auto-sync.
for dir in wiki-offline retirement-logos; do
  src=""
  if [ -d "$REPO_ROOT/public/$dir" ]; then
    src="$REPO_ROOT/public/$dir"
  elif [ -d "$APP_DIR/web-assets/$dir" ]; then
    src="$APP_DIR/web-assets/$dir"
  fi
  if [ -n "$src" ]; then
    echo "[build_web] copying $dir from $src into build/web/"
    rm -rf "build/web/$dir"
    cp -R "$src" "build/web/$dir"
  else
    echo "[build_web] WARN: no source found for $dir — skipping" >&2
  fi
done

echo "[build_web] build/web produced:"
ls -lah build/web | head -20
