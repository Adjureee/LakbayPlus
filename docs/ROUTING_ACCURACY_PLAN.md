# Routing accuracy & "Road route unavailable" — implementation plan

Date: 2026-11-16 · Branch: `feature/routing-ai-davao-data`
Input dataset: `davao_destinations_arrival_points_complete.csv` (112 rows, 67 `route_ready=True`)

## 1. What is broken (confirmed in code)

### Bug A — Every Explore trip shows "Barangay San Pedro" (screenshots 1–3)

`TravelRepository.buildDetailedItineraryFromExplore` →
`generateCustomTrip` (`apps/traveler_app/lib/services/travel_repository.dart:3798`)
picks a **hardcoded template** by keyword in the destination name
(`samal`, `mati`, `buda`, …). Anything that matches none of them —
Tagbibinta Falls, Panabo Mangrove Forest Park, Museo Dabawenyo, … — falls into
the `else` branch whose Day 1 is
`Barangay San Pedro & Poblacion, Davao City` (`travel_repository.dart:3984`).

Consequences seen on the device:

| Screenshot | Symptom | Cause |
|---|---|---|
| 1 Tagbibinta | Day card "Barangay San Pedro…", "3 Stops • 4 km" | The 3 stops are template stops at San Pedro ±0.01°, not the falls |
| 2 Panabo | D1.1–D1.3 pins in downtown Davao City | Same template stops |
| 3 Panabo | Road line ends at the park, but the card still says San Pedro | Backend route uses the real destination id; the card/markers use the template |

So the header, markers, day card, dashed connectors and hotel area all describe
a different place from the one the traveler tapped.

### Bug B — "Road route unavailable — dashed lines show stop order only"

Chain for Tagbibinta Falls:

1. The app asks the API for a route to destination `8`.
2. `_destination_to_stop` (`services/api/app/features/routes/service.py:693`)
   uses `arrival_lat/lng` only when `route_ready` + source + verified-at are
   set. **No destination has an arrival point yet** (the 29 Oct review says
   "Route-ready: 0 of 118"), so it routes to the *attraction pin* — the
   waterfall itself, in the forest.
3. OSRM snaps that pin to the nearest road. `_require_waypoint_snaps`
   (`app/integrations/osrm/client.py:276`) rejects any snap > **250 m**
   (`MAX_PREVIEW_WAYPOINT_SNAP_METERS`). Waterfalls, mountains, park interiors,
   islands and beaches routinely exceed that.
4. The service falls back to a Haversine `is_estimated` response with no
   polyline; the app (`_parseRouteResult`) correctly refuses to draw it, so
   the map shows only dashed stop-order lines.

Secondary contributor: the app's route request times out after **12 s**
(`lakbay_api_catalog_service.dart:762`). A Render cold start or a long
mountain route via OSRM (server timeout 30 s) returns `null` → same notice.

Panabo Mangrove (screenshot 3) routes fine because its pin happens to be
within 250 m of a road.

## 2. Dataset analysis — how accurate are the destinations?

I matched the 41 app places (`assets/data/places.csv`) to the dataset and
measured pin-to-gate distance:

| Result | Count | Examples |
|---|---:|---|
| Same place, gate within 1 km | 9 | People's Park 0.23 km, Christ the King 0.16 km, Monfort 0.31 km |
| Same place, 1–8 km apart (needs review) | 11 | Tagbibinta 3.24 km, Panabo Mangrove 2.56 km, Dahican 3.70 km, Little Boracay 5.93 km, Aliwagwag 7.12 km, Mt Apo 7.69 km |
| Same place, > 8 km apart | 1 | Mt Hamiguitan 13.5 km |
| Name matched a **different** place | 6 | Malagos Garden → Montefrio (31 km), DDG Beach → Banana Beach (94 km), Balut Island → Kopiat (216 km) |
| No match in dataset | 14 | Panabo City Parks, Cape San Agustin, Uraya's Peak, Bukid Amara, … |

Takeaways:

- **Name-based auto-matching is unsafe.** Import must use an explicit
  `dataset row → destination_id` mapping file, reviewed by a person.
- **The dataset is not always more accurate than the app.** Panabo Mangrove's
  current app pin sits exactly on Mapbox's "Panabo Mangroves Forest Park"
  label (screenshot 3); the dataset's "San Isidro entrance" is 2.56 km north.
  Large offsets must be eyeballed, not auto-applied.
- `coordinate_precision` is 4 decimals (~11 m) and 24 rows are
  `approximate_*`. Only `verified_gate_frontage`, `verified_wharf_jumpoff`,
  `verified_trailhead_parking`, `verified_highway_frontage` should become
  `route_ready`.
- 22 rows need a boat (`requires_ferry_or_boat=True`); the arrival point is a
  wharf, which the sea planner already supports (port snap 800 m).

## 3. Plan

### Phase 1 — App: build Explore trips around the real destination (Bug A)

File: `apps/traveler_app/lib/services/travel_repository.dart`

1. In `buildDetailedItineraryFromExplore`, replace Day 1 of the template with a
   day anchored on the explore place: `cityTitle = explore.title`,
   `summary = explore.description`, `lat/lng = explore.lat/lng`, and one
   `ItineraryStop` at the destination (category from the place, hours/fee in
   the description). No fake "Morning Highlight / Culinary / Golden Hour"
   stops with ±0.01° offsets.
2. Extra days (multi-day explore trips) keep a single anchored stop per day
   ("Free day near <place>") instead of jumping to unrelated San Pedro / Samal
   templates.
