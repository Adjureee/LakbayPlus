# Handoff: remaining work on Lakbay+ (state on 2026-11-27)

For an agent or person continuing the work. **Every statement below is either (a) tied to a command or file you can re-run, or (b) marked UNVERIFIED.** Nothing here is a guess presented as fact.

## 0. Rules (read before touching anything)

1. **Evidence first.** For each task, run its "Check" command before changing anything and compare with "Expected". If the output differs, **stop and report the difference**; do not adapt the plan on your own.
2. **Do not invent.** If a file, value or behaviour is not shown by a command or a file you opened, write `UNVERIFIED` and ask. Line numbers drift: the server's cost string was at line 1387 earlier today and is at 1392 now, so **grep for the text, do not trust a line number**.
3. **No live model calls.** Groq's free tier is 200,000 tokens a day, shared with real users (source: owner's note dated 2026-11-19, so **dated**; re-probe before relying on it). A live accuracy run is Gemini only, at most 20 calls (`docs/AI_CHAT_ACCURACY_AUTOMATION_PLAN.md` section 7). Never call the production guest endpoint.
4. **Backend code and database changes need the owner's approval first** (`services/api/AGENTS.md`, working rules 1 and 3). Flutter-only changes do not.
5. **No AI attribution in commits or PRs** (owner's explicit instruction: no `Co-Authored-By` line). Never rewrite published history without an explicit ask; `main` was rewritten once, on request, today (section 1).
6. **Never commit** `apps/traveler_app/android/app/google-services.json` (it is untracked on purpose) or any `.env`.
7. **Do not push, merge or open a PR unless told.** The repo's merge convention is a branch, its commits, then a `--no-ff` merge commit titled `Merge: <summary>` (evidence: `git log main --oneline`, section 1).
8. Environment: Windows. Git Bash and PowerShell both work. "LF will be replaced by CRLF" warnings are normal. `flutter pub get` regenerates plugin-registrant files under `linux/`, `macos/` and `windows/`; treat that as noise, not part of a change.

## 1. Verified state (commands run on 2026-11-27)

| Fact | Command | Result seen |
|---|---|---|
| Date | `date` | 2026-11-27 |
| Branch tips | `git rev-parse --short main origin/main feat/cycling-traffic origin/feat/cycling-traffic` (one name at a time) | main = origin/main = `7f96ddb`; feat/cycling-traffic = origin/feat/cycling-traffic = `de6b7d9` |
| Branch ahead of main | `git rev-list --left-right --count main...HEAD` on feat/cycling-traffic | `0 3` (three commits: `4cd0c59` tooling, `2a41c08` docs, `de6b7d9` code) |
| Working tree | `git status --short` | only `?? apps/traveler_app/android/app/google-services.json` |
| Recent main | `git log main --oneline -9` | F3 `7ef60aa`/`7f96ddb`, F2 `31a2ce9`/`ded5d88`, F1 `ddc2a89`/`599cb7c`, analytics `7424ffe`/`7560692` |
| Flutter analyze | `flutter analyze --no-pub` in `apps/traveler_app` | 1 issue: warning at `test/profile_history_abc_test.dart:17:25` (existing, untouched) |
| Flutter tests | `flutter test --no-pub -j 2` in `apps/traveler_app`, on `de6b7d9` | `+374: All tests passed!` |
| Backend focused tests | `./.venv/Scripts/python.exe -m pytest -q tests/test_mapbox_directions.py tests/test_timeline.py tests/test_timeline_api.py tests/test_destination_hours.py tests/test_nature_scoring.py tests/test_ai_go_ahead.py tests/test_ai_itinerary_geo_quality.py tests/test_accuracy_replay.py tests/test_route_plan.py tests/test_phase6_routes.py tests/test_planning_routes.py tests/test_planning_chat.py tests/test_guest_chat.py` in `services/api` | `390 passed` (253 s), run earlier today on the same files |
| **Full backend suite** | not run | **UNVERIFIED** |
| PRs | `gh pr list --state all --limit 5` | one PR ever (MERGED 2026-11-15, `feature/routing-ai-davao-data`); none for feat/cycling-traffic |
| Leftover local state | `git worktree list`, `git stash list` | worktrees `analytics`, `ux-f1`, `ux-f2`, `ux-f3`, `claude/keen-tereshkova-4312aa`; `stash@{0}` "cycling-move-1795716239" |
| Backup branches | `git branch --list "backup/*"` | `backup/pre-rewrite-main` (`1a2b14d`), `backup/pre-strip-main` (`cd0fc41`) |
| History rewrite | `git reflog show main -3 --date=iso` | `main@{2026-11-27 01:55:00 +0800}: filter-branch: rewrite` (129 trailers removed per owner's request; **every hash on main changed**). Old clones and the old local branches `feat/analytics`, `feat/ux-f1..f3` no longer share history with main |
| Unrelated remote branch | `git branch -r` | `origin/ui-ux-updates`; `git merge-base origin/ui-ux-updates main` printed nothing (no shared history) |
| Catalog snapshot | python reading `services/api/tests/accuracy/corpus/catalog.json` | 63 places, 41 with a photo, 36 with `estimated_cost > 0`, 45 distinct `category` values; file last committed 2026-11-20, so **a snapshot, not live data** |

(The 129 removed `Co-Authored-By: Claude` lines were counted before the push as 114 + 14 + 1.)

## 2. What is already done (do not redo)

- **F0:** baseline `docs/FLAGSHIP_UX_BASELINE.md`, user-test kit `docs/FLAGSHIP_UX_USER_TEST.md`; analytics and crash reporting (`apps/traveler_app/lib/services/analytics_service.dart`, `firebase_analytics_setup.dart`; off in debug builds: `kDebugMode` at `firebase_analytics_setup.dart` lines 28 and 40; off at startup via `firebase_analytics_collection_enabled` in `AndroidManifest.xml`).
- **F1** plain wording and trip fixes, **F2** two clearly named planning doors, **F3** no wrong-place photos and travel times that name their start. Details and corrections are in `docs/FLAGSHIP_UX_PLAN.md` sections F1 to F3.
- **Cycling mode, live traffic, AI itinerary checks, hours/timeline fixes:** commit `de6b7d9` (message lists them).
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

**A1. Run the full backend suite and report.**
- Check: `cd services/api; ./.venv/Scripts/python.exe -m pytest -q` (run in the background; `docs/ADMIN_APP_CONTEXT.md` says about 14 minutes, which is **dated**).
- Expected: UNVERIFIED. Report the exact pass/fail counts. If something fails, quote the test and error and check whether the file is one changed in `de6b7d9` (`git show --stat de6b7d9`). Do not edit unrelated tests to make them pass.

**A2. Tidy local git state** (only after the owner says yes, because it deletes):
- Branches/worktrees: `feat/analytics`, `feat/ux-f1`, `feat/ux-f2`, `feat/ux-f3`, `claude/keen-tereshkova-4312aa`, `backup/pre-rewrite-main`, `backup/pre-strip-main`, and ref `refs/original/refs/heads/main`; `stash@{0}` (it was checked file by file against the working tree before commit; apart from `google-services.json`, which is still untracked in the working tree, its content is in the three commits).
- Check each is merged or redundant before deleting. The `feat/ux-*` and `feat/analytics` branches are on the old history, so `git branch --merged main` will **not** list them even though their content is in main; compare with `git diff --stat <branch> main` instead.

## 5. Tasks that need an owner decision first

| # | Item | Evidence | Decision needed |
|---|---|---|---|
| D1 | Open a PR for `feat/cycling-traffic` | branch pushed, no PR (section 1); GitHub offers `.../pull/new/feat/cycling-traffic` | open now, or run A1 first |
| D2 | "Cost not listed" | text is built in `services/api/app/features/recommendations/service.py` (grep `Cost not listed`); the catalog snapshot has no website or phone field (`catalog.json` keys, listed when the baseline was written) so a "contact the place" action would be invented | change wording (backend change, needs approval), or fill the 27 costs, or add a "Suggest a price" feature |
| D3 | Insider wording the scan does not cover | `apps/traveler_app/lib/models/travel_models.dart` lines about 1043 to 1052: `'Adaptive NN + 2-opt'`, `'Nearest-Neighbor'`, `'OSRM roads'`, `'Google roads'`, `'On-device Haversine'` | exact replacement wording |
| D4 | "Top-5 Match" button (`explore_screen.dart`, grep `Top-5 Match`) | purpose for a traveler is **UNVERIFIED**; the owner never answered | what it does and what to call it |
| D5 | The `category` field is free text (45 values for 63 places) | snapshot count above | a controlled list (data change; backend if enforced) |
| D6 | Duplicate record "Sky Deck Garden Cafe and Restaurant" | appears twice in the snapshot (the earlier audit also noted ids 46 and 47) | which record to keep (data change) |
| D7 | Analytics is on by default with a Settings opt-out | `analytics_service.dart` (`enabled` defaults to true); `settings_screen.dart` toggle | whether that meets the owner's privacy-notice obligations; alternative is opt-in |
| D8 | `place_added` counts only adds through `toggleTripBuilderStop`, not AI-driven adds | `travel_repository.dart` (grep `analytics.placeAdded`) | whether AI adds should count |
| D9 | `docs/Lakbay_Project_Summary.pdf` and `docs/commute_drafts_review.json` were committed as they were found, unreviewed | commit `2a41c08` | keep in the repo or remove |
| D10 | Next plan phases not started: **F4** Home "continue your trip" card and popular row; **F5** "Show on map" on chat results; **F6** research spikes (offline, share link, ratings, guest-first) | `docs/FLAGSHIP_UX_PLAN.md` headings `### F4`, `### F5`, `### F6` | gates: G2 needs user-test round 2; G3 needs two weeks of analytics (plan section 1a). F6 items each need their own approval |

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
