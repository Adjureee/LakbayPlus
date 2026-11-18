# Claims-without-numbers: baseline (18 Nov 2026)

Step 1 of `AI_CLAIMS_CHECK_PLAN.md`. Measurement only: no product behaviour changed. Tool: `services/api/tests/claims_baseline.py`.

## How it was measured

- **Replies:** the deployed guest chat (commit e93c5c1) was asked four place-specific questions per place ("Is X wheelchair accessible?", "What can I do at X?", "Tell me about X.", "Is there parking at X?"). Places were drawn from sparse, middling and rich records.
- **Judge:** Gemini (the fallback provider), a different model family from the Groq chat model, labeled each sentence **supported**, **unsupported** or **generic** against the place's public record plus its room and transport rates. The judge is a measuring tool only and is never used at runtime.
- **My check of the judge:** I read every flagged sentence and a random sample of supported ones.

## Size, and why it is smaller than planned

26 replies, 9 places, 73 sentences. The plan aimed for about 200 sentences. The guest endpoint has a **daily limit per IP**, and the earlier live checks plus this collection used it up (it now answers 429 for about 23 hours). The numbers below are a first estimate, not the final baseline the plan's thresholds call for. The collector resumes where it stopped, so the rest can be added after the limit resets or by running it against a signed-in chat.

## Results

| | Count |
|---|---|
| Replies with at least one unsupported sentence | **13 of 26 (50%)** |
| Sentences: supported / generic / unsupported | 25 / 29 / 19 |

Unsupported sentences by category:

| Category | Count | Typical case |
|---|---|---|
| Conditions | 9 | "go early to avoid crowds", "dry season (Nov-May)", "weather's cooler", "uneven path" |
| Facilities | 4 | "street parking is usually available nearby, but it can fill up on weekends" |
| Accessibility detail | 2 | "terrain can be uneven"; "ramps, restroom access" |
| Activities | 1 | "guided tours, workshops or cultural performances" at a museum whose record lists only exhibits |
| Access | 1 | a bus fare and journey time |
| Rules | 1 | "pay any meter fees" |
| Numbers | 1 | "room rates start at 5,000 per night" |

## How far to trust the judge

From my reading of all 19 flagged sentences:

- **About 13 are clearly unsupported** (invented terrain, parking, tours, meter fees, "dry season Nov-May", card terminals).
- **About 4 are marginal**: general tips that imply a crowd or weather condition ("go early to avoid crowds").
- **About 2 are doubtful**: the room rate and the Aliwagwag bus fare may be in the rate records the judge saw. Judge precision is roughly **70 to 85%**.
- **Misses:** in a random sample of 14 supported sentences, 1 or 2 looked embellished ("sprawling 5-star luxury layout", "cool morning air" at 6:30 to 8:00 AM) and may be unsupported too, so the judge also misses some. Recall is probably around 80 to 90%, untested.

Two judge errors were found and fixed before this run: it did not see the rate records (so it flagged recorded fares), and it flagged honest "not recorded" statements as claims. Both fixes are in the script.

## What this says about the check

1. **About half of place-specific answers about thin records carry at least one invented detail.** The check is needed, and "conditions" and "facilities" are the first categories to enforce, as the plan proposed.
2. **"Hedge, then speculate"** appears repeatedly: "Parking isn't listed ..., so you'll need to check with the parish, many local churches have a small lot or street parking." The first half is honest and the second half invents. The check must catch hedging words ("likely", "probably", "usually", "many ... have"), not only plain assertions.
3. **Seasonal and crowd tips are the largest category (9 of 19).** Whether "go early to avoid crowds" counts as a place claim or a generic tip is plan decision 3. Counting it would drop a lot of harmless advice; not counting it leaves the most frequent invention in place. A middle path: enforce on **specific** conditions (named months, "uneven path", "card terminals") and leave plain "go early" advice alone.
4. **Honest absence statements must stay.** "Parking isn't listed" is the behaviour we want; the check must never remove it.

## Next

- Add the missing places once the guest limit resets (or against a signed-in chat), to reach about 200 sentences, then re-measure.
- Plan step 2 (lexicon, log-only check, tests) after your answers to decisions 1, 2, 3 and 5 in the plan.

## Step 2: the runtime check replayed on this sample (18 Nov 2026)

`services/api/app/features/ai/claims.py` is the deterministic check from the plan, shipped in **log-only** mode (`CLAIMS_CHECK_MODE=log`, the default; `off` and `enforce` also exist). `python tests/claims_baseline.py replay` runs it over the judged replies with no model calls.

| Measure | Result |
|---|---|
| Sentences the judge called unsupported | 19 |
| Caught by the check | 12 |
| Missed | 7 |
| Other sentences wrongly flagged | **0 of 54** |

The 7 misses are the ones the plan chose to leave alone or that are doubtful, not gaps in the lexicon: three plain crowd or weather tips ("go early to avoid crowds", "weather's cooler", "indoor space can get warm"), "arrive early, especially on Sundays", "call the resort to ask about ramps" (advice, not a claim), and the room rate and bus fare that may be in the rate records. Of the claims the plan puts in scope (terrain, parking and other facilities, rules, named activities, specific seasons, and a guess after "not recorded"), the check caught all 12 in this sample. The target of 80% caught and at most 3% wrongly flagged is met here, on 73 sentences, which is too few to be sure: it must be re-measured on the full sample after the guest chat limit resets.

Two bugs found while replaying, now fixed and covered by tests: the "ask the operator" guard hid a guess in the same sentence ("... check with the parish, many churches have a small lot"), and non-breaking hyphens ("air-conditioned") slipped past the patterns.

## Before switching to enforce (19 Nov 2026)

A bigger sample (58 live replies, 19 places, 156 sentences) was judged with the full records the chat sees (the transport records' vehicle type had been missing from the judge's and the replay's view, which made some supported bus fares look invented; fixed in `tests/claims_baseline.py`).

| Measure | Result |
|---|---|
| Replies with at least one unsupported sentence | 25 of 58 (43%) |
| Sentences the judge called unsupported | 33 |
| Caught by the check | 16 (48%) |
| Other sentences wrongly flagged | **0 of 123** |

The 17 misses are mostly the ones left alone on purpose: plain tips (crowds, weather, sunscreen, "bring a raincoat"), advice to ask the operator, open-ended details a word list cannot name ("learn about human and animal anatomy"), and route or price figures that belong to the figure check. By my own count about 80% of the claims in the categories the check covers were caught; that count is a judgement, not a measurement.

Previewing enforcement on all 58 replies (16 would change) found three results that read badly, now fixed and covered by tests:
- a dependent clause left as a fragment ("Because it's a highland spot.") is now dropped whole;
- a guess after "not recorded" removed the whole sentence, leaving the question unanswered; it is now cut back to the honest clause ("Parking isn't mentioned for Aliwagwag Falls.");
- one invented list item dropped a good sentence; list items holding the claim are now removed and the rest kept, and a ", so you can enjoy its wide paths" or ", which includes ..." clause is cut while the answer ("Yes, ... is wheelchair accessible.") stays.

Two defects of the check itself were also found: a place named only with common words ("People's Park") was never recognised in a sentence, so its sentences were never checked (fixed in `mentioned_place_ids`, which also improves the figure check), and a "but" before the absence ("listed as family friendly, but accessibility is not specified") was wrongly treated as an assertion.

To enforce: set `CLAIMS_CHECK_MODE=enforce` in the Render environment (no deploy needed beyond the restart). To go back, set it to `log`.
