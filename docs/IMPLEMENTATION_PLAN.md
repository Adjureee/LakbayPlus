# Lakbay+ Improvement Plan — Routing, Live Location, AI Chat, Davao Datasets

_Status: phases 1–5 implemented on 2026-11-15 (uncommitted); see "Implementation status" at the end._

This plan covers four requests:

1. Smart route optimization that stays on roads (no more cars driving into the sea).
2. Sea crossings (barge / RoRo / ferry / pump boat) allowed **only from a real pier**.
3. Live location tracking while the traveler is moving.
4. A smarter, more natural AI chat, plus many more **Davao Region (Region XI) only** destinations.

---

## 0. What the code does today (findings)

### Why the car drives into the sea

| # | Root cause | Where |
|---|-----------|-------|
| R1 | When there is no road geometry, the map draws a **curved Bézier line straight between stops** and animates a car sprite on it. Davao City → Samal or Mati → Waniban therefore crosses open water. | `apps/traveler_app/lib/widgets/lakbay_mapbox_widget.dart:435-515`, `_AnimatedRoutePolylinePainter` (`:1233-1250`) |
| R2 | Road geometry is empty in many cases: not signed in, API not configured, `public_transport` mode, or OSRM failure. The backend fallback (`_estimated_response`) returns **Haversine legs with no geometry**. | `services/api/app/features/routes/service.py:96-145, 591-612`; `travel_repository.dart:820-842` |
| R3 | Routing uses the **public OSRM demo server** (`router.project-osrm.org`): rate-limited, no uptime guarantee, so fallbacks happen often. | `services/api/.env.example:79` |
| R4 | Stops use the **attraction coordinate** (a beach, an island center, a waterfall) unless a verified `arrival_lat/lng` exists. Off-road points fail the 250 m snap check → fallback → straight line. | `routes/service.py:423-437`, `integrations/osrm/client.py:23` |
| R5 | There is **no concept of ports/piers**. Island destinations only carry a text note ("ferry must be arranged separately"), and the planner marks them `needs_review` instead of routing via a pier. | `planning/routing.py:24-40, 118-129`; seed `davao_destinations.py:612-623` |
| R6 | `fetchRoadRouteForTrip` never sends the traveler's **current location as origin**, so routes start at the first stop, not where the user is. | `travel_repository.dart:820-842` |
| R7 | The client-side AI fallback (`chatOrPlan`) lets the LLM **invent lat/lng** for stops; nothing checks the point is on land. | `lakbay_ai_service.dart:184-232` |

### Is the map tracking my location while moving? — **No.**

- `LocationService.captureCurrentLocation()` calls `Geolocator.getCurrentPosition` **once** (medium accuracy). There is no `getPositionStream` anywhere in `lib/`.
- The "my location" marker is static until the user re-requests location.
- The map is a **custom raster-tile renderer**, not the Mapbox Maps SDK, so there is no built-in location puck, heading, or follow mode.
- Android has only foreground fine/coarse permissions — fine for in-app tracking, no background tracking.

### Why the AI feels "lame"

| # | Cause | Where |
|---|-------|-------|
| A1 | When a planning state exists, the system prompt **forbids itineraries, caps replies at ~120 words**, and stacks dozens of "do not" rules. The model plays it safe and sounds like a form. | `integrations/groq/prompts.py:205-285` |
| A2 | Two different brains: signed-in users get the backend prompt; others get a separate client prompt with a **random shuffle of 16 destinations**. Answers are inconsistent. | `lakbay_ai_service.dart:174-176`, `travel_repository.dart:1978-2210` |
| A3 | Whether to build an itinerary is decided by a **keyword regex** (`plan|trip|samal|…`), not by understanding intent. | `travel_repository.dart:2027-2030` |
| A4 | Short memory: client sends 6 turns, server keeps 8 × 800 chars; RAG uses **only user turns**. | `travel_repository.dart:1982-1986`, `prompts.py:201-202`, `ai/service.py:317` |
| A5 | Only ~29 catalog destinations → retrieval often returns nothing useful, so the model hedges ("I don't have enough information…"). | `seeds/davao_destinations.py` |
| A6 | **Security:** `GROQ_API_KEY` is bundled into the Flutter app (`env_config.dart:64-79`). Anyone can extract it from the APK. |

