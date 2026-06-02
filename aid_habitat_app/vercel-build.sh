#!/usr/bin/env bash
# Vercel-specific wrapper around `tool/build_web.sh`.
#
# Vercel's Linux build image does not ship Flutter, so we clone a pinned
# Flutter toolchain (cached across deploys when possible) and delegate the
# actual build to the host-agnostic script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FLUTTER_GIT_REF="${FLUTTER_GIT_REF:-3.38.4}"

if [ ! -d "flutter/.git" ]; then
  echo "[vercel-build] cloning Flutter $FLUTTER_GIT_REF..."
  git clone --depth 1 -b "$FLUTTER_GIT_REF" https://github.com/flutter/flutter.git
else
  echo "[vercel-build] using cached Flutter checkout; pinning $FLUTTER_GIT_REF..."
  git -C flutter fetch --depth 1 origin "refs/tags/$FLUTTER_GIT_REF:refs/tags/$FLUTTER_GIT_REF" \
    || git -C flutter fetch --depth 1 origin "$FLUTTER_GIT_REF"
  git -C flutter checkout -f "$FLUTTER_GIT_REF"
fi

export PATH="$PATH:$(pwd)/flutter/bin:$(pwd)/flutter/bin/cache/dart-sdk/bin"
# Git considers the cloned flutter/ dir "unsafe" under Vercel's user — mark
# it as safe so `flutter --version` (which runs git rev-parse) doesn't fail.
git config --global --add safe.directory "$(pwd)/flutter"

# On Vercel the public API URL is injected via Project Settings → Env Vars.
: "${AIDHABITAT_API_BASE_URL:?AIDHABITAT_API_BASE_URL must be set in Vercel env}"

exec "$SCRIPT_DIR/tool/build_web.sh"
