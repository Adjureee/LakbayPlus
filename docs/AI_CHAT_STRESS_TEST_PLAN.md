# AI chat: target specification, stress test and fix plan

Status: plan only. No code has been changed and no test has been run.

This document has three parts. **Part A** is what your phone screenshots showed, the stress test and the first fixes. **Part B** is your target specification for the assistant, kept as written. **Part C** maps Part B to what the app does today and merges the phases. The backend guide requires your approval before code changes, and the stress run spends AI quota (see "Decisions").

# Part A. Anomalies, stress test and first fixes

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


---

# Part B. Target specification: Lakbay+ AI travel assistant

This is the specification you supplied, kept as written (formatted as headings and lists). Part C below maps it to what the app does today and to the fixes above.

## Objective

Improve Lakbay+ so users can naturally describe their travel preferences, receive five relevant place recommendations within their chosen destination area, select the places they want to visit, and receive a detailed, personalised, and realistic itinerary.

The assistant must remain helpful when the dataset is incomplete while clearly distinguishing supported information, estimates, and unknown details.

Inspect the existing codebase, database, preference management, recommendation retrieval, and itinerary generation before making changes. Use the existing architecture where practical.

## B1. User journey

Implement this flow:

Collect initial preferences → Recommend five matching places → User selects places → Collect remaining planning details → Review trip summary → Generate and validate itinerary → Allow revisions.

Do not require users to answer every planning question before seeing places. Collect the destination area and interests first, then ask for additional information when it becomes necessary.

If the user already provides sufficient details, proceed without repeating questions or requiring unnecessary confirmation.

## B2. Preference collection and memory

Maintain structured trip state containing:

- Chosen destination area
- Whether nearby areas are allowed
- Starting location and return location
- Travel date and number of days
- Departure time and return deadline
- Number of adults and children
- Child ages when needed for pricing or activity eligibility
- Budget and currency
- Whether the budget is per person or for the whole group
- Expenses included in the budget
- Transportation mode
- Interests and preferred activities
- Activity intensity and preferred pace
- Relevant accessibility or dietary needs, when provided
- Selected destination IDs

Ask one focused question at a time, or two closely related questions. Support both typed answers and suggested reply buttons.

Interpret short answers using the current question and conversation context:

- "Just me" → one traveller.
- "600" → PHP 600 when answering a budget question in pesos.
- "Easy" → low-intensity activities when answering that question.
- "Day trip" → one day without overnight accommodation.
- "Tomorrow" → resolve using the current Asia/Manila date.
- "This month" → a date range; request a specific date when necessary.
- "Make it 1000 instead" → update the budget when the context is clear.

Do not infer unsupported details. A day trip does not establish an exact return time or return location.

Update only the affected fields and preserve all other accepted preferences. Clarify ambiguous answers when their interpretation materially affects the plan.

Only confirm an update after it has been saved successfully.

## B3. Five personalised place recommendations

Recommend five distinct places within the user's chosen destination area when sufficient suitable records exist.

Rank recommendations using available information about:

- Interests and desired activities
- Budget and cost coverage
- Starting location and transportation
- Available travel time
- Activity intensity and pace
- Traveller composition
- Relevant accessibility needs
- Operating status and availability on the travel date, when known

Treat required user constraints as filters where the data supports them. Do not describe a place as meeting a constraint that cannot be verified.

For each recommended place, display:

- Destination name and location
- Correct destination image, or a placeholder
- Supported activities
- Brief explanation of why it matches the user's preferences
- Suggested visit duration, labelled as an estimate when appropriate
- Recommended visiting time and its basis, when available
- Known fees and relevant pricing conditions
- Important unknown details
- View details and add/remove controls

Keep recommendation cards concise and put additional information in the details view.

Use canonical destination IDs so recommendation text, cards, images, selections, and itinerary stops refer to the same records.

Five recommendations are five candidate places, not five itinerary options. The user chooses which places to include.

Do not automatically add a place because it was recommended. Do not assume all five places can fit in one trip.

If fewer than five suitable places are available:

- Show the suitable places available.
- Explain the limitation briefly.
- Offer to broaden preferences or include nearby areas.
- Obtain the user's agreement before expanding the area.
- Never invent or duplicate places to reach five.

When preferences change, refresh recommendations while preserving selected places. Flag selections that no longer match and let the user decide whether to keep them.

## B4. Destination and activity data

