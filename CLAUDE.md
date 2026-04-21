# aid'habitat-manager — agent rules

## Absolute rules for every Claude Code session

1. **Always work on `main`.** Never create branches or worktrees unless the
   user explicitly asks for one. Before any edit, run `git rev-parse
   --abbrev-ref HEAD` and confirm it prints `main`. If not, check out main
   first (stashing any WIP in a commit, not in `git stash`).

2. **Before finishing a turn, verify no work is orphaned.** Run:

   ```bash
   git branch -a            # list local + remote branches
   git log --all --oneline --not main | head -20   # any commit not in main?
   git worktree list         # any secondary worktree?
   ```

   If any output shows work that isn't in `main`, surface it to the user
   in plain French and ask whether to merge, cherry-pick, tag, or discard
   before you stop. Do NOT stop with unmerged work without mentioning it.

3. **Never use `git stash` for anything you care about.** Stashes get
   dropped silently during rebases and auto-stashes. Always make a real
   commit — even WIP. Commit early, commit often.

4. **Never `--no-verify`, never `--force` on main.** Pre-commit hooks and
   signing stay enforced. Force-push to main is forbidden.

5. **Commits on this project auto-run a Stop hook** that commits any
   pending changes and warns about orphan branches/worktrees. Do not
   fight the hook — trust it. If you see a "Travail non mergé" warning in
   the system message at end of turn, reconcile it in the next response
   (merge, or explain why it should stay on its branch).

## Parallel-agent discipline

The user often runs 3–5 agents in parallel on this repo. That means:

- Your commits may race with another agent's commits. Git's lockfile
  serializes — this is safe — but you may need to `git pull --rebase` if
  you see a "Updates were rejected" error.
- Before a rebase, commit all your WIP first (see rule 3). Never rebase
  with dirty tree.
- Avoid destructive operations on shared state (reset, force-push, branch
  delete) without confirming with the user.

## Project quick facts

- Flutter app: `aid_habitat_app/` (macOS + iPadOS web PWA targets).
- Express backend: `server/` (talks to NocoDB via `server/nocodbMcpClient.mjs`).
- React web app: root `components/`, `App.tsx`, `services/dataService.ts`.
- NocoDB connection: `NOCODB_API_URL` + `NOCODB_API_TOKEN` in `.env.local`.
- Dev server: `node server/index.mjs` on `:3001`.
- App session token in Flutter: set at runtime by `AuthService` after
  login. Fallback `local-auth:<base64-email>` is generated if the remote
  login fails but the local hash matches.

## Recovery lifelines (in case of data loss)

- `backup_main_before_recovery_20260421` — snapshot of main before the
  2026-04-21 recovery.
- `wip_recover_*` tags (×17) — dangling commits from April 2026 that
  contained the Flutter work the user thought was lost. Safe to reference.
- Always check `git reflog` and `git fsck --no-reflogs --lost-found`
  before declaring any commit "lost forever".