### Dataset size

- `seeds/davao_destinations.py`: **~29 destinations** (plus their accommodations and transport rows).
- `assets/data/explore_trips.csv`: 20 curated trips.
- There is already a **destination candidates pipeline + OSM lookup** (`features/destinations/candidate_*`, `osm_lookup.py`, admin `destination_candidates_screen.dart`). We should use it rather than hand-writing seeds.

---

## Phase 1 — Road-only routing and smart ordering (fixes R1–R4, R6, R7)

**Goal:** every land leg follows real roads; if we can't get a road route, we never draw a car on a straight line.

### 1.1 Backend: Mapbox Directions as primary router, OSRM as backup
- New integration `services/api/app/integrations/mapbox_directions/` (client, schemas, errors), same pattern as `integrations/osrm/`.
  - `GET /directions/v5/mapbox/driving-traffic/{coords}` with `geometries=polyline6&overview=full&steps=true&annotations=duration,distance&radiuses=…&approaches=curb`.
  - Parse step `mode` (`driving` vs `ferry`) so ferry segments are labeled, not hidden.
  - Use a **server-side secret token** (`MAPBOX_SERVER_TOKEN`, `sk.` scope `directions:read`); the app keeps its `pk.` token for tiles only.
- Ordering: **Mapbox Matrix API** (≤25 points) feeds the existing `exact_order` (≤ `EXACT_ORDER_MAX_STOPS`) and `nearest_neighbor_two_opt` in `routes/ordering.py`. Keep OSRM Table/Trip as a fallback.
- Provider chain in `RouteService`: Google Routes (live traffic, if configured) → Mapbox → OSRM → **"unrouted"** (no geometry, explicit warning). Haversine stays for distance/time *estimates only*.
- Optional: self-host OSRM with a Mindanao extract on Render/Fly to remove the demo-server dependency.

### 1.2 Road-access (arrival) points for every destination
- Fill `arrival_lat/lng` (fields already exist) with the **parking/entrance point on a road** for every destination. Admin map pin picker already supports it.
- Backfill script `scripts/backfill_arrival_points.py`: snap each destination with Mapbox `nearest`-style Directions call (1-coordinate radius test) → propose a road point → admin verifies.
- Validation: reject a destination as `route_ready` if its arrival point is > 250 m from a routable road.

### 1.3 Land/sea validation
- Add a Region XI **land polygon** check (reuse `apps/admin_app/davao_provinces_polygons.json`, stored as PostGIS geometry).
- Any stop coordinate (admin entry or AI output) that falls in water and is not a port/island destination is rejected or snapped to its arrival point.

### 1.4 Traveler app
- `fetchRoadRouteForTrip` sends **origin = current GPS position** (or chosen start) and `return_to_origin`.
- `lakbay_mapbox_widget.dart`:
  - Car sprite and animation **only on real geometry** (`roadGeometry.length >= 2`).
  - No geometry → dashed grey "connector" line + banner "Road route unavailable — showing stop order only". No car sprite.
  - Draw each leg with its own style: solid = road, dashed blue = sea, and switch sprite per leg (`TransportMode.ferry` already exists).
- Remove client-side Bézier route math for travel lines (keep it only for decorative flight arcs if needed).

**Acceptance:** Davao City → Eden Nature Park → Philippine Eagle Center draws along roads; turning off Mapbox/OSRM shows a dashed connector, never a car over water; unit tests for provider fallback order and "no geometry → no car".

---

## Phase 2 — Sea crossings from real piers (fixes R5)

**Goal:** if the trip needs a barge/ferry, the route drives to the departure pier, crosses, then drives from the arrival pier.

### 2.1 Data model (Alembic migration)
- `sea_ports`: `port_id, name, lat, lng (road-side gate), island_group, province, port_type (roro_barge | passenger_ferry | pump_boat), source_url, verified_at, is_active`.
- `sea_links`: `link_id, from_port_id, to_port_id, vessel_type, allows_private_vehicle, crossing_minutes, typical_wait_minutes, first_trip, last_trip, frequency_text, fare_passenger, fare_vehicle, geometry (LineString, optional), source_url, verified_at`.
- `destinations`: add `island_group` (`mainland`, `samal`, `talikud`, `waniban`, `kopiat`, `balut_sarangani`, …) and optional `preferred_port_id`.

