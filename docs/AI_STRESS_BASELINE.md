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
