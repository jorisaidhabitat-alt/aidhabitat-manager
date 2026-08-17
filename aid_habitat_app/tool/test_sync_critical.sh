#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$script_dir/test_safely.sh" \
  test/models/autonomy_item_names_test.dart \
  test/services/offline_persistence_test.dart \
  test/services/sync_engine_remote_session_test.dart \
  test/services/dossier_remote_context_merge_test.dart \
  test/services/dossier_remote_child_merge_test.dart \
  test/services/sync_errors_test.dart
