# AI chat: stress test and fix plan

Status: plan only. No code has been changed and no test has been run. The backend guide requires your approval before code changes, and the stress run spends AI quota (see "Decisions").

## 1. What your 10 screenshots show

Each item says what I confirmed in the code or the live catalog, and what is still a guess.

| # | What you saw | Likely cause | Status |
|---|---|---|---|
| A1 | The AI asks "When are you planning to travel?" and offers grey chips "Tomorrow / Next weekend / This coming Friday". Tapping "Tomorrow" gives "I couldn't safely update your plan from that response". The app also draws its own chips for the same question ("This month / Nov / Dec"). Same pattern for activity ("Easy walking / Moderate trekking" next to the app's "Easy / Moderate / Challenging"). | Two sets of chips for one question. The app's chips send a structured answer (`answerChatDetail`). The model's chips are sent as plain text, and the model is not allowed to write `travel_start_date`, `activity_level` or `prefers_quiet` (the prompt forbids it), so its reply fails validation. | Code path confirmed. That the failure is exactly this validation is likely, not proven. |
| A2 | After "Just a day trip": "I could not use the return trip; please confirm that detail in the plan review." You never mentioned a return trip. | The model proposed `return_to_origin`, the server refuses unconfirmed values, and `_partial_planning_reply` prints that internal wording. | Confirmed in `service.py`. |
| A3 | Your start is Panabo, but the AI says Panabo City Parks and Plaza "takes 45 to 60 minutes from Davao City" and that you can go "by tricycle or a northbound bus along the Agusan-Davao highway for about ₱150". The card says about 2 minutes. | That is the commute route I added, which starts from Davao City. It reaches the model regardless of where the traveler starts, so the answer is right for someone in Davao City and wrong for you. | Likely. Needs a check of what is sent as context. |
| A4 | The text names Panabo Mangrove and Agriya, but the card shown is Huyong-huyong Nature Park. The chips say "Add Panabo Mangrove". Another reply names Monfort Bat Sanctuary, Museo Panabo and Sky Deck Cafe, with no card for any of them. | The prose is written by the model from retrieved records; the cards come from the server's ranking. Nothing forces them to agree. | Confirmed as a design gap. All the places named do exist in the catalog (ids 7, 19, 34, 42, 44, 46/47, 53), so the model is not inventing places. |
| A5 | "is there a place to go in panabo?" gets a text answer and a question back, with no cards. | The model labelled a browse request as a question, and a question gets no cards. The same weakness as the "add the museum" problem. | Likely. |
| A6 | Several cards show the same relief-map picture. | 22 of 63 catalog places have no photo, and the app shows a generic image. Also "Sky Deck Garden Cafe and Restaurant" is in the catalog twice (ids 46 and 47). | Confirmed in the live catalog. |
| A7 | "Agriya Naturetainment has an open entrance vibe" and "About ₱0 per person (catalog …" for Museo Panabo. | The first is invented wording for a place whose cost is not listed. The second is a catalog cost of 0.00 shown as a number instead of "Free" or "Not listed". | Likely. |
| A8 | After "Let's plan this trip" with 1 pick, the AI asks the date before people, days and budget. Later "Plan a trip with my pick" with 1 pick returns "5 itinerary options built from your picks". | The server sets a question order, but the model does not always follow it. Whether five options from one pick are meaningfully different is unknown. | Open. To be measured. |

## 2. Goal

For the normal flows a traveler takes (browse, pick, add, ask a question, plan), the AI should:
1. never show an error message the traveler did not cause;
2. only describe places the cards show (or the picks), with facts from the catalog;
3. use the traveler's own start place for times and fares;
4. say "not listed" when a fact is missing, never fill it in;
5. offer only replies that work when tapped.

## 3. The stress test

A script that holds many scripted conversations with the chat API and checks every reply with automatic rules. It extends the existing `services/api/tests/manual_chat_eval.py` and lives outside the normal test suite, because it calls the real model and costs quota.

**Scenarios (about 40), each repeated 3 times to see how often the model varies**
- Browse by category, by town ("a place to go in Panabo"), by vibe ("inspire me"), in English, Filipino, Bisaya and mixed (Taglish).
- Pick one, three or ten places, then add, remove and "any other".
- Trip details in every order, short answers ("Tomorrow", "600", "Easy"), and tapping every suggested chip.
- Different start places: Panabo, Davao City, Samal, Mati, a pinned location, none.
- Questions about fees, hours, how to get there, safety, weather.
- Bad input: negation ("I don't want Samal"), typos, places outside Davao, empty and very long messages, "ignore your rules" attempts, rude messages.
- Long chats (20 turns) to check memory and drift.

**Automatic checks (the "oracles")**
1. No fallback or internal wording in a benign flow ("couldn't safely update", "I could not use the …").
2. Every place named in the text is in the catalog and is either on a card or already picked.
3. Times and fares come from the traveler's start place; flag "from Davao City" when the start is elsewhere.
4. No invented money, hours or fees: every peso amount in the reply must appear in the supplied context.
5. Unknown stays unknown ("not listed"), never ₱0 unless the catalog says free.
6. Card rules hold: at most 5; at most 3 with picks; no picked place repeated; the category matches the request.
7. Every suggested reply, when sent, does not produce an error.
8. Question order follows the server's `ask_next`.
9. Language matches the traveler's language.
10. Reply is valid and fast enough (record the invalid-output rate and the time).

**Output:** a report with pass rates per check and the failing transcripts, so each failure can be turned into a regression test.

**Baseline thresholds (proposed)**
- Benign flows hit a fallback or internal message: at most 2%.
- Places named but not on the cards: 0 in at least 95% of runs.
- Wrong start place in times and fares: 0.
- Invented amounts: 0.
- Suggested replies that fail when tapped: 0.

## 4. Fixes, in priority order

Each fix gets a test that reproduces the screenshot case, and is checked again by the stress run.

| Priority | Fix | Touches |
|---|---|---|
| 1 | **One set of chips.** When the server's `ask_next` is activity, date or quiet, the AI returns no suggested replies and the app's structured chips are the only ones. As a backup, free text like "tomorrow" or "next weekend" is read by the server into a real date. | `ai/service.py`, prompts |
| 2 | **Friendly handling of refused details.** Drop an unconfirmed detail silently, keep the model's reply, and let the plan review ask for it. Never print "I could not use the return trip" unless the traveler gave it. | `ai/service.py` |
| 3 | **Start-place-aware answers.** Give the model commute routes only when they start where the traveler starts; otherwise say clearly "from Davao City". Put the traveler's start place and the server's travel time for each card in the context, and tell the model to use only those. | context building, prompts |
| 4 | **Text matches cards.** The server decides the places and writes a short caption per card from catalog facts; the model writes only the intro and tips. Chips like "Add Panabo Mangrove" come from the same list. | `ai/service.py`, prompts, app chips |
| 5 | **Browse detection.** A request for places in a town or of a kind ("a place to go in Panabo", "what's there to do") is treated as a browse on the server, whatever the model labelled it. | `ai/service.py` |
| 6 | **Honest cost and fee wording.** "Free (per catalog)" for 0.00, "Cost not listed" for none, and the AI may not describe entrance or hours it was not given. | app card text, prompts |
| 7 | **Photos and duplicates.** Add photos for the 22 places without one and remove the duplicate Sky Deck entry in the admin app (a data task for you). In the app, show a category icon instead of the shared relief-map picture. | admin data, app |
| 8 | **Question order and plan count.** Enforce `ask_next` order and check that five options from one pick are really different. | `ai/service.py`, itinerary code |

Fixes 1, 2, 3, 5 and 6 are small. Fix 4 is the biggest and changes how replies are written, so I'd do it last of the backend fixes.

## 5. Phases

| Phase | What | Needs |
|---|---|---|
| S0 | Check A3 and A1 in code and with one real call each; write the 10 screenshot cases down as test cases | your OK for a few live calls |
| S1 | Build the stress script and the checks | none |
| S2 | Baseline run, report | the run budget below |
| S3 | Fixes 1, 2, 3, 5, 6 with tests, then the full suite | your approval per backend change |
| S4 | Fix 4 and 8 | approval |
| S5 | Rerun the stress test, compare with the baseline, then a live check on the phone | deploy on Render |
| S6 | Data fixes (photos, duplicate) | you, in the admin app |

## 6. Decisions I need from you

1. **Run budget.** Each conversation turn is one AI call. 40 scenarios × 3 repeats × about 6 turns is roughly 700 calls per full run. The app has daily and per-minute limits for AI calls, so I'd run in batches and stop at a cap. Proposed cap: 300 calls for the baseline. Is that acceptable?
2. **Where to run it.** Recommended: a local API on this computer, reading the production catalog (read-only) and using the real model key from the local `.env`, so nothing touches your production users. The alternative is the live API with a dedicated test account, which means creating an account on production and needs your permission.
3. **How to judge replies.** Recommended: automatic rule checks only (cheap and repeatable). A second AI judging quality would add cost and its own errors; I'd leave it for later.
4. **Data fixes.** Will you add the missing photos and remove the duplicate Sky Deck entry in the admin app, or should I only report them?
