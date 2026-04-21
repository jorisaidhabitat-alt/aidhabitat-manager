#!/usr/bin/env bash
# Auto-commit hook — runs on every agent Stop.
# Commits any pending changes on main with an automatic message.
# - Skips silently when the working tree is clean.
# - NEVER uses --no-verify (hooks and signing stay enforced).
# - Includes a Claude co-author trailer.
# - Only runs when HEAD is on `main` (no-op on branches/worktrees).

set -u

REPO="/Users/aidhabitat/Downloads/aid'habitat-manager"
cd "$REPO" 2>/dev/null || exit 0

# Only auto-commit when we're on main. Avoids clobbering work on feature
# branches or in nested worktrees spawned by parallel agents.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ "$branch" != "main" ]; then
  exit 0
fi

# Clean tree → nothing to commit.
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  exit 0
fi

git add -A

ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
msg="auto-commit: agent session end $ts

Co-Authored-By: Claude <noreply@anthropic.com>"

# No --no-verify: pre-commit hooks must run. If they fail, we leave the
# changes staged so the next manual commit can address them, but we do
# not block the agent's Stop event.
git commit -m "$msg" >/dev/null 2>&1 || true
exit 0