Use destination records that support, where available:

- Canonical ID, name, description, and geographic area
- Coordinates and access information
- Operating status
- Opening hours by day and date-specific exceptions
- Entrance fees and adult/child pricing policies
- Correct destination images
- Transportation access and parking
- Booking requirements
- Source and last-verified date

Store activity-level information separately where practical:

- Activity name and description
- Availability, scheduled sessions, and last admission
- Typical duration
- Additional fees and whether they are already included in admission
- Effort level and relevant accessibility information
- Age or participation restrictions
- Weather dependencies
- Recommended visiting time and supporting reason

A destination being open does not establish that every activity is available.

## B5. Handling incomplete data

Use retrieved records and successful tool results for factual claims about local fees, operating hours, activities, transport, and availability.

Distinguish:

- Supported facts: information backed by an identified source.
- Estimates: values with an identifiable calculation or planning basis.
- Unknown information: details without sufficient evidence.

Preserve source and verification dates where available. Do not describe old information as currently verified.

Never interpret:

- A missing entrance fee as free admission.
- Missing hours as unrestricted access.
- A missing operating status as proof that a place is open.
- Missing activity details as proof that an activity exists.
- Unknown accessibility as confirmed suitability.

Do not invent destination-specific prices, routes, transport services, travel times, activity schedules, or booking availability.

Planning allowances may be used when clearly identified. For example, a user-approved meal allowance is not a verified restaurant price.

When important data is missing:

- Explain what is unknown and how it affects the decision.
- Ask a targeted question when the user can supply useful information.
- Offer a provisional plan or supported alternative.
- Avoid blocking the whole conversation over nonessential missing details.
- Do not guarantee budget or schedule feasibility.

Only claim current verification when an actual successful lookup occurred. If no verification capability is available, state that the detail remains unconfirmed.

## B6. Detailed itinerary generation

Before generating, show a compact review containing:

- Destination area and selected places
- Date and trip duration
- Travellers
- Starting and return locations
- Departure time and return deadline
- Transportation
- Budget scope
- Interests, pace, and relevant needs
- Material assumptions or missing details

Allow corrections without restarting the conversation.

Generate a day-by-day timeline from the user's selected places.

Include:

- Start and end time for each itinerary item
- Destination and specific supported activity
- Allocated visit or activity duration
- Travel from the previous stop
- Transportation mode and supported travel estimates
- Meals, rest breaks, and reasonable buffers
- Admission and activity costs
- Transport and meal expenses where available
- Booking requirements and relevant restrictions
- Return journey and expected arrival time

Distinguish confirmed activity schedules from provisional planning times.

Explain recommended timing using:

- Known activity sessions or access restrictions
- Opening hours and last admission
- Available weather or environmental information
- Clearly labelled general advice
- User preferences
- Route efficiency and time constraints

Do not invent precise "best time" claims.

Do not invent travel times to make a schedule appear complete. If routing information is missing, identify the affected travel legs and label the schedule as provisional.

Preserve selected places. If they cannot fit, explain the conflict and ask whether the user wants to prioritise places, change the time window, or revise another constraint.

Do not silently remove selected places or add new destinations. Optional alternatives must be clearly identified.

## B7. Budget presentation

Calculate expenses according to group size and pricing rules.

Separate:

- Known costs
- Estimated expenses and their basis
- Unknown expenses
- Known or estimated subtotal
- Remaining budget based on that subtotal

Prevent double-counting fees included in packages or admission. Distinguish per-person charges from shared group expenses.

Only describe a trip as within budget when essential expenses are adequately covered by available information.

If costs are incomplete, explain that the subtotal is not the full trip cost.

## B8. Application-level validation

Do not rely solely on the language model to check its own output.

Implement deterministic checks for:

- Valid local dates
- Chronological ordering and schedule overlaps
- Valid destination IDs
- Selected-place consistency
- Geographic scope
- Budget arithmetic
- Traveller counts and pricing units
- Required itinerary fields

Where supporting data exists, also validate:

- Travel time between stops
- Opening hours and activity sessions
- Visit durations and travel buffers
- Return deadline
- Activity suitability and restrictions

Classify each relevant check as:

- Passed
- Failed
- Cannot verify

Missing information must not count as a passed check.

Resolve failed constraints before describing the itinerary as feasible. For checks that cannot be verified, identify the unresolved issue in plain language.

