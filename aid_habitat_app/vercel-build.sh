#!/usr/bin/env bash
# Vercel-specific wrapper around `tool/build_web.sh`.
#
# Vercel's Linux build image does not ship Flutter, so we clone the stable
# channel on every build (cached across deploys when possible) and delegate
# the actual build to the host-agnostic script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d "flutter" ]; then
  echo "[vercel-build] cloning Flutter stable..."
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git
fi

export PATH="$PATH:$(pwd)/flutter/bin:$(pwd)/flutter/bin/cache/dart-sdk/bin"
# Git considers the cloned flutter/ dir "unsafe" under Vercel's user — mark
# it as safe so `flutter --version` (which runs git rev-parse) doesn't fail.
git config --global --add safe.directory "$(pwd)/flutter"

# On Vercel the public API URL is injected via Project Settings → Env Vars.
: "${AIDHABITAT_API_BASE_URL:?AIDHABITAT_API_BASE_URL must be set in Vercel env}"

exec "$SCRIPT_DIR/tool/build_web.sh"
