#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
tmp_dir="${TMPDIR:-/tmp}/aid_habitat_app_test_safe"

rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

rsync -a \
  --exclude '.dart_tool' \
  --exclude 'build' \
  --exclude '.flutter-plugins-dependencies' \
  "$app_dir/" \
  "$tmp_dir/"

cd "$tmp_dir"
flutter test "$@"