3. Leave `generateCustomTrip` templates for the free-text "custom trip"
   feature only, and change its `else` fallback to centre on `centerLat/Lng`
   rather than San Pedro.
4. Tests in `test/trip_builder_flow_test.dart`: an explore trip for
   Tagbibinta Falls has Day 1 titled "Tagbibinta Falls", one stop at the
   place coordinates, and no stop containing "San Pedro".

### Phase 2 — Backend: stop failing the whole route on a far snap (Bug B)

Files: `app/integrations/osrm/client.py`, `app/features/routes/service.py`

1. Keep the 250 m guard for `verified_arrival` stops (a far snap there means
   bad data).
2. For `attraction`-basis stops (no verified arrival point), allow a larger
   snap (e.g. 2 km) **and** return the last road point plus an explicit
   `is_estimated` "walk/last-mile" segment from the road end to the pin, with
   a warning "Road ends ~X m from <place>; final approach is on foot/trail."
   The app already draws estimated segments as grey dashes beside a real road
   line.
3. Beyond 2 km: keep today's Haversine fallback (likely wrong pin).
4. Tests in `tests/test_route_plan.py` / a new `test_osrm_snap_policy.py`
   with a fake OSRM client: 300 m attraction snap → road route + last-mile
   segment; 300 m verified-arrival snap → rejected; 5 km → estimated.

### Phase 3 — Import the dataset's arrival points (accuracy)

New: `services/api/scripts/import_arrival_points.py` +
`services/api/app/features/destinations/data/arrival_point_mapping.csv`.

1. Mapping CSV columns: `dataset_row, destination_id, reviewed_by, note`.
   I pre-fill the 20 confident pairs from the table above; the 6 wrong
   matches and 14 unmatched places stay out until reviewed.
2. The script (dry-run by default, `--apply` to write):
   - sets `arrival_lat/lng`, `arrival_source_url`, `arrival_verified_at`;
   - sets `route_ready=True` only when dataset `route_ready=True`,
     precision is a `verified_*` value, `snap_failure_mode` is not
     `access_restriction`/`multi_day_ferry_out_of_scope`, and the gate is
     ≤ 1.5 km from the attraction pin — otherwise stores the point with
     `route_ready=False` and prints it for review;
   - never changes the attraction `lat/lng` (the pin shown on the map).
   - prints a report: applied / held for review / skipped, with distances.
3. Uses the existing destination update validation in
   `destinations/service.py` (no schema change, no new migration).
4. Re-export `apps/traveler_app/assets/data/places.csv` with
   `scripts/export_app_places.py` so offline mode matches.

### Phase 4 — App resilience

1. Raise the route request timeout from 12 s to 30 s and retry once, so a
   Render cold start no longer reads as "no road route".
2. When the response is `is_estimated`, show the API's warning text in the
   map notice instead of the generic message, so the traveler learns *why*.

### Phase 5 — Verification

- `flutter test` and `pytest` in `services/api`.
- Manual on device: Tagbibinta, Panabo Mangrove, Dahican, Monfort — expect a
  solid road line, the correct Day 1 card, and correct markers.

## 4. Status (2026-11-16)

- **Phase 1 done.** `_anchorDaysOnExplorePlace` in `travel_repository.dart`;
  later days are continuation days with no duplicate pins. Test:
  `test/explore_trip_anchor_test.dart`. The free-text custom-trip templates
  are unchanged.
- **Phase 2 done.** New `app/features/routes/snap_policy.py` (gate 250 m,
  pier 800 m, attraction/origin 2 km); `OSRMRouteResult.waypoint_snaps`;
  dashed last-stretch segments and warnings in `_osrm_response` and the
  multimodal runs. Test: `tests/test_snap_policy.py`.
- **Phase 3 built, dry-run only.** Rules in
  `services/api/app/features/destinations/arrival_import.py`, reviewed pairs
  in `.../data/arrival_point_mapping.csv` (24 of 41 destinations), dataset
  copied to `services/api/docs/`, CLI `python -m scripts.import_arrival_points`
  (`--apply` to write). Dry run: 7 ready, 5 stored without route_ready,
  12 held (pins 1.7–7.7 km apart), 17 destinations with no dataset row.
  Re-exporting `places.csv` is not needed: it holds attraction pins, which
  the import never changes.
- **Held places reviewed against OpenStreetMap (applied 2026-11-16).**
  Current pin confirmed, dataset point rejected: Museo Dabawenyo, Panabo
  Mangrove, Camp Sabros, Isla Reta. Pin moved to the OSM feature
  (`destinations/data/pin_corrections.csv`, applied with
  `python -m scripts.apply_pin_corrections`): Eden Nature Park (plus its
  OSM reception area as route-ready arrival), Dahican Beach (dataset gate
  then passed → route-ready), Tagbibinta Falls, Mainit Hot Springs, Little
  Boracay, Tudaya Falls, Aliwagwag Falls. Seed file and `places.csv` updated.
  Mount Apo Trail Area: summit pin kept; routes end at the OSM "Trekkers'
  Information Center" in Kapatagan (route-ready, applied 2026-11-16).
- **Phase 4 done.** Route requests time out after 30 s with one retry; the map
  notice shows the API's reason (`routeNotice`); live tracking follows the
  solid road part even when a dashed last stretch exists.

## 5. Decisions needed

- Approve Phase 1 + 2 + 4 (code fixes) now.
- Phase 3 writes to the production Neon database when run with `--apply`;
  I will build and dry-run it, but **you run `--apply`** after reviewing the
  report, especially the 11 places whose gate is 1–8 km from the pin.