## B9. Response style and error recovery

Use friendly, clear, concise language. Answer the immediate question before asking the next relevant question. Keep factual uncertainty specific and avoid repeating generic disclaimers.

Avoid vague wording such as "open entrance vibe." Say "The entrance fee is unconfirmed" when that is the actual situation.

Suggested reply buttons must be supported by the application's input handling.

If an update fails:

- Identify what could not be saved.
- Preserve previously accepted preferences.
- Provide a working retry or editing option.
- Do not blame a valid user answer for an internal failure.

Never claim that a place was added, a preference was saved, or an itinerary was generated unless the application confirms success.

## B10. Implementation priorities (as specified)

**Phase 1: Reliable conversation and selection**
- Fix short-answer interpretation and date handling.
- Store preferences consistently.
- Support corrections and failed-update recovery.
- Align destination text, cards, images, and selections.

**Phase 2: Recommendations and data handling**
- Implement five-place retrieval and ranking.
- Add activity-level fields where practical.
- Track supported, estimated, and unknown information.
- Handle insufficient matching records honestly.

**Phase 3: Itinerary generation and validation**
- Generate structured timeline items.
- Add cost calculations and schedule checks.
- Handle conflicts and incomplete information.
- Support revisions without losing accepted choices.

**Phase 4: Presentation**
- Render the structured itinerary as a readable day-by-day timeline.
- Provide expandable activity, travel, cost, and uncertainty details.
- Use correct destination images.
- Add export functionality if included in project scope.

Prioritise reliable behaviour and information consistency before visual polish.

## B11. Acceptance tests

Verify that the system can:

- Process "Tomorrow," "Day trip," "600," and "Easy" correctly in context.
- Apply a correction without resetting unrelated preferences.
- Recommend five distinct matching places when suitable data exists.
- Return fewer than five honestly when records are insufficient.
- Keep text, cards, images, selections, and itinerary stops consistent.
- Preserve selections when recommendations refresh.
- Handle missing prices, hours, transport, and activity information.
- Explain time or budget conflicts without silently changing the trip.
- Calculate individual and shared costs correctly.
- Preserve saved preferences when an update fails.
- Generate a detailed timeline with supported activities and clear assumptions.

Use example conversations as regression tests and prompt examples. Start with prompt improvements, retrieval, structured state, and validation. Consider fine-tuning only if evaluation reveals persistent response problems that those measures do not resolve.

## Deliverables

- Implemented changes
- Updated data structures and required configuration
- Focused test results
- Remaining dataset limitations
- Any external integrations still required

## Success criterion

A user can describe preferences naturally, receive up to five relevant place recommendations, select preferred places, and obtain a detailed itinerary that respects those choices, checks practical constraints, and clearly identifies information that remains unconfirmed.


---

# Part C. How the specification maps to the app today

"Today" below comes from the code I read (`planning/schemas.py`, `destinations/models.py`, `ai/service.py`, `conversation_stage.py`, the chat screen) and from your screenshots. Items marked **to audit** I have not read yet; step S0 settles them.

## C1. Gap map

