# AI chat stress test: baseline (17 Nov 2026)

Run with `services/api/tests/stress_chat.py`: 21 scripted conversations, each run 3 times, plus one tap of the first suggested reply per scenario. 137 AI calls (cap 296), 120 answers scored. The catalog was a snapshot of the production data (63 places, 14 accommodation rates, 12 transport rates) in a local database; the production database was not touched. Route times were calculated from straight-line distance, not the live routing service.

## Read this first

- **Every scored answer came from the fallback model (Gemini 3.5 Flash Lite), not Groq.** Groq's daily quota was used up (one call returned "Groq rate limit reached, retry in 2750 seconds"). So this baseline describes how the app behaves **when Groq is unavailable**. How the Groq model behaves is not measured. Run again after the quota resets to compare.
- **My first checks had false alarms,** which I fixed in the script after the run. The counts below show the raw result and the corrected one.
- A rule check finds problems; it does not prove quality. Replies that passed every check can still be mediocre.

## Results by check

| Check | Raw | Corrected | Notes |
|---|---|---|---|
| No internal or error wording in the reply | 102 / 119 | same | 14% of answers showed "I couldn't safely update your plan from that response" |
| The model's output was usable | 105 / 120 | same | 15 unusable outputs, 12.5% |
| Text names only places on the cards or picked | 31 / 43 | same | 28% fail: the text names places the cards don't show |
| No "from Davao City" when the start is elsewhere | 39 / 42 | same | 3 failures, all with a Panabo start |
| Reply in the traveler's language | 114 / 119 | same | 5 English chats answered in Cebuano |
| Peso amounts come from the data | 26 / 32 | 31 / 32 | 5 "failures" were fees in the places' own fee text. The 1 real one is the AI's own subtraction ("leaving you with around ₱700") |
| Clock times match the place's record | 7 / 8 | 8 / 8 | The record said "06:00-17:00" and the AI said "6:00 AM to 5:00 PM", which is correct |
| A place with no listed cost is never called free | 49 / 49 | same | |
| At most 5 cards (3 after picks), none repeated | 43 / 43 | same | |
| Cards match the kind of place asked for | 6 / 6 | same | |
| Cards avoid places the traveler ruled out | 3 / 3 | same | |
| An explicit add puts the place in the plan | 3 / 3 | same | |
| Saved details hold the values just given | 6 / 6 | same | |
| No key or prompt text leaked | 119 / 119 | same | |
| A place outside the Davao Region is called outside | 0 / 3 | 2 / 3 | One answer ignored Boracay, one was an error |
| A request for places in a town shows cards | 1 / 3 | same | "is there a place to go in panabo?" got a text answer in 2 of 3 runs |
| Small talk and nonsense get no cards | 14 / 15 | same | "thanks!" in a long chat got cards |
| Answered within 25 seconds | 115 / 119 | same | Median 3.8 s, slowest 38 s |
| A tapped suggested reply works | 15 / 17 | same | 2 taps ended in the error message |

## What is solid

Card limits, ruled-out places, category matching, explicit adds, saved values, no leaked prompts, and not calling unlisted prices "free" all passed every time. Prices and hours the AI quoted matched the records.

## Real problems, in order of how often they happen

1. **Unusable model output shows a scary error (14% of answers).** It happened on the injection test, "I don't want Samal", gibberish, "Just a day trip", a long chat, and two tapped suggested replies. In one case the error even came with "I added Museo Panabo to your plan." after the traveler only asked what time it opens. **Fix:** when the output is not usable JSON but is plain text, show the text; never add a place from a question.
2. **The text and the cards disagree (28% of answers with cards).** The text names Dahican Surf Resort or the Samal beach area while the cards show other places. **Fix 4** in the plan.
3. **"Where to go in Panabo" gets no cards (2 of 3 runs).** The model calls it a question. **Fix 5.**
4. **English chats answered in Cebuano (5 answers).** Greetings like "Maayongo!" and whole replies in Cebuano, with the chats' language set to English. **Fix:** a stricter language rule, and a server check that retries once.
5. **Wrong start place (3 answers).** "takes about 45 to 60 minutes from Davao City" and "completely free to enter" for Panabo City Parks and Plaza, which has a listed cost of ₱150. **Fix 3.**
6. **Slow answers (4 over 25 s).** Likely the Groq error followed by the fallback model.
7. **Derived budget arithmetic ("leaving you with around ₱700").** The remaining budget is stated without knowing the other costs. This is the rule in your specification (B7).

## Already fixed from the screenshots (not in this baseline)

- The model's date chips ("Tomorrow", "Next weekend") next to the app's own buttons, and the "I could not use the return trip" message after "Just a day trip". Fixed on `feature/ai-phase1-conversation` after this run, with tests. The baseline was run before those fixes, so its numbers for them are the "before".

## Next run

After the quota resets: run again with the same scenarios (same script, 3 repeats) to compare with this baseline, and see whether Groq behaves differently from the fallback model.

## After the second batch of fixes (same day)

A targeted re-run of the scenarios that failed, with the same script and the same fallback model: 7 scenarios x 2 repeats = 32 answers, then a 3-scenario, 8-answer check of the two stubborn cases. Small samples, so read them as direction, not as a new baseline.

| Check | Baseline (those scenarios) | After |
|---|---|---|
| English chat answered in English | 5 wrong-language answers | 32 / 32 correct |
| Error wording shown to the traveler | 14% of all answers | 2 of 32, then 0 of 8 after the last fix |
| A question about a place adds it | "I added Museo Panabo to your plan." | Never; the answer was given and nothing was added |
| Reply invented text or amounts | none found | none found (8 / 8 amounts, 3 / 3 hours) |

