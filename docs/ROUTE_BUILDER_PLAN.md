# Single-Place Trip Builder, Adaptive Route Optimization & Animated Road Trail

_Status: plan only, nothing implemented · 2026-11-15 · reviewed and revised (see §9)_

## 1. What is being asked

1. **Single places, not combos.** Explore currently sells bundled packages ("4-Day Samal & Talikud Island Hopping Escape"). Every card should be **one place** (one destination).
2. **The traveler sets the days.** No fixed day count comes from the place. The traveler picks places, then chooses how many days.
3. **Optimize the travel route** among the selected places with an **adaptive route optimization** approach that uses the **Haversine formula** and **OSRM** to produce an efficient visiting order.
4. **Animated progressive trail drawing** of that route on the map.
5. **Adapt Mapbox's road-trailing technique to Flutter**: the route line "draws itself" along the real road geometry.

## 2. What the code does today (findings)

| # | Finding | Where |
|---|---|---|
| F1 | Explore mixes two kinds of cards: 20 bundled **combos** from `assets/data/explore_trips.csv`, each with a fixed `days`, and **single places** synced from the backend (`api_…` ids). | `explore_screen.dart`, `travel_repository.dart:106, 516-571` |
| F2 | A multi-stop builder already exists (`tripBuilderStops`, max 8), with a days stepper that defaults to `stops.length.clamp(2, 7)`. | `explore_screen.dart:46-215`, `travel_repository.dart:199-219` |
| F3 | **Days are 1 place per day.** The offline builder uses `ordered[i % ordered.length]`: 5 places in 3 days **silently drops 2 places**; 2 places in 5 days **repeats places**. | `travel_repository.dart:1503+` |
| F4 | **Offline ordering is plain nearest-neighbour** from the first pick: no 2-opt, no GPS start, no islands. The online path (signed-in only) calls the backend optimizer, which is already strong (Held-Karp exact ≤ 11 stops, NN + 2-opt, OSRM/Mapbox matrix, island-aware piers from Phase 2). | `travel_repository.dart:1393-1450`, `services/api/app/features/routes/ordering.py`, `routes/service.py` |
| F5 | The route map draws **one waypoint per day** (`routeWaypoints` uses `day.lat/lng`), so several places in one day cannot be shown or routed. | `travel_models.dart:822` |
| F6 | The current animation is a 4.8 s **looping** line trim over the whole projected path, measured in screen pixels, with one sprite. It has no per-day sequencing, never "settles", and has no faded tail. | `lakbay_mapbox_widget.dart` (`_AnimatedRoutePolylinePainter`, `_buildSegmentSprite`) |
| F7 | Backend visit-length data exists: `stay_duration_type` = short / half_day / full_day / overnight / multi_day. | `destinations.stay_duration_type` |
| F8 | The working tree has **uncommitted UI edits** in 8 app files (map badges, notices, screens). They should be committed or reviewed before this work starts, so they are not mixed in. | `git status` |

## 3. Target experience

1. **Explore** shows single places only (photo, name, municipality, category, typical visit length such as "Half day"). The tap action is **＋ Add to trip**.
2. A **Trip tray** (bottom bar) shows "4 places selected · Plan trip".
3. **Plan sheet**:
   - Places list, with remove, **lock as first**, and **must-visit** toggles.
   - **Start from**: My location / a hotel / the first place. **End**: back to start, or anywhere.
   - **Days**: a stepper the traveler sets (1–14). It starts at a *suggested* value computed from visit lengths, labelled "Suggested: 3 days", but the traveler decides.
   - **Pace**: Relaxed (≈6 h/day) · Balanced (≈8 h) · Packed (≈10 h).
4. **Optimize** → the app shows the ordered route instantly (on-device), then refines it with OSRM/Mapbox road times when online. It reports what it did, for example "Visit order optimized: 186 km → 142 km (−24%)", and which method ran.
5. **Itinerary**: each day has 1..n places, drive times between them, and a warning when a day is over the pace budget ("Day 2 is 11 h. Add a day?").
6. **Route map**: the trail draws itself day by day along the roads, with dashed blue boat legs and a moving vehicle or boat head. Then it stays drawn, with a **Replay** button.

