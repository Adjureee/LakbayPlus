# Alternative places plan

Status: **decisions made (the recommendations in section 7). Nothing here is built.** No database change is proposed.

## 1. The problem

When a place in the itinerary does not work, Lakbay says so and stops. A place can fail in four ways today:

| What fails | Where it shows | What the traveler is offered |
|---|---|---|
| The place is closed that day, past last admission, or does not fit the hours | A **conflict** ("closed_that_day", "does_not_fit_hours", "after_last_admission", "place_closed") | Three generic choices: prioritise places, change the time window, relax another constraint |
| The day is too full or the return deadline is missed | A conflict ("exceeds_day", "after_return_deadline") | The same three choices |
| The place suits the group badly (age, effort, wheelchair, elderly) | A failed **check** ("activity_suitability") | Nothing specific |
| The place is recorded as temporarily or permanently closed | A conflict ("place_closed") and a failed check ("operating_status") | The same three choices |

"Prioritise places" lets the traveler **drop** the problem place. It never says **what could take its place**. The traveler has to leave the itinerary, browse the catalog, add something by hand, and hope it fits. The nearby-places layer on the route map is the only help, and it ignores opening hours, the group and the day.

## 2. The idea

When a place does not work, offer up to **three replacements**, found by code and **proven on the traveler's actual itinerary** before they are shown.

1. **Find candidates** in the catalog: active places in the Davao Region, not already in the itinerary, near the place being replaced.
2. **Rank them** by how alike they are (category, vibes and activities, budget class, the group's needs).
3. **Test each one**: run the same timeline engine with the swap in place. Keep only candidates that **clear the problem** and **add no new failure**. The engine is a pure function, so this is cheap and needs no model.
4. **Show the survivors** with plain reasons ("same kind of place · 4 km away · open Tuesdays 9:00 AM to 5:00 PM"), and an honest note where a fact is not recorded.
5. **Apply a swap as a normal revision.** It goes in the revision log and can be restored like any other change. Nothing is swapped without a tap.

The language model is **not** involved. Candidates, tests and reasons all come from recorded data, so the claims check has nothing to police. The chat can mention that alternatives exist, but the list itself comes from the engine.

## 3. What already exists and is reused

| Piece | Reused for |
|---|---|
| `build_timeline` (pure) | Testing each candidate on the real itinerary |
| Conflicts and checks with `destination_ids` | Knowing which place failed and why |
| `TimelineRevision.destinationIds` (full replacement list) | A swap is the same list with one id replaced. **No new revision mechanism** |
| Append-only revisions and restore | A swap can be undone |
| `nearbyPlacesForTrip` (app) | The distance idea; the new ranking is on the server so it can see hours and flags |
| Place fields: category, vibes, activities, budget class, kid / elderly / wheelchair flags, hours, status, fees | Ranking and reasons |

## 4. How candidates are chosen

**Pool.** Active places in scope that are not already in the itinerary and not recorded as closed. A place with **no coordinates** is skipped.

**Distance.** Within 15 km of the place being replaced (straight line, the same rule the engine already uses for estimates). If fewer than three candidates survive, the radius grows once to 30 km, and the reason says the distance.

**Rank** (higher is better, all from recorded data):

| Signal | Why |
|---|---|
| Shares a category with the failed place | Closest to what the traveler chose |
| Shares vibes or activities | Same kind of day |
| Same or lower budget class | Does not break the budget |
| Matches the group's needs (kid, elderly, wheelchair) when the trip states them | Avoids a second failure |
| Hours are **recorded** and cover the slot | A known "open" beats an unknown |
| Nearer to the failed place | Less travel change |

A recorded but unfavourable fact (closed that day, no wheelchair access when needed) **removes** the candidate. A **missing** fact never removes it and never counts as a pass: it lowers the rank and appears in the reason ("hours not confirmed").

**Test.** Swap the candidate in at the failed place's position and rebuild. A candidate survives only if the original conflict is gone, no **new** conflict appears, and no check that passed before now fails. Checks that "cannot verify" stay as they are and are listed.

## 5. What the traveler sees

- In the conflict card, under the message for a place: **"Swap for…"** chips, one per candidate (the place name, and one line of reasons). Tapping one opens a short confirmation: what changes ("Day 1 now ends at 5:10 PM instead of 6:40 PM"), then **Swap**.
- On a failed `activity_suitability` check: the same chips for the places the check names.
- When **no candidate survives**: the card says "We could not find a place that fits instead", and keeps the three existing choices. It does not suggest anything it did not test.
- After a swap, the revision log shows "Swapped X for Y" and the existing restore works.

## 6. What it does not do

- It does not add a place nobody asked to replace. The nearby layer stays as it is.
- It does not swap automatically. Every swap is a tap.
- It does not use the model to pick or describe places.
- It does not invent facts: no recorded hours means "hours not confirmed", not "open".
- It does not rebalance the whole trip. It replaces **one** place at a time.

## 7. Decisions (all recommendations accepted)

1. **When alternatives appear. Decided: only for a failing place.** Only for a place that fails a check or causes a conflict (recommended), or also an on-demand "find something else" on any stop?
2. **How many to show. Decided: three.** Three per problem place (recommended), or more?
3. **How far to look. Decided: 15 km, growing once to 30 km.** 15 km, growing once to 30 km (recommended), or stay strictly near?
4. **Unknown hours. Decided: shown, ranked lower, labelled.** A candidate with unrecorded hours may be shown, ranked lower and labelled "hours not confirmed" (recommended), or shown only when hours are recorded?
5. **Same category only? Decided: prefer it, allow close ones.** Prefer the same category but allow close ones (recommended), or require the same category?
6. **Where it runs. Decided: on the server, in the timeline response.** On the server inside the timeline response (recommended: one call, one source of truth), or a separate call the app makes when the traveler taps?

## 8. Steps

| Step | Contents | DB change | Deploy risk |
|---|---|---|---|
| **A1** Engine | Pure function: candidates, ranking, test by rebuilding, reasons. Heavy tests on fixed data (closed day, wheelchair, nothing fits, unknown hours, ties) | none | None, it is not called yet |
| **A2** API | `alternatives` in the timeline response (or its own endpoint, decision 6), with the swap shown as a revision. Live check through the public `/planning/timeline` | none | Low |
| **A3** App | Chips in the conflict card and the failed-check row, the confirmation, the revision-log line | none | Low |

Each step ships alone and is live-checked before the next, as with the timeline and the claims check.

## 9. How we will know it works

- **A1:** for each conflict code and the suitability check, a fixture where the swap clears it, one where nothing fits, and one where the best-looking candidate is rejected because the swap makes a different check fail.
- **A2:** live, through the public endpoint with real catalog places, I ask for an itinerary with a place closed on the chosen day and read the alternatives. I check three things by hand: each one really is open that day, none is already in the trip, and "hours not confirmed" appears where hours are missing.
- **A3:** on the phone: tap a chip, confirm, see the change, open the revision log, restore.
- **The honest limit:** admin data is thin. Many places have no recorded hours yet, so on today's data many alternatives will say "hours not confirmed". The feature gets better as you enter hours in the admin app. That is the same data entry already on your list.