| Spec | What exists today | Gap | Where it is handled |
|---|---|---|---|
| **B1** Journey: collect, recommend five, pick, details, review, generate, revise | The server tracks three stages (collect, recommend, picking) and shows cards as soon as an interest is known. | The model sometimes asks details in the wrong order (date before people, days and budget). The "review trip summary" step is **to audit**. | Fix 8 (question order); S0 audit |
| **B2** Trip state | `PlanningState` has origin, destination ids, budget and scope, traveler, adult and child counts, child ages, days and nights, return flag, interests, activity level, start date, quiet preference, priority order, transport and activity picks, cost allowances, age-based pricing. | Missing: destination **area** and "nearby allowed", return **location** (only a yes/no flag), departure time, return deadline, pace, accessibility and dietary needs, which expenses the budget includes. | New Phase 1 state fields (needs your approval; stored in the existing state object, no new table) |
| **B2** Short answers ("Tomorrow", "600", "Easy", "Day trip", "This month", "Make it 1000 instead") | The app's own chips send structured answers for activity, date and quiet. The model's chips are sent as text and fail ("Tomorrow"). "Just a day trip" produces a refused-detail message. | Dates are not resolved from words using the Asia/Manila date; corrections like "make it 1000" and range answers like "this month" are untested. | Fixes 1 and 2; new date and amount parser on the server |
| **B2** "Only confirm an update after it has been saved" | The add-by-name path now writes its own confirmation. Other replies still use the model's wording. | Confirmation text for budget, days and other updates comes from the model. | Fix 4 (server writes confirmations) |
| **B3** Five distinct places, ranked, with reasons | `MAX_SUGGESTIONS = 5`; the ranking uses interests, budget, travel time and activity level; near matches are labelled; fewer-than-five shows a reason. | Cards lack supported activities, visit duration, recommended visit time with its basis, and "important unknowns". The "broaden or include nearby areas, with the traveler's agreement" step does not exist. Refreshing after a preference change keeping picks, and flagging picks that no longer match, is **to audit**. | Fix 4 and a new Phase 2 card model |
| **B3** Text, cards, images, picks refer to the same records | Not guaranteed (screenshots A4, A6). | Prose names places that are not on the cards; 22 of 63 places have no photo; "Sky Deck Garden Cafe and Restaurant" is in the catalog twice. | Fix 4, Fix 7 |
| **B3** "Five recommendations are not five itinerary options" | The app shows "Here are 5 itinerary options built from your picks" after "Plan a trip with my pick." | This is a **decision for you** (see C3): the spec treats five as places, but the app also offers five generated itineraries. | Decision 1 below |
| **B4** Destination data | A destination has name, description, district, coordinates, a verified arrival point with source and date, free-text `entrance_fee`, `estimated_cost`, `operating_hours` (one text field, 255 characters), `best_time_to_visit`, `activities` (free text), difficulty, kid, wheelchair, pet and elderly flags, an image with credit and licence. | No structured opening hours by day or exceptions, no adult and child price policy per place, **no last-verified date or source for fees and hours** (only for the arrival point), no booking requirement field, no separate activity records. The accessibility flags default to false, so "unknown" and "not accessible" look the same. | New Phase 2 data work; needs migrations (approval) and admin app forms |
| **B5** Supported, estimated, unknown | The app already says "Cost not listed" and keeps "unknown stays unknown" as a rule. | The three labels are not a field on the data; the model decides the wording ("open entrance vibe"; "₱0 per person"). Missing hours and fees can still be described loosely. | Fix 6; Phase 2 tri-state fields |
| **B6** Itinerary timeline with start and end times, travel legs, meals, buffers, costs, booking notes, return time | **Audited.** An itinerary activity has one free-text `time` (up to 20 characters), a title, a description, optional destination, accommodation and transport ids, an estimated cost (always labelled `ai_draft_estimate`) and notes. A day has a title, a summary and a list of activities. | No start and end time, no duration, no travel leg from the previous stop, no meal or rest slots, no buffers, no booking notes, no return leg or arrival time. The traveler cannot be told which times are confirmed and which are provisional. | Phase 3: new timeline item schema |
| **B7** Budget: known, estimated, unknown, subtotal, remaining; per-person vs shared | **Audited.** `planning/costs.py` is close to the spec. It records missing prices as "missing" with a reason, only gives a total when the picture is complete (`total_estimate` is empty otherwise), keeps a `priced_subtotal`, labels traveler allowances as "not a verified catalog fee", and handles per-person versus whole-trip scope and age-based prices. | Two gaps. (1) The itinerary generator does not use this: its validator **requires** the option total to be within the budget and equal to the sum of activity costs, which pushes the model to put costs on every item whether or not any are known. (2) The "remaining budget" wording and "within budget only when essential costs are covered" are not applied to the chat or itinerary text. | Phase 3: feed the itinerary from `costs.py`, and let unknown costs stay unknown |
| **B8** Deterministic checks, tri-state (passed, failed, cannot verify) | **Audited.** The itinerary validator (`ai/validators.py`) checks the day count and numbers, that the total is within the budget and equals the sum of the costs, that destination, accommodation and transport ids exist and belong together, that every selected id is used, and that stops follow the calculated route order. A failed check raises an error and the model is asked again. | It is pass or fail only: there is no "cannot verify". It does **not** check chronological order or overlaps (the time is free text), opening hours, last admission, visit durations, travel buffers, return deadline or activity suitability, because the data for them is not stored. | Phase 3 checks; Phase 2 data |
| **B9** Style; buttons the app can handle; failed-update recovery | Prompt v13 has examples; the app has its own chips. | Model chips that fail; internal wording after a refused detail; no retry or edit option after a failed update. | Fixes 1, 2; app change for retry |
| **B11** Acceptance tests | 916 backend tests and 281 app tests, plus the planned stress run. | The 11 acceptance cases are not written as tests yet. | Added to the stress scenarios (C2) |

