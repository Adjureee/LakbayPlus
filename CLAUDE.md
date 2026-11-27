# Lakbay monorepo

Flutter traveler app (`apps/traveler_app`), Flutter admin web (`apps/admin_app`) and a FastAPI
backend (`services/api`). Backend working rules are in `services/api/AGENTS.md`; read it before
changing backend code (it requires asking before code changes and approval for schema changes).

## Skills activate on their own

Project skills live in `.claude/skills/`. Invoke the matching one with the Skill tool at the
start of the work, without waiting for the user to name it. A hook (`.claude/hooks/skill_router.py`)
also flags the match on each prompt; follow it.

| The task involves | Skill |
|---|---|
| Running or choosing tests, `flutter analyze`, "make sure nothing broke", a changed API field | `lakbay-verify` |
| AI chat accuracy, stress or baseline runs, any live Groq or Gemini call | `lakbay-ai-accuracy` |
| Routes, Mapbox/OSRM, snap rules, sea crossings, map geometry, route notices | `lakbay-routing-geo` |

When a task touches two areas, invoke both (a routing change ends with `lakbay-verify`).

## Working defaults

- Live model or routing calls spend shared quota (Groq 200k tokens/day). Make none unless the
  user asks, and follow the cap in `lakbay-ai-accuracy`.
- Run any command expected to take more than about two minutes in the background.
- Delegate a read-only sweep across many files to a subagent; do the edits and test runs here.
- Do not commit unless asked: the working tree usually holds uncommitted work.