## 4. Data change: single places

- **Source of truth:** the backend `destinations` table (41 published now, more as candidates are published). Every Explore card is one destination.
- **Offline / no backend:** replace `explore_trips.csv` with `assets/data/places.csv`, generated from the published catalog by a new script (`scripts/export_app_places.py`). Columns: id, name, district, category, lat, lng, island_group, stay_duration_type, thumbnail. **No `days` column.**
- **Combos become "Suggested routes"** (`assets/data/suggested_routes.json`): `{title, destination_ids[], suggested_days}`. Tapping one **pre-fills the tray** with its places; the traveler still sets the days and optimizes. This keeps the curated content without fixed packages.
- **Saved trips** built from old combos keep working: they are `ItineraryTrip`s with their own days, and nothing reads the old CSV after load. Old combo ids in favourites are mapped or dropped once, during a migration in `initialize()`.

## 5. Adaptive route optimization

"Adaptive" here means the engine **picks its cost source and its algorithm** from what is available and how big the problem is, and **re-plans** when inputs change.

### 5.1 Cost model (what "distance" means)

Three tiers. The engine uses the best one available, per pair of stops:

1. **Road travel time** from the OSRM `table` (or the Mapbox Matrix through the Phase 1 chain): real driving seconds.
2. **Haversine estimate**, when there is no network or a pair has no road answer: `km × detour factor (1.35) / 40 km/h`. The same factor and speed are used in `sea_planner.py`, so both sides agree.
3. **Sea legs.** When two stops are on different island groups, cost = drive to pier + wait + crossing (+ penalty if the car cannot board), using the Phase 2 `SeaNetwork`. This keeps each island's stops together.

The response states which tier was used per leg (`cost_source: osrm | mapbox | haversine | sea`).

### 5.2 Algorithm selection (by stop count *n*, including the start)

| n | Method | Why |
|---|---|---|
| ≤ 2 | trivial | nothing to order |
| 3–11 | **Held-Karp exact** (`exact_order`, already in `ordering.py`) | provably shortest order; < 50 ms |
| 12–25 | **Multi-start nearest neighbour → 2-opt → Or-opt** (Or-opt is new: moves runs of 1–3 stops) | near-optimal and fast |
| any, offline | the same algorithms in **Dart** on Haversine costs | instant, works for guests and offline |

Constraints for all methods: fixed start (GPS, hotel or locked first place), optional return to start, and **must-keep-order** pairs if the traveler locks them (later).

### 5.3 Day planner (new, the main fix for F3)

After the order is fixed, split it into the **traveler's chosen D days**:

- **Visit hours** per place come from `stay_duration_type`: short 1.5 h · half_day 4 h · full_day 7 h · overnight/multi_day forces a day end at that place (an overnight stay).
- **Day load** = visit hours + travel hours between consecutive places (+ the first leg from the start or hotel).
- **Linear partition** (dynamic programming) into exactly D contiguous groups, **minimizing the heaviest day**. The order stays optimal, and days come out balanced.
- **More days than places:** spread long visits across days, and add flagged "free / rest" time rather than repeating places.
- **Fewer days than needed:** keep **every** place (never drop silently), mark overloaded days red, and offer "Add 1 day" or "Remove a place".
- **Suggested days** (shown, not forced) = smallest D where every day ≤ the pace budget.

### 5.4 Where it runs

- **Backend:** new `POST /routes/plan`, sitting on `RouteService` and reusing `ordering.py`, `sea_planner.py` and the matrix chain.
  - Input: `destination_ids`, `day_count`, `origin?`, `return_to_origin`, `pace`, `locked_first?`.
  - Output: ordered stops, a day for each stop, per-day legs with geometry (road and sea segments), totals, `order_method`, `cost_source`, `savings_vs_input` (km and minutes), and warnings.
