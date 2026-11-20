# AI chat accuracy automation plan

Status: **draft for review. Nothing here is built.** No database or app change is proposed. Decisions for you are in section 7.

## 1. What this is for

You asked to automate the testing of how accurate the AI chat's **cards** (the places it shows) and **suggestions** (the suggested replies under a message) are. Today that testing is done by hand, on request, and the last full measurement is from 17 Nov, before most of the fixes since. This plan makes it something that runs by itself, cheaply, and tells you when a change made the chat worse.

## 2. How cards and suggestions are produced

Knowing this decides what can be tested without the model.

| Part | Who produces it | Testable without a model? |
|---|---|---|
| **Which cards appear** | The model turns the sentence into a small **place query** (`categories`, `province`, `limit`, at most 5). The recommender then **ranks catalog places in code** (`recommendations/service.py`, `scoring.py`) | **Yes, the ranking part.** Given a place query and the catalog, the cards are deterministic |
| **Whether the model understood the sentence** ("waterfalls in Davao de Oro" becomes the right query) | The model | No, needs real model calls |
| **Suggested replies** | The model writes 2 or 3 short replies, each under 60 characters. The server drops them when a structured question is pending | Their **shape** can be checked by rules; whether they are good needs the model |
| **The reply text next to the cards** | The model, then the claims check | Partly (the existing checks) |

## 3. What exists and what is missing

| Exists | Gap |
|---|---|
| `tests/stress_chat.py`: 21 scripted conversations, 19 rule checks (card limits, no repeats, category match, ruled-out places, no cards for small talk, chip tap works, language, hours and prices supported) | It runs only by hand, always with the real model, so it competes with real users for Groq's 200,000 tokens a day. It was blocked by that cap three times |
| `tests/claims_baseline.py`: a judge that labels the facts in replies, plus a replay of the runtime claims check | Only the facts in the text, not cards or suggestions |
| A baseline of 17 Nov | Stale, and a different model mix (all Gemini) |
| Checks that cards **obey rules** | Nothing checks that they are the **right cards**: no expected answer per query, no measure of how many fit or whether the best known places appear |
| `chip_works`: a tapped suggestion gets a normal answer | Nothing checks that a suggestion is **relevant**: it asks for the next missing detail, does not repeat what the traveler already said, and is in their language |
| Results in prose in `docs/` | No saved numbers per deploy, so no trend and no "this got worse" alert |

## 4. The design: four layers

The first three need **no model and no quota** and run in the normal test suite. Only the fourth calls the model.

### Layer 1: replay of saved replies (offline)

Save a corpus of real chat answers, **including the ones that failed**, with the cards and suggestions each carried, and run every check over them on each test run. It catches mistakes in the checks themselves and regressions in the code that polishes replies (the claims check, the card filters). It cannot say anything about the model. The 58 replies and labels already saved for the claims work are the start of it, plus the stress runs.

### Layer 2: the card oracle (offline)

A list of about **25 golden queries**, each a place query plus an expected answer **derived from the catalog's own fields** (category, province, district, recorded flags), not from anyone's opinion. For each:

| Measure | Rule |
|---|---|
| **Precision** | Every card matches the asked category and province, using the recommender's own category matching |
| **Coverage** | If any catalog place matches, at least one card is shown |
| **Completeness** | If more than `limit` places match, exactly `limit` cards are shown (at most 5); if fewer, the shortfall reason is stated, never padded with unrelated places |
| **Honest ranking** | A recorded snapshot of the top cards per query; a change is **flagged for review**, not failed, because adding or editing a place legitimately changes it |
| **The existing rules** | No repeats, none already picked, none ruled out, none outside the Davao Region without saying so |

This tests the real recommender against the real catalog snapshot, so it also catches a data problem: a place with the wrong category simply fails precision.

### Layer 3: suggestion rules (offline, on saved replies and live ones)

Each suggested reply set is checked for:

- 2 or 3 replies, none over 60 characters, no duplicates;
- **not repeating what the state already holds** ("Just me" after the traveler count is set, a budget after one is given);
- in the traveler's language (the existing language check, applied to each reply);
- names only places in the catalog;
- none when a structured question is pending (the server's own rule).

### Layer 4: a live run, small and on a budget

The existing 21 scenarios plus the golden queries sent as sentences, with the real model. It adds the measures only the model can fail:

| Measure | Rule |
|---|---|
| **Query understanding** | The sentence became the right place query (categories, province, limit) |
| **Chip progress** | After tapping a suggestion, the conversation moves: a new detail is saved or cards appear, not a repeat of the same question |
| **The existing 19 checks** | Unchanged |

Budget: **20 calls a run**, about 80,000 tokens. That is within one day's allowance **only if nothing else uses it**, which is why decision 2 matters. Results are saved as a small JSON file per run (date, commit, provider, per-check pass counts) and compared with the previous run: a **check that dropped** is printed first.

## 5. What it will not tell you

- **A rule check finds problems; it does not prove quality.** A reply can pass every check and still be dull or unhelpful. The 17 Nov baseline said the same.
- **Twenty calls is a small sample.** A check that goes from 19 of 20 to 18 of 20 is noise. The report shows counts, never "improved by 5%".
- **Layers 1 to 3 do not test the model.** Only layer 4 does, and it is the layer limited by quota.
- **The judge is not the truth.** The claims work showed the judge disagreeing with the records in about half of its misses. Nothing here uses a model judge as a pass/fail gate.

## 6. Steps

| Step | Contents | Deploy risk |
|---|---|---|
| **K1** | Move the checks out of `stress_chat.py` into an importable module the harness and the tests share; build the replay corpus and run it in the normal suite | None: test code only |
| **K2** | The golden queries and the card oracle, run against the catalog snapshot | None |
| **K3** | The suggestion rules, on the corpus | None |
| **K4** | The live runner: 20 calls, saved results, comparison with the last run, a short printed report | None |
| **K5** | Optional: a schedule (weekly) so it runs without being asked | None |

Each step ships on its own. K1 to K3 add tests that fail on a real regression; K4 and K5 only report.

## 7. Decisions for you

1. **Where the corpus lives.** Commit the saved replies into `services/api/tests/accuracy/` (recommended: the replay then runs for everyone, and replies carry no personal data, only guest questions about places), or keep them out of the repo.
2. **Which model the live run uses.** **Gemini only, from the local `.env`** (recommended: it has its own daily allowance and never touches the Groq quota real users share), or the production guest endpoint (shows exactly what users get, but spends Groq tokens).
3. **How often.** Run after each deploy by one command (recommended), plus a weekly schedule only if you want it (K5), or only by hand.
4. **What fails the test suite.** Layers 1 to 3 fail on a real regression (recommended); the live run only reports.
5. **The golden queries.** I draft about 25 from the catalog's categories and provinces and you read the list once (recommended), or you write them.
6. **Ranking changes.** A changed top card is **flagged for review** (recommended), not failed.

## 8. How we will know it works

- **K1:** the replay catches a deliberately broken check: I break one rule and the corpus run fails with the sentence that tripped it.
- **K2:** a place with a wrong category added to a fixture fails precision, and a query with no matches reports the shortfall reason instead of padding.
- **K3:** a suggestion set that repeats an answered detail is flagged.
- **K4:** two runs of the same commit give the same check counts within the model's own variation; a run after a deliberately worse prompt shows a check dropping.
- **Cost:** the whole offline part runs in seconds inside the normal suite, and the live run stays at 20 calls.
