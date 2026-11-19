# Itinerary timeline design (Phase 3 and 4)

Status: **draft for review. Nothing here is implemented.** No database change is proposed for the first three steps. Decisions for you are in section 9.

Source: specification B6 (itinerary), B7 (budget), B8 (validation), B9 (errors), B10 (phases 3 and 4), and the decisions already made: **one itinerary plus revisions** (not five), the traveler's picks are never silently dropped, checks are **passed / failed / cannot verify**, and the budget comes from `planning/costs.py`. It builds on the place data now in the database (opening hours, prices, activities, visit lengths, booking notes, unknown accessibility).

## 1. What exists today

| Piece | What it does | Gap against the specification |
|---|---|---|
| AI generator (`/ai/itineraries/generate`, `ai/validators.py`) | The model writes up to five "options": days of activities, each with a free-text `time` (20 characters), a title, a description and a cost labelled `ai_draft_estimate`. The validator needs the total to equal the sum of activity costs and to be within budget, then re-asks the model on failure | Times are text, so order and overlaps cannot be checked. The cost rule pushes the model to put a number on every item. No travel legs, meals, buffers, booking notes, return leg or arrival time. Checks are pass or fail only |
| Catalog draft (`planning/draft.py`) | No model. Orders stops by route, gives each stop a clock time from a visit length (`stay_duration_type` heuristic), caps a travel leg at 90 minutes, and lists costs as listed or unlisted | Closest to what we want, but times are "provisional" without saying so, hours and last admission are ignored, and it also returns several options |
| Budget (`planning/costs.py`, `PlanningBudget`) | Known and estimated lines, missing costs with reasons, a total only when complete, per-person or whole-trip, age prices, allowances labelled "not a verified catalog fee" | Close to B7. Neither itinerary path uses it |
| Route (`planning/routing.py`) | Order, distance and duration per leg, with whether the route is verified | Not attached to timeline items |
| App | "Compare AI Itinerary Options" row of five; the repository builds "N itinerary options built from your picks" | To become one itinerary card plus revise |

## 2. The idea: build the timeline in code, not with the model

The biggest source of wrong itineraries is asking a language model to invent times, durations and costs. The structure here is arithmetic on data we hold, so the **server builds it deterministically** from the traveler's picks, and each item records **why** it has its time and how much to trust it. The model is not needed to schedule. Its remaining jobs are the ones it is good at: understanding a correction ("start later", "swap lunch") into a change of the plan state, and, optionally later, phrasing the explanations.

This also makes B8 simple: the checks run on a structure whose times we computed, instead of trying to parse model text.

## 3. The timeline structure

A **Timeline** is a list of days; each day is an ordered list of **items**.

| Field | Meaning |
|---|---|
| `kind` | `depart`, `travel`, `visit`, `activity`, `meal`, `rest`, `buffer`, `return` |
| `starts_at`, `ends_at`, `duration_minutes` | local times (Asia/Manila) |
| `time_basis` | **confirmed** (a scheduled session or an opening time from structured hours), **estimated** (a calculated value with a stated basis, such as straight-line distance at an assumed speed), **provisional** (a planning default such as "start 8:00"), or **unknown** |
| `destination_id`, `activity_id` | canonical ids, so text, cards, images and stops stay consistent |
| `travel` (on travel items) | from, to, mode, minutes, basis `supported` / `estimated` / `unknown`, route verified or not |
| `costs` | cost lines with amount or **null**, status known / estimated / unknown, per person or shared, and "included in" (admission, package) to prevent double counting |
| `booking`, `restrictions` | from the place's booking fields and the activity's age, effort and weather limits |
| `notes` | specific uncertainty in plain words ("Hours not confirmed for this place"), never a generic disclaimer |

The unknown stays unknown: a leg with no coordinates has `minutes: null` and says so; the schedule after it is marked provisional instead of getting an invented number.

## 4. How times are assigned

