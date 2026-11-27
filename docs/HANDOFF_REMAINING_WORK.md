# Handoff: remaining work on Lakbay+ (state on 2026-11-27)

For an agent or person continuing the work. **Every statement below is either (a) tied to a command or file you can re-run, or (b) marked UNVERIFIED.** Nothing here is a guess presented as fact.

## 0. Rules (read before touching anything)

1. **Evidence first.** For each task, run its "Check" command before changing anything and compare with "Expected". If the output differs, **stop and report the difference**; do not adapt the plan on your own.
2. **Do not invent.** If a file, value or behaviour is not shown by a command or a file you opened, write `UNVERIFIED` and ask. Line numbers drift: the server's cost string was at line 1387 earlier today and is at 1392 now, so **grep for the text, do not trust a line number**.
3. **No live model calls.** Groq's free tier is 200,000 tokens a day, shared with real users (source: owner's note dated 2026-11-19, so **dated**; re-probe before relying on it). A live accuracy run is Gemini only, at most 20 calls (`docs/AI_CHAT_ACCURACY_AUTOMATION_PLAN.md` section 7). Never call the production guest endpoint.
4. **Backend code and database changes need the owner's approval first** (`services/api/AGENTS.md`, working rules 1 and 3). Flutter-only changes do not.
5. **No AI attribution in commits or PRs** (owner's explicit instruction: no `Co-Authored-By` line). Never rewrite published history without an explicit ask; `main` was rewritten once, on request, today (section 1).
6. **Never commit** `apps/traveler_app/android/app/google-services.json` (it is untracked on purpose) or any `.env`.
7. **Standing contract:** `docs/AGENT_AUTONOMY.md` (commit `aba54a4`) governs hands-off execution and hard stops until revoked in writing. Never push or merge to `main` without explicit approval. The repo's merge convention is a branch, its commits, then a `--no-ff` merge commit titled `Merge: <summary>` (evidence: `git log main --oneline`, section 1).
8. Environment: Windows. Git Bash and PowerShell both work. "LF will be replaced by CRLF" warnings are normal. `flutter pub get` regenerates plugin-registrant files under `linux/`, `macos/` and `windows/`; treat that as noise, not part of a change.

## 1. Verified state (commands run on 2026-11-27)

| Fact | Command | Result seen |
|---|---|---|
| Date | `date` | 2026-11-27 |
| Branch tips | `git rev-parse --short main origin/main` and `feat/cycling-traffic` | `main` = `origin/main` = `7f96ddb`; `feat/cycling-traffic` through `a29a843` (+ this handoff update) |
| Working tree | `git status --short` | only `?? apps/traveler_app/android/app/google-services.json` (untracked on purpose) |
| Recent main | `git log main --oneline -9` | F3 `7ef60aa`/`7f96ddb`, F2 `31a2ce9`/`ded5d88`, F1 `ddc2a89`/`599cb7c`, analytics `7424ffe`/`7560692` |
| Flutter analyze | `flutter analyze --no-pub` in `apps/traveler_app` (on D7 `21a1cbd`) | 1 issue: pre-existing warning at `test/profile_history_abc_test.dart:17:25` (ran in 17.5s) |
| Flutter tests | `flutter test --no-pub -j 2` in `apps/traveler_app` (on D3 `d8d4931` and D7 `21a1cbd`) | `+374: All tests passed!` |
| **Full backend suite (A1)** | `cd services/api; ./.venv/Scripts/python.exe -m pytest -q` (on `f429140`) | `1313 passed, 1 skipped, 87 warnings in 943.53s (0:15:43)` (0 failed). Skipped: `tests/test_app_assessments_postgres.py:184` (`LAKBAY_ASSESSMENT_TEST_DATABASE_URL` not set — live Postgres test **UNVERIFIED**) |
| PRs | `gh pr create --base main --head feat/cycling-traffic` | PR opened for `feat/cycling-traffic` -> `main` (not merged) |
| Local git cleanup (A2) | `git worktree list`, `git stash list`, `git branch -v` | Only repo root worktree registered; `stash@{0}` dropped; `feat/analytics`, `feat/ux-f1..f3` deleted; branch `claude/keen-tereshkova-4312aa` kept; leftover folder `.claude/worktrees/keen-tereshkova-4312aa` unregistered from git but locked on disk by another Windows process |
| Backup branches | `git branch --list "backup/*"`, `git for-each-ref refs/original` | Kept intact: `backup/pre-rewrite-main` (`1a2b14d`), `backup/pre-strip-main` (`cd0fc41`), `refs/original/refs/heads/main` (`1a2b14d`) |
| History rewrite | `git reflog show main -3 --date=iso` | `main@{2026-11-27 01:55:00 +0800}: filter-branch: rewrite` (129 trailers removed per owner's request; **every hash on main changed**) |
| Unrelated remote branch | `git branch -r` | `origin/ui-ux-updates`; `git merge-base origin/ui-ux-updates main` printed nothing (no shared history) |
| Catalog snapshot | python reading `services/api/tests/accuracy/corpus/catalog.json` | 63 places, 41 with a photo, 36 with `estimated_cost > 0`, 45 distinct `category` values; file last committed 2026-11-20, so **a snapshot, not live data** |

(The 129 removed `Co-Authored-By: Claude` lines were counted before the push as 114 + 14 + 1.)

## 2. What is already done (do not redo)

- **F0:** baseline `docs/FLAGSHIP_UX_BASELINE.md`, user-test kit `docs/FLAGSHIP_UX_USER_TEST.md`; analytics and crash reporting (`apps/traveler_app/lib/services/analytics_service.dart`, `firebase_analytics_setup.dart`; off by default via D7 `21a1cbd`, off in debug builds via `kDebugMode`, off at startup via `AndroidManifest.xml`).
- **F1** plain wording and trip fixes, **F2** two clearly named planning doors, **F3** no wrong-place photos and travel times that name their start. Details and corrections are in `docs/FLAGSHIP_UX_PLAN.md` sections F1 to F3.
- **Cycling mode, live traffic, AI itinerary checks, hours/timeline fixes:** commit `de6b7d9` (message lists them).
- **Standing contract:** `docs/AGENT_AUTONOMY.md` (`aba54a4`).
- **A1 (full backend suite):** `1313 passed, 1 skipped` on `f429140`.
- **A2 (local git cleanup):** deleted `feat/analytics`, `feat/ux-f1..f3`, `stash@{0}`, and unregistered all 5 worktrees (backups preserved).
- **D3, D4, D5, D7, D9:** plain route labels (`d8d4931`), `"Top 5 for you"` rename (`9b74e87`), 8-kind category taxonomy proposal (`96aa821`), opt-in analytics + consent prompt design doc (`21a1cbd`), removed outdated summary PDF & commute drafts JSON (`a29a843`).
- **Project skills** under `.claude/skills/` (Claude Code format; their command lists are still a valid reference): `lakbay-verify`, `lakbay-ai-accuracy`, `lakbay-routing-geo`.

## 3. Tasks only the owner or a device can do (do not simulate)

| # | Task | Why it cannot be automated | Evidence it is open |
|---|---|---|---|
| H1 | Look at F1/F2/F3 on a phone: Home, Discover, Trips, the My Trips "+" sheet, the Discover tray's Plan sheet, a chat card for a place with no photo | needs a device | no phone check was ever done (UNVERIFIED visually) |
| H2 | Confirm analytics events arrive: build a **release or profile** build and watch Firebase DebugView | debug builds send nothing by design (`!kDebugMode`) | no event has been observed |
| H3 | Firebase console: enable Analytics and Crashlytics; update the Play **Data Safety** form | console access | not done |
| H4 | User test round 1 (5 to 8 travelers), fresh screenshots, taps and seconds to first result | people and a phone | `docs/FLAGSHIP_UX_BASELINE.md` section 4 lists these as "Still to measure" |
| H5 | Enter the missing data in the admin app: **22 places without a photo, 27 without a known cost** | admin access and real photos/prices | lists are in `docs/FLAGSHIP_UX_BASELINE.md` section 1 (from the 2026-11-20 snapshot; refetch before using) |

## 4. Tasks an agent can do without a decision

**A1. Done (2026-11-27, commit `f429140`).**
- Command: `cd services/api; ./.venv/Scripts/python.exe -m pytest -q`
- Result: `1313 passed, 1 skipped, 87 warnings in 943.53s (0:15:43)` (0 failed). Skipped: `tests/test_app_assessments_postgres.py:184` (`LAKBAY_ASSESSMENT_TEST_DATABASE_URL is not set` — live Postgres test **UNVERIFIED**).

**A2. Done (2026-11-27).**
- Deleted branches `feat/analytics`, `feat/ux-f1`, `feat/ux-f2`, `feat/ux-f3` (after verifying `git diff --diff-filter=D --name-only <branch> main` empty for each), dropped `stash@{0}`, and unregistered all 5 worktrees.
- Kept `backup/pre-rewrite-main`, `backup/pre-strip-main`, `refs/original/refs/heads/main`, and branch `claude/keen-tereshkova-4312aa`.
- Leftover Windows folder `.claude/worktrees/keen-tereshkova-4312aa` is unregistered from git but could not be removed (`The process cannot access the file because it is being used by another process.`); delete manually once the locking process closes.

## 5. Decisions & task status (D1–D10)

| # | Item | Evidence / Status | Next step |
|---|---|---|---|
| D1 | **Done:** push `feat/cycling-traffic` and open PR into `main` | pushed to `origin/feat/cycling-traffic`; PR opened (not merged) | owner reviews & merges after H1 |
| D2 | **Closed (no change):** "Cost not listed" wording | owner decided to fix with data entry, not wording | handled via H5 |
| D3 | **Done (`d8d4931`):** plain-word route labels in `travel_models.dart` and `explore_screen.dart:2496-2497` | `Shortest order` / `Optimized order` / `Nearest stop first` / `Your stop order`; `Road distances` / `Straight-line estimate`; `+374` Flutter tests green | closed |
| D4 | **Done (`9b74e87`):** renamed `"Top-5 Match"` to `"Top 5 for you"` | `explore_screen.dart:332` and `high_grade_planner_test.dart:309`; tests green | closed |
| D5 | **Done — proposal only (`96aa821`):** 8-kind category taxonomy | `docs/CATEGORY_TAXONOMY_PROPOSAL.md` (45 snapshot categories -> 8 kinds; live DB **UNVERIFIED**) | owner review before any data/backend change |
| D6 | **Pending (skipped):** deactivate duplicate `"Sky Deck Garden Cafe and Restaurant"` (id `47`) | approved for id `47` only; skipped because `LAKBAY_ADMIN_EMAIL` and `LAKBAY_ADMIN_PASSWORD` were unset in the environment. Live DB records **UNVERIFIED** (snapshot `catalog.json` shows ids `46` and `47` differ only on `destination_id`, `created_at`, `updated_at`) | set env vars and re-run D6 procedure |
| D7 | **Done (`21a1cbd`):** analytics switched to opt-in (off by default) + consent prompt design doc | `analytics_service.dart`, `firebase_analytics_setup.dart`, `settings_screen.dart`, `analytics_service_test.dart` (`+374` green); design proposal at `docs/ANALYTICS_CONSENT_PROMPT_DESIGN.md` (not implemented) | publish privacy notice & approve prompt implementation later |
| D8 | **Closed (no change):** `place_added` event scope | owner decided no change | closed |
| D9 | **Done (`a29a843`):** removed `docs/Lakbay_Project_Summary.pdf` and `docs/commute_drafts_review.json` | `git rm` + `git ls-files` empty | closed |
| D10 | **On hold:** **F4** approved only after owner confirms H1; **F5** & **F6** on hold until G2 (user-test round 2) and G3 (two weeks of analytics) | `docs/FLAGSHIP_UX_PLAN.md` sections 1a, F4–F6 | wait for H1 confirmation before starting F4 |

## 6. Known limits (do not treat as bugs found today)

- Trips saved before F3 keep the photo they were saved with, so an old saved trip can still show a regional photo (`docs/FLAGSHIP_UX_PLAN.md`, F3 "Known gap").
- Removing a trip offers Undo for 6 seconds; if the app closes inside that window the cloud copy may come back on the next sync (comment on `removeSavedTripWithUndo` in `travel_repository.dart`).
- The persisted bucket-list key `'Island Garden City of Samal (IGaCoS)'` (grep in `travel_repository.dart`) is allow-listed in `apps/traveler_app/test/plain_words_test.dart` because changing it would orphan saved choices.
- The wording test also allow-lists the required "© Mapbox" credit in `lakbay_mapbox_widget.dart` and `mapbox_service.dart`; do not remove those credits.

## 7. Commands that were run and worked (copy, do not improvise)

```
# Flutter, from apps/traveler_app
flutter analyze --no-pub
flutter test --no-pub -j 2 test/<file>_test.dart      # one file
flutter test --no-pub -j 2                            # everything (about 2 minutes)

# Backend, from services/api
./.venv/Scripts/python.exe -m pytest -q tests/<file>.py

# Git, from the repo root
git fetch origin main
git rev-list --left-right --count main...origin/main   # expect "0 0" when in sync
```

## 8. How to report each task

For every task, reply with: (1) the check command and its exact output, (2) what you changed (file paths), (3) the command that proves it and its output, (4) anything you could not verify, marked `UNVERIFIED`. If a step needs a decision from section 5 or a device from section 3, stop and say so; do not fill the gap.