### 2.2 Seed ports and links (must be verified before go-live)
Starting candidates; confirm names, coordinates, schedules and fares with the operators / LGU tourism offices:
- Davao City ↔ Samal: **Sasa Wharf ↔ Babak** (RoRo barge, vehicles), Davao City (e.g. Sta. Ana / Magsaysay area) passenger boats ↔ Samal landings.
- Davao City / Samal ↔ **Talikud Island**.
- Mati (Pujada Bay) ↔ **Waniban Island**.
- Davao de Oro (Mabini area) ↔ **Kopiat Island**.
- Davao Occidental ↔ **Balut / Sarangani Islands**.
- Note the **Samal Island–Davao City Connector bridge** project: when it opens, a road route should win automatically — the router simply finds a road path and needs no sea link.

### 2.3 Multimodal router (`routes/multimodal.py`)
1. Group stops by `island_group`.
2. If two consecutive stops are on different island groups, pick the best `sea_link` by: drive time to port + typical wait + crossing time (+ penalty if the trip is by private car and `allows_private_vehicle = false`; then park at the pier and switch to walking/tricycle on the island).
3. Build legs: `drive(origin → port A)` → `sea(port A → port B)` → `drive(port B → stop)`. Land legs use the Phase 1 router; the sea leg uses `sea_links.geometry`, or a straight line drawn **only** as a sea leg.
4. Ordering cost matrix adds the crossing cost, so the optimizer **visits all Samal stops together** instead of crossing back and forth.
5. Warn when the trip would arrive at a pier after the last trip.
6. If Mapbox/OSRM itself returns a `ferry` step (OSM ferry routes), map it to the matching `sea_link` when possible; otherwise label it as an unverified ferry leg.

### 2.4 API and app
- `RouteLeg` gains `leg_mode: road | sea | walk`, `port_from`, `port_to`, `schedule_text`, `fare`.
- `planning/routing.py`: replace the "non-road access → needs_review" block with the multimodal route when every needed sea link exists.
- Traveler app: pier markers, ferry sprite on sea legs, a leg card "Board RoRo at Sasa Wharf · ~15 min · ₱xx/vehicle · first trip 5:00 AM (verify)".
- Admin app: CRUD screens for ports and sea links (follow `transport_screen.dart`).

**Acceptance:** Davao City → Samal beach shows drive to the pier → dashed sea leg → drive on Samal; no land leg ever crosses water; tests for island grouping, port selection, and "visit island stops together".

---

## Phase 3 — Live location tracking (answers "is Mapbox monitoring my location?")

- `LocationService.watchPosition()` → `Geolocator.getPositionStream(LocationSettings(accuracy: high, distanceFilter: 10))` (`AndroidSettings` with `intervalDuration` 3–5 s; `bestForNavigation` only in navigation mode).
- `TravelRepository` keeps `livePosition` (lat, lng, heading, speed, accuracy) and notifies the map; start the stream when the route map is open, stop it on dispose/background to save battery.
- Map widget: moving blue dot + heading arrow + accuracy circle; **follow-me** toggle; remaining distance/ETA from position to the next stop.
- **Off-route detection:** if the user is > 50 m from the route polyline for 3 consecutive fixes, re-request a route from the current position (debounced, at most every 30 s).
- **Arrival detection:** within ~100 m of a stop or pier → mark it reached and advance to the next leg.
- Permissions: keep foreground-only (already in manifest). Add background mode later only if needed (`ACCESS_BACKGROUND_LOCATION` + foreground service notification + iOS `UIBackgroundModes`).
- Decision to make: stay on the custom tile widget (works on web too) **or** adopt `mapbox_maps_flutter` on Android/iOS for a native location puck, vector tiles, and smoother navigation. Recommendation: adopt `mapbox_maps_flutter` for mobile, keep the custom widget as the web fallback.