- **App (Dart port):** `lib/services/route_optimizer.dart` with Haversine, Held-Karp, NN + 2-opt + Or-opt and the linear-partition day planner. It shows a result **instantly**; when the backend answer arrives (road times, geometry), the app swaps it in. This works offline and for guests.
- **Guests:** `/routes/*` currently needs a login. Either add a rate-limited guest variant (same pattern as `/ai/chat/guest`), or let guests use on-device ordering only (straight dashed lines, no road geometry). **Recommendation:** a guest endpoint with per-client limits, because road geometry is what makes the trail look right.

### 5.5 Re-planning (the "adaptive" part at runtime)

Re-run (debounced 400 ms) when: places are added or removed, the day count or pace changes, the start changes, a place is locked, or live tracking reroutes (Phase 3). Locked days the traveler has edited by hand are preserved.

## 6. Animated progressive trail (Mapbox road-trailing, adapted to Flutter)

Mapbox animates a route in two ways: by **trimming a line layer** (`line-trim-offset`, with `line-gradient` over `line-progress` for a fading tail), or by moving a point with `turf.along` at a distance along the line. The app's map is a custom Flutter tile renderer, so we re-implement those semantics. Their names are kept, so a later switch to `mapbox_maps_flutter` (whose `LineLayer` has `lineTrimOffset`) is a drop-in.

### 6.1 Components

- **`RouteTrail` model** (pure Dart, testable):
  - Polyline points in **geographic meters**, cumulative distance per vertex, and per-segment mode (road / sea / estimated) plus the day index.
  - `pointAt(distance)` and `bearingAt(distance)`: the Flutter equivalent of `turf.along`.
  - `trimmedPath(progress)`: the equivalent of `line-trim-offset` [0, p].
- **`RouteTrailController`** (`AnimationController` wrapper):
  - Duration scales with route length (≈ 1.2 s per 10 km, clamped 2–12 s) and uses an ease-in-out curve.
  - Plays **once per day leg in sequence**, pausing ~300 ms at each stop, then **holds the completed trail**.
  - Controls: `play`, `pause`, `replay`, `seek(day)`.
- **`RouteTrailPainter`** (`CustomPainter`):
  - **Drawn part:** solid line for roads, dashed blue for sea, dashed grey for estimates. The day colour comes from a palette.
  - **Fading tail:** the last ~15% of the drawn length uses a gradient shader, mimicking `line-gradient` with `line-progress`.
  - **Head:** a vehicle or boat sprite at `pointAt(progress)`, rotated by `bearingAt`.
  - **Not yet drawn:** a faint "ghost" route.
  - **Performance:** project vertices once per camera change, not per frame. Use `PathMetric.extractPath` for the trim, simplify the polyline per zoom (Douglas-Peucker, tolerance ~1 px), and wrap the layer in a `RepaintBoundary`.
- **Optional camera follow** ("Fly along" toggle): eases the camera to `pointAt(progress)`, like Mapbox's "follow a route" example.
- **Accessibility:** if the OS asks for reduced motion, or the traveler turns animation off, draw the full route immediately.
- **Rule kept from Phase 1:** no vehicle and no trail animation along estimated segments.

### 6.2 Replaces

`_AnimatedRoutePolylinePainter` and `_buildSegmentSprite` in `lakbay_mapbox_widget.dart`. The road / sea / estimated styling and the "no car on water" rule carry over.

## 7. Work breakdown

| Step | What | Size |
|---|---|---|
| 0 | Commit or review the 8 uncommitted UI edits (F8) | – |
| 1 | `export_app_places.py` + `places.csv` + `suggested_routes.json`; Explore shows single places; tray and "Add to trip"; Suggested routes pre-fill the tray | 2–3 d |
| 2 | Dart `route_optimizer.dart` (Haversine, Held-Karp, NN + 2-opt + Or-opt, day planner) + unit tests | 2 d |
| 3 | Backend `POST /routes/plan` (+ Or-opt in `ordering.py`, day planner, savings, cost sources, guest variant) + tests | 2–3 d |
| 4 | Plan sheet (days stepper, pace, start/end, locks); itinerary with many places per day; `routeWaypoints` per stop (F5) | 2–3 d |
| 5 | `RouteTrail` model / controller / painter; replace the old animation; replay, camera follow, reduced motion | 2–3 d |
| 6 | End-to-end tests and device check; docs | 1 d |