## C2. How the stress test covers the specification

Each acceptance case in B11 becomes a stress scenario with an automatic check, run three times each:

1. "Tomorrow", "Day trip", "600", "Easy" in context → the saved state has the right date, a day count of one with no invented return time, PHP 600, and an easy activity level.
2. A correction ("make it 1000 instead") → only the budget changes; every other field is unchanged.
3. Five distinct places when the catalog has enough; fewer, with a reason and an offer to broaden, when it does not; never a duplicate.
4. Text, cards, images, picks and itinerary stops name the same records.
5. Picks survive a refresh; ones that no longer match are flagged, not removed.
6. Missing price, hours, transport and activity data are reported as unknown, never as free, open, or available.
7. A conflict (time or budget) is explained and nothing is silently dropped.
8. Individual and shared costs add up (arithmetic checked in code, not by the model).
9. A failed update keeps the saved preferences and offers a retry.
10. An itinerary has times, travel legs and labelled assumptions.

## C3. Phases (specification phases mapped to the earlier plan)

| Specification phase | Work from this plan | Needs |
|---|---|---|
| **Phase 1.** Reliable conversation and selection | S0 audit, S1 stress script, S2 baseline, then Fixes 1, 2, 3, 4, 5 and 8; new date and amount parser; new state fields (area, return deadline, pace); retry option after a failed update | approval per backend change |
| **Phase 2.** Recommendations and data handling | Richer cards (activities, visit duration, visit time with its basis, unknowns); supported, estimated or unknown labels on the data; last-verified date and source for fees and hours; structured opening hours; separate activity records; "broaden to nearby areas" step; refresh that keeps picks | **database migrations (approval)**, admin app forms, data entry by you |
| **Phase 3.** Itinerary and validation | Timeline items with times and travel legs; budget split into known, estimated, unknown; tri-state checks; conflict handling that keeps the traveler's picks | approval; may reuse the existing itinerary generator |
| **Phase 4.** Presentation | Day-by-day timeline in the app with expandable details; correct photos or category placeholders; export if in scope | app work; photos from you |

Fine-tuning stays out of scope until the stress results show problems that prompts, retrieval, structured state and validation cannot fix, as the specification says.

## C4. Decisions added by the specification

1. **Five itineraries or one?** The app currently offers five generated itinerary options after "Plan a trip with my pick". The specification says five recommendations are places, not itineraries, and asks for one detailed itinerary that respects the picks, with revisions. Keep the five options, or change to one itinerary plus revisions?
2. **New data fields and tables.** Phase 2 needs new columns (for example last-verified date and source, structured hours) and probably an activities table. Each needs your approval and a migration. Should I draft that design for review before any change?
3. **Scope and order.** This is several weeks of work. Recommended order: stress baseline first (it measures what is actually broken), then Phase 1, then Phase 2 data design, then Phases 3 and 4. Is that right, or do you want Phase 2 or 3 earlier?
4. **Data entry.** Structured hours, fees, last-verified dates, photos and activities have to come from someone who knows the places. Will you or your team enter them in the admin app?

## C5. Decisions recorded (17 Nov 2026)

| Question | Your answer | What it changes |
|---|---|---|
| Five itineraries or one? | **One itinerary plus revisions** | The "Compare AI Itinerary Options" row of five becomes a single itinerary that respects the picks, with revisions. The five cards stay as five **places** to choose from. Planned in Phase 3. |
| Design the new place data first? | **Yes, design first** | Before any database change I write a short design doc: new columns (last-verified date and source, structured hours, an "unknown" value for accessibility flags), an activities table, migration steps and admin app forms. Nothing changes until you approve it. |
| Order of work | **Stress baseline, then Phase 1** | S0 audit, S1 stress script, S2 baseline run, then the conversation fixes, then the data design, then Phases 3 and 4. |
| Who enters the place data | **You, in the admin app** | I build the admin forms; you fill them in over time. Places without data keep showing "not listed". |

Still open from section 6: the run budget for the stress baseline (proposed cap: 300 AI calls), and where it runs (recommended: a local API reading the production catalog read-only).