**Acceptance:** walking or driving with the app open, the dot moves in real time; leaving the route triggers a reroute; tests use a fake position stream.

---

## Phase 4 — A smarter, more natural AI chat (fixes A1–A6)

1. **One brain, server-side only.** All chat goes through `POST /ai/chat`. Remove the client Groq call and **remove `GROQ_API_KEY` from the app**. Allow guest chat with an anonymous session + rate limit.
2. **Rewrite the system prompt** (`prompts.py`) into: persona (warm Davaoeño local guide, light Bisaya touches like "Maayong buntag!" when it fits) → answer-first rules (answer the actual question, then at most one follow-up) → grounding rules (shortened) → output schema. Raise the length cap to ~200 words, adapting to the question; allow a short "sample day" outline in chat while keeping the validated Generate itinerary step for full plans.
3. **Tool calling instead of context stuffing.** Give the model tools: `search_destinations(query, province, vibe, budget)`, `get_destination(id)`, `route_between(a, b)` (Phase 1/2 router incl. ferries), `ferry_schedule(island)`, `weather(place, date)`. The model fetches facts on demand.
4. **Intent from the model, not a regex.** Add an `intent` field (`question | brainstorm | plan_trip | modify_trip | logistics | smalltalk`) to the JSON output and use it instead of the `wantsItinerary` regex.
5. **Better memory.** Send 12 turns; keep a running **conversation summary** in `planning_state`; include assistant turns in RAG query building.
6. **Settings.** Chat temperature ~0.6, JSON/planning calls 0.2. Keep `gpt-oss-120b` on Groq with Gemini fallback; add a model comparison run with the existing `ai_model_comparison_enabled`.
7. **Streaming replies** (SSE) so the first words appear in about 1 s.
8. **Evaluation set.** 40 real Davao questions (e.g. "how do I get to Samal with my car?", "cheap 2-day Mati trip for 4", "rainy day in Davao City") scored for groundedness, helpfulness, and tone, using the existing `features/evaluation` module. Run before and after each prompt change.

**Acceptance:** eval score improves against the baseline; no API key in the APK; replies name real catalog places and correct ferry/pier info.

---

## Phase 5 — More Davao Region destinations (fixes A5)

**Target:** ~29 → **120+** active destinations, all inside Region XI, each with an arrival point, `island_group`, category, vibes, and fees.

### 5.1 Pipeline (reuse what exists)
1. Pull candidates per province with `osm_lookup.py` (tourism=attraction|viewpoint|museum, natural=beach|waterfall|peak, leisure=park) within the Region XI polygon.
2. Load them as **destination candidates** → admin reviews in `destination_candidates_screen.dart` → promote to destinations.
3. Enrichment: description, fees, hours, best time to visit, from LGU / DOT Region XI pages (store `source_url`).
4. Automatic checks: inside the Region XI polygon, arrival point routable, island destinations linked to a port, no duplicates (name + 300 m radius).
5. Rebuild RAG embeddings after import.

### 5.2 Candidate list to verify (Region XI only)
- **Davao City:** Crocodile Park, Jack's Ridge, Malagos Garden Resort & chocolate museum, Lon Wa Buddhist Temple, Japanese Tunnel, D' Bone Collector Museum, Roxas Night Market, Magsaysay Park, Shrine of the Holy Infant Jesus of Prague, Davao River whitewater rafting, Puentespina orchid garden.
- **Samal / Talikud (Davao del Norte):** Hagimit Falls, Monfort Bat Sanctuary, Vanishing Island, Sanipaan shoal, Kaputian beach, Isla Reta (Talikud), Coral Garden (Talikud).
- **Davao del Norte (mainland):** Madaum mangrove & islets (Tagum), Tagum City Hall and night market, Hijo Resorts area, Panabo mangrove (exists).
- **Davao de Oro:** Kopiat Island, Maragusan highlands and falls, Mainit Hot Springs (exists), Lake Leonard (exists).
- **Davao Oriental:** Mt. Hamiguitan Range Wildlife Sanctuary (UNESCO), Pujada Bay, Waniban Island, Sleeping Dinosaur viewpoint, Baganga Sunrise Boulevard, Aliwagwag (exists), Cape San Agustín (exists).
- **Davao del Sur:** Passig Islet (Sta. Cruz), Kapatagan highlands, Mt. Apo trails (exists), Digos eco park (exists).
- **Davao Occidental:** Balut and Sarangani Islands (Balut exists), Jose Abad Santos beaches, Malita landmarks.
- **Exclude** popular places outside Region XI (e.g. Lake Sebu, Lake Agco, Lake Holon) — the region polygon check enforces this.