## 8. Tests and acceptance

- **Optimizer:**
  - Held-Karp equals brute force for n ≤ 8 on random instances.
  - NN + 2-opt + Or-opt stays within 5% of exact for n = 11.
  - Island stops are never split across two crossings when one is enough.
- **Day planner:**
  - Every place appears exactly once, for any D.
  - The max day load is minimal (checked against brute force for small cases).
  - An overnight place ends a day.
- **Dart vs backend:** same order on the same Haversine costs (shared JSON fixtures).
- **Trail:**
  - `pointAt` / `bearingAt` match known geometry.
  - Progress 0 draws nothing and 1 draws everything.
  - Sea segments are dashed; estimated segments get no head sprite.
  - Under reduced motion, the full trail draws at once.
- **Acceptance:**
  - Pick Eden, Philippine Eagle Center, Samal beach and Dahican, set 3 days, and press Optimize. Samal is visited via the Sasa pier, no place is dropped, days are balanced, and the trail draws day by day along the roads.

## 9. Plan review — what was improved over the first draft

1. **Never drop or repeat places (F3).** The first idea, "one place per day", was replaced by a **linear-partition day planner** (§5.3), so any number of places fits any number of days.
2. **Multiple places per day needs a model change (F5).** Without per-stop waypoints, the map and routing cannot show it; this was added to step 4.
3. **The traveler sets days, but gets help.** A *suggested* day count and per-day load warnings are shown. Nothing is forced.
4. **Reuse instead of rebuild.** The backend already has Held-Karp, NN + 2-opt, the OSRM/Mapbox matrix and the island router. The plan adds **Or-opt** and a **day planner** on top, and mirrors them in Dart, rather than starting over.
5. **Explainable optimization.** It shows the method used and the km/time saved against the traveler's own order. That matters for a thesis defense and for user trust.
6. **Islands and boats stay correct** in both ordering and animation (sea legs dashed, boat head).
7. **Guests and offline** get instant on-device ordering. Road geometry comes from a guest endpoint (decision below).
8. **The animation is distance-based in meters**, not screen pixels. It is sequenced per day, settles instead of looping, has a fading tail like Mapbox's `line-gradient`, respects reduced motion, and is built so `mapbox_maps_flutter`'s `lineTrimOffset` can replace it later.
9. **Combos are not thrown away.** They become **Suggested routes** that pre-fill the tray.
10. **Uncommitted UI edits are isolated first (F8)**, so this work lands as a clean, reviewable change.

## 10. Decisions needed

1. **Guests and road routing:** add a rate-limited `/routes/plan/guest`? Recommended: yes.
2. **Map engine:** keep the custom Flutter renderer and mirror Mapbox's trim semantics (recommended; it works on web and mobile now), or move mobile to `mapbox_maps_flutter` and use its native `lineTrimOffset`?
3. **Old combos:** convert to Suggested routes (recommended), or remove them entirely?
4. **Day limits:** a 14-day maximum and up to 12 places per trip (backend exact search ≤ 11 + start). Is that OK?

---

## 11. Addendum (2026-11-15): ranking default, smart AI cards, location-based start, sign-in gate

_Plan only. Findings come from the current code; items marked "verify" were not yet read._

### 11.1 Top 5 match: default to weighted SAW and hide the method
- **Today:** the Top Places sheet defaults to `'topsis'` and shows a TOPSIS / SAW chip selector (`explore_screen.dart:1562, 1658-1666`). The API client also defaults to `'topsis'` (`lakbay_api_catalog_service.dart:1657`) and so does the result parser (`travel_models.dart:1797`). The backend default is already `simple_additive_weighting`.
- **Plan:** send `simple_additive_weighting` (or omit the field), remove the chips, and never show a method name in the app. Keep TOPSIS in the backend for the thesis and its tests. Update `high_grade_planner_test.dart` (it expects `topsis`).