1. **Day start** is the traveler's `departure_time` (already in the trip state); with none, 8:00 is used and the whole day is marked **provisional** with that stated.
2. **Order** is the route order the app already computes (or the traveler's own order when they choose to keep it).
3. **Travel legs** use the route preview's duration when the route is calculated (basis `supported`, `estimated` if the provider says so). With coordinates but no route, a straight-line estimate at a stated speed (basis `estimated`, calculation shown). With neither, `unknown`.
4. **Visit length**, first present of: the activity's recorded duration, the place's recorded typical visit (step 1 of the place data work), then the heuristic from `stay_duration_type` (basis `estimated`, "planning basis"). The traveler's pace scales planning defaults only, never a recorded duration: relaxed 1.25, balanced 1.0, packed 0.85.
5. **Opening hours** from structured hours (step 2): a stop is placed inside the window for its day, after opening and before closing minus its visit, respecting last admission. If it does not fit that day it is reported as a conflict (section 6), never silently moved or removed. With text-only or no hours the stop is placed provisionally and noted "hours not confirmed".
6. **Meals, rest and buffers** are planning items: lunch around 12:00 for 60 minutes (a second meal when the day runs past 18:00), a 15-minute buffer between legs, a rest after 3 hours of visits at a relaxed pace. All are labelled **provisional planning defaults**. A meal has a cost only from the traveler's own meal allowance; otherwise its cost is unknown.
7. **Return** to the return place (or the start place) with an expected arrival time, checked against `return_deadline` when set.

## 5. Budget

The timeline asks `planning/costs.py` for the budget and attaches its lines to the items they belong to. The summary follows B7 exactly:

- known costs, estimated costs with their basis, unknown costs listed by item;
- the subtotal, and the **remaining budget only when the picture is complete**; otherwise "this is not the full trip cost";
- "within budget" is only said when the essential expenses are covered by data; otherwise "fits the costs we know about, X unknown";
- fees included in admission or a package are not counted twice (the `included_in` field, filled from the activity's "fee included in admission" value).

The itinerary generator's rule that every item must carry a number and the sum must match is dropped: unknown stays unknown.

## 6. Checks (B8) and conflicts

Each check returns **passed**, **failed** or **cannot verify**, with the items it concerns. **Missing data never passes.**

| Check | Passes when | Cannot verify when |
|---|---|---|
| Dates valid, order and overlaps | all times chronological, nothing overlaps | (always checkable) |
| Ids valid and consistent | every item's place exists and is one of the picks (or marked optional) | |
| Every pick present | each selected place has an item or is in a reported conflict | |
| Geographic scope | places are inside the Davao Region | |
| Budget arithmetic, traveler counts, pricing units | lines sum as `costs.py` says and units match the group | a price has no unit |
| Opening hours and last admission | structured hours cover the visit | the place has text hours only or none |
| Travel time | the leg is supported or estimated | the leg is unknown |
| Visit durations and buffers | recorded or estimated duration present and buffers kept | the duration came from the planning default only (shown as an estimate, not a pass) |
| Return deadline | arrival before the deadline | no deadline set, or an unknown leg precedes it |
| Activity suitability | age, effort and weather limits met | the limit is unrecorded |

The itinerary is described as **feasible** only when nothing failed, and the unverifiable checks are listed in plain words next to it ("Hours are not confirmed for 2 stops").

**Conflicts.** When picks cannot fit (closing time, deadline, too many hours), the timeline still lists every pick; the ones that do not fit are flagged, and the reply offers three choices: **prioritise** some places, **change the time window** (start earlier, end later, add a day), or **relax another constraint**. Nothing is removed without the traveler's choice. Suggested alternatives are shown separately and labelled optional.

## 7. One itinerary and its revisions

The timeline is a **pure function of the trip state and the catalog**, so a revision is a change of state ("start at 9", "drop the museum", "add a lunch break", "swap day 1 and 2") followed by a recompute. To keep the traveler's accepted choices, the state gains a small list of **pins** (a stop locked to a day or a start time), which the builder honours before anything else. Each recompute returns a short **what changed** list ("Moved lunch to 12:30 because the museum closes at 12:00"), so a revision is explained and never silently different.

No database table is needed for this. Saving an itinerary to the traveler's trips with its revision log is a later step (section 8, T4).

## 8. Steps

| Step | Contents | DB change | Size |
|---|---|---|---|
| **T1** Timeline engine | Pure functions: assign times, travel legs, durations, meals and buffers, conflicts, checks, budget lines. Heavy unit tests on fixed data (no model, no network). No route calls: it consumes a route result | none | Large |
| **T2** API and chat | `POST /planning/timeline` (state in, timeline + checks + budget + what-changed out). The chat's "Generate itinerary" calls it; corrections go through the existing state updates and recompute; the five-options path is retired from the flow (endpoint kept) | none | Medium |
| **T3** App | Day-by-day timeline screen: time range per item, expandable details (travel leg, costs, booking, uncertainty chips Confirmed / Estimated / Provisional / Unknown), a checks panel ("5 passed, 1 failed, 3 cannot verify"), a conflict card with the three choices, replace "Compare AI Itinerary Options" with one itinerary card and Revise | none | Large |
| **T4** Saved itineraries, revisions history, export | Save to trips with a revision log; PDF export if wanted | migration (approval) | Medium |

Each step ships on its own and is live-checked before the next. T1 needs no deploy risk at all (new code, not yet called).

## 9. Decisions for you

1. **Deterministic first, model for corrections only** (recommended), or keep the model writing the timeline with a stricter validator?
2. **The five-option AI generator:** retire it from the app flow once T2 lands (recommended; the endpoint stays), or keep it as "alternative ideas"?
3. **Planning defaults:** day start 8:00, lunch 12:00 for 60 minutes, 15-minute buffers, pace factors 1.25 / 1.0 / 0.85, straight-line speed for estimates. Fine, or different values? All appear on screen as provisional.
4. **Meals and rest in every itinerary** (recommended, as the specification lists them), with costs unknown unless the traveler approved a meal allowance?
5. **Persistence:** derived-only through T3, saving in T4 (recommended), or save from the start?
6. **Export (PDF)** in scope for T4, or later?
7. **Start with T1.** It is backend-only and has no deploy risk.

## 10. How it maps to the acceptance tests

Times, travel legs and labelled assumptions (acceptance 10) come from section 3 and 4; no invented figures (B5) from the `unknown` rule; budget honesty (B7) from section 5; deterministic checks with "cannot verify" (B8) from section 6; picks preserved and conflicts explained from section 6; revisions without losing accepted choices from section 7.

## 11. Nights (overnight modelling)

A multi-day itinerary now closes each day with an `overnight` item and starts the next day from where the group sleeps.

- **Where they sleep** is the stay the traveler chose (`selected_accommodation_ids`). Stays are offered at picked places only, so the lodging is always one of the picks. If the chosen rooms are all at one place, that place is the lodging. If they are at several places, which night is spent where is not recorded, so none is assumed and the night says why. If no stay is chosen, none is invented.
- **With a lodging:** the day ends with travel to the lodging (skipped when the last stop is the lodging), then "Overnight at <stay>". The next day's first trip starts from the stay, and no trip is added when the first stop is the lodging's own place.
- **Without a lodging:** the night reads "Overnight (place to stay not chosen)" and says the next day's first travel time is measured from the last place of the day before. This was the earlier behaviour; it is now stated.
- **Travel times** to and from the lodging are straight-line estimates (never to an island), because the route covers only the chain of picks. A leg the route did supply is kept.
- **Check:** `overnight_stay` passes when a stay is chosen and cannot be verified when not. It only exists when the trip has a night.
- **Not modelled:** a different stay each night, check-in and check-out times, or the stay's own opening hours.
