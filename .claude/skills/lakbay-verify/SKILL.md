---
name: lakbay-verify
description: Run, choose or report tests and static analysis for the Lakbay monorepo (pytest in services/api, flutter test and flutter analyze in apps/traveler_app and apps/admin_app). Use whenever the user asks to run tests, check that a change works, "verify", "make sure nothing broke", or after changing an API schema or field that the Flutter apps read, even if they do not name a test command. Invoke this automatically at the start of such work, and again before reporting a change as done; the user should never have to ask for it.
---

# Verify a Lakbay change

Pick the smallest suite that proves the change. The full backend suite is slow (about 14 minutes per `docs/ADMIN_APP_CONTEXT.md`, a dated figure), so a focused run first and the full run only when the user asks for it or a change is wide.

## Backend (services/api)

Run from `services/api`. The venv python works in both Bash and PowerShell with forward slashes:

```
./.venv/Scripts/python.exe -m pytest -q tests/<file>.py
```

Tests use in-memory SQLite (`tests/conftest.py`), so no database or network is needed. Choose files by area:

| Change area | Run |
|---|---|
| AI chat, prompts, resolver, grounding | `test_ai_*.py test_planning_*.py test_chat_prompt_rules.py test_grounding*.py test_claims_check.py test_guest_chat.py test_destination_resolver.py test_accuracy_replay.py` |
| Routes, ordering, sea, snap, providers | see the `lakbay-routing-geo` skill |
| Recommendations / scoring | `test_phase3_recommendations.py test_top_places_*.py test_route_feasible_recommendations.py` |
| Trips, budgets, expenses | `test_phase7_trips.py test_phase4_budget_engine.py test_phase9_expenses.py` |
| Anything else | `-k <keyword>` against `tests/`, then ask before the full run |

Full suite (only on request, run it in the background and report the final counts): `./.venv/Scripts/python.exe -m pytest -q` from `services/api`.

Files in `tests/` without a `test_` prefix (`stress_chat.py`, `claims_baseline.py`, `manual_live_*.py`, `stress_ai_rate_limit.py`) are opt-in live scripts that call real models. Never run them as part of verifying; use the `lakbay-ai-accuracy` skill instead, because they spend shared API quota.

## Flutter (apps/traveler_app, apps/admin_app)

Run from the app folder. `--no-pub` avoids a network fetch, and `-j 2` is the project's setting:

```
flutter analyze --no-pub
flutter test --no-pub -j 2 test/<file>_test.dart
```

A first run is slow (two route tests took about a minute). Run `flutter pub get` only if `pubspec.yaml` changed. If `pub get` leaves the generated plugin registrant files (`macos/`, `windows/`) modified, treat that as noise rather than part of the change.

## When an API response or field changes

The backend and the two Flutter apps share a contract only by convention (snake_case JSON, hand-written Dart mappers), so nothing fails to compile when one side moves. Check each:

1. Backend schema in `services/api/app/features/<feature>/schemas.py` and its test.
2. Traveler mappers: `apps/traveler_app/lib/services/lakbay_api_catalog_service.dart`, `lakbay_ai_service.dart`, `travel_repository.dart` and `lib/models/*.dart`, plus the matching tests.
3. Admin: `apps/admin_app/lib/services/` and `test/api_service_test.dart`.

Say which of the three you updated or confirmed unaffected. Adding or changing database tables or columns needs the user's approval first (`services/api/AGENTS.md`), and so does editing backend code in general: ask before implementing.

## Definition of done

- Report exactly which commands ran and their pass/fail counts; do not say "all tests pass" after a partial run.
- If something fails, quote the failing test and error. Check whether the file is one you touched before deciding it is yours; never edit an unrelated test to turn it green.
- State what was not run (full suite, admin app, phone check).
- Do not commit. The working tree often holds the user's uncommitted work.
