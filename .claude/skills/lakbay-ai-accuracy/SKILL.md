---
name: lakbay-ai-accuracy
description: Measure or change the accuracy of the Lakbay AI chat (cards, suggested replies, claims, itinerary quality), edit tests/accuracy, stress_chat.py or claims_baseline.py, or make ANY live Groq or Gemini call. Use whenever the user asks "is the chat accurate", wants a stress or baseline run, a model comparison, or a live check of the guest chat, and before any request that would spend Groq or Gemini quota. Invoke this automatically before the first live call or run; the user should never have to ask for it.
---

# Lakbay AI chat accuracy and live-call budget

Design source: `docs/AI_CHAT_ACCURACY_AUTOMATION_PLAN.md`. Steps K2 to K5 there (card oracle, suggestion rules, live runner) are not built yet; K1 (shared checks and replay) is.

## Order of work: free first, live last

1. **Offline replay (no model, no network, seconds).** From `services/api`:
   ```
   ./.venv/Scripts/python.exe -m pytest -q tests/test_accuracy_replay.py tests/test_claims_check.py tests/test_grounding.py tests/test_chat_prompt_rules.py
   ```
   `tests/accuracy/checks.py` holds the rules (`CHECKS`), `replay.py` runs saved answers from `tests/accuracy/corpus/` (`cases.json`, `real_replies.json`, `catalog.json`, `rates.json`). A case is `id, note, text, body, expect_failed, state` and optionally `origin_label, lang, user_numbers, picked_before, step`.
2. **Changing a check or the reply-shaping code:** a replay difference names the case that flipped. Decide whether the check or the old expectation was wrong and say which; do not edit `expect_failed` just to go green.
3. **A new bad answer found in the wild:** add it to the corpus with the checks it fails in `expect_failed`. Failures stay in the corpus on purpose, because they catch regressions in the checks themselves.
4. **Live run, only if the user asks for model behaviour** (does the model understand the sentence, do chips progress). See below.

## Live calls: the quota rules

- Groq free tier: `openai/gpt-oss-120b` allows 200,000 tokens/day, shared with real users. One chat call carries about 3 to 4k tokens, so roughly 50 calls use the day (memory note of 2026-11-19; re-probe before relying on it). The app's own guard (`GROQ_MODEL_REQUESTS_PER_DAY`) counts requests, not tokens, so passing it says nothing about the token cap.
- Project decision (plan section 7): live runs use **Gemini only** from the local `.env`, **at most 20 calls per run**. Raise the cap only if the user says so, and say what it will cost.
- The production guest endpoint (`lakbay-api-rioi.onrender.com/api/v1/ai/chat/guest`) spends Groq tokens. Do not call it unprompted. `tests/claims_baseline.py collect` calls it with 12 places x 4 questions = 48 calls, which is most of a day. `tests/manual_live_*.py` and `stress_ai_rate_limit.py` also spend quota. Run any of these only on an explicit request that names the cost.
- If Groq must be measured, probe first with a request of about 3k tokens and `max_tokens` 4096 (a 5-token probe succeeds even when real calls are refused) and read the TPD message.

## Running the stress script on Gemini only

`stress_chat.py` defaults to `CAP=300` and `REPEATS=3`, far beyond the budget, so always set them. Blanking the Groq key makes the app skip Groq and use the Gemini fallback. Do this in the Bash tool: in PowerShell, `$env:GROQ_API_KEY = ''` deletes the variable and the key in `.env` is used again.

Preflight, which must print `groq key set: False`:
```
GROQ_API_KEY= ./.venv/Scripts/python.exe -c "from app.core.config import get_settings as g; s=g(); print('groq key set:', bool(s.groq_api_key), '| fallback key set:', bool(s.fallback_llm_api_key))"
```

Run (the Gemini limit is 10 requests a minute, hence the 7 second delay):
```
GROQ_API_KEY= LAKBAY_STRESS_CATALOG=tests/accuracy/corpus/catalog.json LAKBAY_STRESS_RATES=tests/accuracy/corpus/rates.json LAKBAY_STRESS_CAP=20 LAKBAY_STRESS_REPEATS=1 LAKBAY_STRESS_DELAY=7 LAKBAY_STRESS_OUT=<scratch>/stress.json ./.venv/Scripts/python.exe -m pytest -q -s tests/stress_chat.py
```
Chip taps (`LAKBAY_STRESS_CHIPS`, default on) go through the same counter, so they count toward the cap. Check the printed `models answering:` line shows only Gemini models. Use `LAKBAY_STRESS_ONLY=id1,id2` to narrow the scenarios.

## Reporting

- Give counts ("18 of 20"), never "improved by 5%". Twenty calls is a small sample and one check moving by one is noise.
- Rule checks find problems; they do not prove quality. Never use a model judge as a pass/fail gate (it disagreed with the records in about half of its misses).
- Say how many live calls were made, on which provider, and that no Groq tokens were spent (or how many were).

## Definition of done

Offline replay passes or every difference is explained; any live run stayed within its cap on the stated provider; results and limits are reported as counts. Do not commit saved outputs unless asked.
