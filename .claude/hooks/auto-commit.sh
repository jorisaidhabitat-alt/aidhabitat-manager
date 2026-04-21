#!/usr/bin/env bash
# Auto-commit + orphan-detect hook.
# Runs on every agent Stop. Anchored to THIS project so it fires from the
# main repo AND from any .claude/worktrees/* worktree — but never from
# unrelated projects (installed in user-global settings.json too).
#
# Behavior:
#   1) Refuse to run unless cwd is inside this project's git tree.
#   2) Commit any pending changes on the CURRENT branch (main or worktree).
#      Never uses --no-verify. Adds a Claude co-author trailer.
#   3) Scan for unmerged branches / orphan commits relative to main, and
#      emit a systemMessage so the agent + user see it.

set -u

# Resolve the git toplevel of the current directory. Works for main repo
# AND for worktrees (git worktree uses a separate .git pointer file that
# rev-parse understands).
toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$toplevel" ]; then exit 0; fi

# Project sentinel: only run this hook inside the aid'habitat project.
# We check for a file that exists in main AND would be checked out in
# any worktree cloned from it.
if [ ! -f "$toplevel/aid_habitat_app/pubspec.yaml" ]; then
  exit 0
fi

cd "$toplevel" || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

# --- 1) Auto-commit pending changes on the current branch --------------
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git add -A
  ts=$(date "+%Y-%m-%d %H:%M:%S %Z")
  msg="auto-commit: agent session end $ts (branch=$branch)

Co-Authored-By: Claude <noreply@anthropic.com>"
  # No --no-verify: pre-commit hooks + signing stay enforced. On failure
  # we leave the changes staged for the next manual commit.
  git commit -m "$msg" >/dev/null 2>&1 || true
fi

# --- 2) Orphan-work detection (branches + worktrees not merged to main)
# Only meaningful if local `main` exists.
warnings=""
if git show-ref --verify --quiet refs/heads/main; then
  # Branches (local) whose tip is not reachable from main.
  unmerged_branches=$(git branch --no-merged main 2>/dev/null \
    | sed -E 's/^[* +]+//;s/[[:space:]]+$//' \
    | grep -v '^$' \
    | grep -v '^main$' \
    || true)

  # Worktrees whose HEAD isn't already in main.
  unmerged_worktrees=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    wt_path="${line#worktree }"
    wt_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    [ -z "$wt_branch" ] && continue
    [ "$wt_branch" = "main" ] && continue
    # If worktree HEAD commit is already an ancestor of main, skip.
    wt_head=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$wt_head" ] && git merge-base --is-ancestor "$wt_head" main 2>/dev/null; then
      continue
    fi
    unmerged_worktrees="${unmerged_worktrees}${wt_path} (${wt_branch})\n"
  done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ')

  if [ -n "$unmerged_branches" ] || [ -n "$unmerged_worktrees" ]; then
    warnings="⚠️ Travail non mergé sur main détecté — pense à merger ou ignorer avant de fermer cet agent.\n"
    if [ -n "$unmerged_branches" ]; then
      warnings="${warnings}Branches non mergées:\n${unmerged_branches}\n"
    fi
    if [ -n "$unmerged_worktrees" ]; then
      warnings="${warnings}Worktrees non mergés:\n${unmerged_worktrees}"
    fi
  fi
fi

# Emit systemMessage only when there's something to warn about.
if [ -n "$warnings" ]; then
  # printf -v not available in posix sh; use printf directly.
  # Escape for JSON (newlines → \n, quotes → \").
  payload=$(printf '%s' "$warnings" \
    | python3 -c 'import sys,json; print(json.dumps({"systemMessage": sys.stdin.read()}))' \
      2>/dev/null \
    || printf '{"systemMessage": %s}' "\"${warnings//\"/\\\"}\"")
  printf '%s\n' "$payload"
fi

exit 0
