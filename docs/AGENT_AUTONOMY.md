# Agent Autonomy Standing Contract

Effective: 2026-11-27 (active until revoked in writing by the owner).

## Go Without Asking
- Read-only commands; `flutter analyze` and tests; backend tests (never live model calls).
- Edit Flutter/Dart code, tests and docs. Backend code changes that need no schema or migration change, when the backend suite passes afterwards.
- Work on `feat/cycling-traffic` or a new feature branch. Commit with no AI attribution. Push feature branches (never `main`).
- Open a PR for a feature branch into `main`. Do not merge it.
- Delete local branches/worktrees only after `git diff --stat <branch> main` shows nothing unique.
- Update `docs/HANDOFF_REMAINING_WORK.md` after each task.

## Hard Stops (Always Ask the Owner)
- Push or merge to `main`.
- Force-push or any history rewrite.
- Database schema or migration.
- Any production data change (unless explicitly approved for a specific record/task).
- New dependencies.
- Live model calls (Groq, Gemini beyond 20 calls a day, the production guest endpoint, Mapbox beyond 5 calls).
- Anything needing a device, a console or the owner's login.
- Deleting backups (`backup/*`) or `refs/original`.

## Evidence
- For every task, paste the check command and its output before changing anything, then the proving command and its output.
- Mark anything unverified as `UNVERIFIED`.
- If output differs from what was expected, stop and report; do not adapt.

## Failures
- Retry once, then stop and report with the exact error.

## Secrets
- Read credentials only from environment variables.
- Never print them, write them to a file, or commit them.
- If a variable is missing, stop (or skip if instructed) and tell the owner its name.

## Report
- One evidence block per task, then one final summary listing what is done, what stopped and why.
