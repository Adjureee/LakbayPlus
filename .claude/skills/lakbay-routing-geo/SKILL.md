---
name: lakbay-routing-geo
description: Change or check Lakbay routing and geography - route preview/optimize, stop ordering, day planning, sea and ferry crossings, snap rules, Mapbox/OSRM clients and profiles (driving, walking, cycling, traffic), route geometry on the traveler map, "Road route unavailable" notices. Use whenever a task touches services/api routes or integrations/osrm or mapbox_directions, or the traveler app's route, map or trail code, even if the user only describes a symptom like a dashed line, a car on water or a wrong travel time. Invoke this automatically when such work starts; the user should never have to ask for it.
---

# Lakbay routing and geo correctness

Approved scope and wording: `services/api/docs/routing.md`. Background on past bugs: `docs/ROUTING_ACCURACY_PLAN.md`.

## Where things live

- Backend: `app/features/routes/` (`service.py`, `snap_policy.py`, `ordering.py`, `day_planner.py`, `sea_planner.py`, `multimodal.py`), `app/integrations/osrm/client.py`, `app/integrations/mapbox_directions/client.py`, AI geo input in `app/features/ai/geo_context.py`.
- Traveler app: `lib/services/route_optimizer.dart`, `route_summary.dart`, `mapbox_service.dart`, `lib/widgets/lakbay_mapbox_widget.dart`, `route_trail.dart`.

## Invariants (the app would show wrong or invented routes if broken)

- **Router order:** Mapbox first when `MAPBOX_DIRECTIONS_TOKEN` is set, OSRM as fallback (`get_osrm_client`, `ChainedRoutingClient`). Cost sources are `haversine | osrm | mapbox | google_routes | sea`; keep the tier honest per leg.
- **Profiles:** Mapbox driving uses `driving-traffic` by default; walking and cycling are Mapbox profiles. OSRM supports only driving and walking, and `OSRM_WALKING_BASE_URL` must be a separate foot-profile service, never the driving URL.
- **Snap limits** (`snap_policy.py`): verified arrival 250 m (`MAX_PREVIEW_WAYPOINT_SNAP_METERS`), port 800 m, attraction pin or the traveler's GPS 2000 m. A far snap on an attraction pin keeps the road part and returns the gap as a dashed last-stretch segment (shown only above 250 m); a far snap on a verified arrival rejects the route as bad data.
- **Never fabricate.** Estimated (haversine) results carry `is_estimated` and no polyline, and the app must not draw them as a road. Straight-line fallbacks and unreachable results keep their own labels.
- **Unverified arrivals** (`arrival_points_verified=false`) keep the approximation wording and get no turn-by-turn steps. A road result can be not-estimated and still unverified.
- **Saved trips** restore their saved route snapshot with no new routing request; "Recalculate route" is an explicit action that does not overwrite the trip.
- **No vehicle on water:** sea legs and pier crossings come from `sea_planner` and sea links, not from road routing.

## Tests

From `services/api`, with `./.venv/Scripts/python.exe -m pytest -q` (the route and provider files alone took about 3.5 minutes, so run them in the background):
`tests/test_snap_policy.py tests/test_mapbox_directions.py tests/test_osrm_trip_parser.py tests/test_route_*.py tests/test_phase6_routes.py tests/test_planning_routes.py tests/test_sea_routing.py tests/test_commute_directions.py tests/test_phase15b_geo_analytics.py tests/test_phase15e_ai_geo_context.py tests/test_ai_itinerary_geo_quality.py`

From `apps/traveler_app`, with `flutter test --no-pub -j 2`:
`test/route_optimizer_test.dart test/route_geometry_test.dart test/route_trail_test.dart test/phase3_real_routing_test.dart test/phase4_commute_directions_test.dart test/cycling_and_traffic_test.dart test/map_ux_and_sync_test.dart`, then `flutter analyze --no-pub`.

Follow `lakbay-verify` for reporting. Mapbox tests mock the transport (`tests/test_mapbox_directions.py` shows how) because no Mapbox token is set locally; new tests should do the same.

## Live routing calls

Real Mapbox or public OSRM calls spend a token or hit a shared demo server. Make none unless the user asks; if they do, state the number of requests first, keep it to a handful, and never print the token. A new route behaviour needs a mocked test with a coordinate set and expected result, not a live check.

## Definition of done

The invariants above still hold for the changed path; the relevant backend and Dart tests were run and reported with counts; any new mode or fallback has a test showing both the road result and the labelled estimate. Ask before changing database fields or backend code (`services/api/AGENTS.md`), and do not commit.