### 5.3 App data
- Regenerate `assets/data/explore_trips.csv` (20 → 40 curated trips), `descriptions.json`, `short_descriptions.json`, and `discovery_sections.json` from the API instead of hand-editing them.

---

## Suggested order and rough effort

| Order | Phase | Why first | Rough size |
|-------|-------|-----------|-----------|
| 1 | Phase 1 (road routing + "no car on water" rule) | Fixes the most visible bug | 4–6 days |
| 2 | Phase 5.1 pipeline + arrival points | Phases 1–2 need good coordinates | 3–5 days + data review |
| 3 | Phase 2 (ports, sea links, multimodal router) | Depends on Phases 1 and 5 data | 5–7 days |
| 4 | Phase 3 (live tracking, reroute) | Builds on the Phase 1 router | 3–5 days (+3 days if adopting `mapbox_maps_flutter`) |
| 5 | Phase 4 (AI chat) | Can run in parallel with Phases 2–3; benefits from more data | 5–7 days |

## Decisions needed from you

1. **Routing provider:** Mapbox Directions (paid after the free tier, best Philippine coverage) vs self-hosted OSRM (free, more ops work). Recommendation: Mapbox primary + OSRM fallback.
2. **Map engine on mobile:** keep the custom tile widget or adopt `mapbox_maps_flutter`. Recommendation: adopt on Android/iOS.
3. **Guest AI chat:** allow chat without sign-in via the backend (needed to remove the client API key)?
4. **Port/ferry data:** who verifies schedules and fares (admin team vs. sourced from LGU pages)?

---

## Implementation status (2026-11-15)

| Phase | Done | Still open |
|---|---|---|
| 1. Road routing | Mapbox Directions/Matrix/Optimization primary, OSRM fallback (`integrations/mapbox_directions`); `OSRM_BASE_URL` + `MAPBOX_DIRECTIONS_TOKEN` in `render.yaml`; app sends GPS origin; no vehicle sprite without road geometry; estimated routes no longer turned into fake road lines | Set `MAPBOX_DIRECTIONS_TOKEN` on Render; verified arrival points per destination |
| 2. Piers & sea links | `sea_ports`, `sea_links`, `destinations.island_group`; pier-to-pier router (`routes/sea_planner.py`, `routes/multimodal.py`); island-aware ordering; road/sea segments, crossing cards and pier markers in the app | Verify starter pier coordinates, schedules and fares; add Waniban, Kopiat, Balut links; admin CRUD for ports/links |
| 3. Live tracking | Position stream, live dot with heading/accuracy, follow mode, off-route reroute, arrival detection, distance/time left | Device testing; background tracking (not planned) |
| 4. AI chat | Local-guide prompt, model `intent` + `suggested_replies`, 12-turn memory, chat temperature; fixed `lat/lng` origin bug, history bug, footer; guest chat (`/ai/chat/guest`) and trip drafts (`/ai/trip-draft`) on the backend; AI keys removed from the app | Remove the AI keys from `apps/traveler_app/.env` and rotate them; run `tests/manual_chat_eval.py`; streaming replies |
| 5. Davao destinations | Region XI outline + OSM island outlines (`destinations/region.py`, `sea_links/data/island_outlines.json`); candidates get `island_group` and `region_status`; publishing outside Region XI is blocked and copies the island; new Samal/Talikud destinations are tagged automatically; staging script prefills district/island/category/vibes/activities and orders scenic places first; admin form shows vibes, island and region warnings | Run the migrations, `scripts.backfill_island_groups --apply`, and `scripts.stage_osm_destination_candidates --apply`; admins review and publish (648 candidates, 357 without resorts) |