What changed: the model's plain text is shown when its JSON is unusable (never if it claims something was saved, and never from valid JSON that broke a rule); a misspelt key such as `chat__response` (the fallback model did this twice) no longer throws the answer away; a question never adds a place; and the prompt now says an English message gets an English reply with no Bisaya greetings.

Still open from the baseline: the text names places the cards do not show (4 of 10 clean in the re-run, so still failing), "where to go in Panabo" showing no cards, "from Davao City" times for a Panabo start, and slow answers while Groq is rate limited. One of the 32 answers came from `openai/gpt-oss-120b` (Groq), so part of the quota is back; the full Groq comparison is still to do.

## After the third batch of fixes (same day, commit `bfc8e41`)

Re-run of the affected scenarios (6 scenarios x 2 repeats = 20 answers, same script, fallback model; small sample, direction only).

| Check | Baseline | After |
|---|---|---|
| Text names only places on the cards or picked | 31 / 43 (28% failing) | **10 / 10** |
| No "from Davao City" when the start is elsewhere | 39 / 42 | **10 / 10** |
| A request for places in a town shows cards | 1 / 3 | **2 / 2** |
| Reply in the traveler's language | 114 / 119 | **20 / 20** |
| An explicit add puts the place in the plan | 3 / 3 | 2 / 2 |
| Error wording shown to the traveler | 17 / 119 | 1 / 20 (a reply the server could not use at all) |

What changed: a request for places in a town ("is there a place to go in panabo?") is shown as that town's places, whatever the model called it, with duplicate catalog entries listed once; a sentence that names a place that is not on a card is removed from the text; a sentence giving a route "from Davao City" is removed when the traveler starts somewhere else; and the prompt now tells the model the traveler's start place and marks each transport record with whether it starts there.

### A new finding: invented specifics

For "How do I get to Dahican Surf Resort?" (start Mati) the model wrote a route time, a distance, a tricycle fare, parking, road condition and a best surf time. The catalog record has only "24/7" for hours and nothing about the route. The prices and hours checks did not catch most of this, because the numbers appear elsewhere in the catalog. This is the rule in your specification (B5): do not invent destination-specific prices, routes, travel times or schedules. The prompt already says so; the fallback model does not follow it reliably.

Next fix: check every distance, time and amount in a reply against the facts supplied for that reply, and remove or restate sentences with figures the data does not support. Needs your go-ahead before I change how replies are checked.

## After the fourth batch of fixes (same day, branch `feature/ai-phase1c-grounding-polish`)

Re-run of the affected scenarios (5 scenarios x 2 repeats = 14 answers, same script, fallback model; small sample, direction only). Every check passed: no error wording, text names only places on the cards, no "from Davao City" for a Panabo start, peso amounts all supported.

What changed:
- **No hanging sentences.** A sentence that leans on a removed one ("It takes ...", "If you rent a car, the drive is similar") is removed with it.
- **Figures belong to the place named.** A sentence about one place may only use that place's own records, plus the traveler's own words and plan. "Outdoor trails about 1.5 to 2 hours away" is no longer kept just because the numbers appear in some other place's record.
- **Counts agree with the cards.** "We have 3 nature parks" beside five cards is removed.
- **No bland fallback.** When nothing useful is left, the text is built from the cards: "Here are 5 places that match what you asked for: Museo Panabo, Panabo City Parks and Plaza, ...".

Examples from the run:
- "How do I get to Dahican Surf Resort?" from Mati: "I don't have confirmed times, distances or prices for that in Lakbay's records, so I won't guess."
- "is there a place to go in panabo?": five Panabo cards and a caption naming them.
- "Are there entrance fees?": the recorded fees (30 and 15 for Huyong-huyong, 100 plus 5 for Monfort), and the unlisted ones are said to need confirming.

Still not covered: claims without numbers ("bring cash for parking", "the road is paved") and replies that are honest but thin when the catalog has little to say.

## Live check of phase 1c on the deployed API (17 Nov 2026, commit `ba474e9`)

Run through the public guest chat, single runs, Gemini 3.5 Flash Lite. (An earlier attempt hit a deploy that was still on the previous commit: the caption had no place names. After the redeploy the new behaviour showed.)

| Case | Result |
|---|---|
| "show me beach resorts" | Caption built from the cards: "Here are 4 places that match what you asked for: Chema's by the Sea, Isla Reta Beach Resort, Banana Beach at Hijo Resorts Davao and Lanikai Hijo Estate Resort." |
| "Show me nature parks" (start Panabo) | "We have 3 nature parks listed ..." beside exactly 3 cards: the count agrees |
| "How do I get to Dahican Surf Resort?" (start Mati) | No route figures; the reply ends with the "I left out some times, distances and prices" note, with one tip and a follow-up question. Honest, thin |
| "is there a place to go in panabo?" (start Panabo) | Five Panabo cards, but the text kept "taking about 45 to 60 minutes and costing around ₱150 if traveling from nearby Davao City" |

### New weak spot

The Panabo sentence slipped past the start-place rule because it says "from **nearby** Davao City", and the rule only matches "from Davao City". The figures themselves are the place's own recorded ones (₱150, 45 to 60 minutes) and the sentence says they are from Davao City, so it is not wrong, but it is about the wrong starting place for a traveler in Panabo. Proposed: let the rule match up to two words between "from" and "Davao City".