### 11.2 Smart AI: show the right cards, filtered by province
- **Goal:** "show me destinations" returns destination cards; "mountains in Davao de Oro" returns **mountain** cards **in that province**.
- **Plan:**
  1. Extend the chat model output with `place_query: {categories[], province?, limit}` (next to `intent`). New intent value: `show_places`.
  2. The backend resolves it against the catalog (`category`, `district`, active, Region XI via `region.py`), ordered by the same SAW ranking, and returns card ids in `planning.recommendations`.
  3. A province named in the message wins; otherwise use the province of the traveler's current location (`province_for`).
  4. The app renders cards for `show_places`, and plain text for other intents.
  5. When fewer matches exist than asked, say so and suggest the nearest provinces; never pad with unrelated places.
- **Tests:** mountain + province returns only mountains in that province; no province uses the GPS province; an empty result gives an honest message; the 40-question eval gets 6 "show me…" cases.

### 11.3 Remove the default Davao starting place
- **Today:** `effectiveOriginLabel` returns the profile city, else "Current GPS Location" / "Current Location" (`travel_repository.dart:3223`). Hardcoded Davao defaults are spread around: `7.0731` fallbacks in `travel_models.dart` and `travel_repository.dart`, `'Davao City'` in `travel_models.dart:220, 724`, `my_trips_screen.dart:30` and `yes_ai_onboarding_flow.dart:76` (`'Samal Island & Davao City'`).
- **Plan:**
  1. The start is the **current GPS location**, reverse-geocoded to a place name (the existing `LocationService.reverseGeocode`).
  2. No permission or no fix: ask the traveler to **search for or pin a start**. Never assume Davao.
  3. Remove Davao from every origin and label default. A fixed Region XI map center stays only as a **camera** fallback, never as an origin.
  4. A start outside Region XI is allowed, with a note that road routes are planned inside Region XI.
  5. The onboarding and chat greetings use the resolved place name, or ask for one.

### 11.4 Onboarding order and a mandatory sign-in
- **Today:** onboarding has 3 stages: AI chat (0), rating "Good so far?" (1), and "First plan, done" (2) (`yes_ai_onboarding_flow.dart`). `main.dart:50-53` only gates on `hasCompletedOnboarding`, not on `isSignedIn`. Verify where stage 2 hands off to the dashboard.
- **Plan:**
  1. Order: **try the AI → rating → sign in or register → dashboard.**
  2. The dashboard is reachable only when `isSignedIn`. No skip or "continue as guest" button.
  3. A returning signed-out user goes straight to the sign-in screen; completed onboarding is remembered but does not unlock the dashboard.
  4. Guest chat (Phase 4) stays, used only for the onboarding "try the AI" step, with its per-device limits.
  5. Tests: signed-out never reaches the shell; sign-in lands on the dashboard; the order above holds.

### 11.5 Remove the "Lakbay Traveler" account
- **Found:** `auth_screen.dart:63-65` makes up a name from the email and falls back to **"Lakbay Traveler"** (or "<name> Traveler"). I have not confirmed any seeded or default account elsewhere (verify the default `UserProfile`, the backend seeds and the admin users list).
- **Plan:** require the traveler's real name at registration and never invent one; remove the placeholder fallback; remove any seeded or default placeholder account; one-time migration that clears a stored name equal to "Lakbay Traveler" so the traveler is asked for theirs.
- **Open question:** is "Lakbay Traveler account" this fallback name, or a default or demo account you saw somewhere else?

### 11.6 Order and added decisions
Suggested order: 11.1 → 11.3 → 11.5 → 11.4 → 11.2 → then sections 4–6. 11.2 needs a backend change and a database-free test set.
Decisions to add to section 10: (5) is a start outside Region XI allowed? (6) confirm what "Lakbay Traveler account" refers to.
