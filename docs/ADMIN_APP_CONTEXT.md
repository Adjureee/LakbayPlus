# Lakbay+ Admin — context summary

Written 2026-11-16 for handing to another coding assistant. Describes the
admin work on `main` (latest commit `659da71`). Repo: `Adjureee/LakbayPlus`.

## Project layout

| Path | What |
|---|---|
| `apps/admin_app` | Flutter **web** admin (package `lakbay_admin`) |
| `apps/traveler_app` | Flutter Android traveler app (package `lakbay_travel`) |
| `services/api` | FastAPI + SQLAlchemy + Alembic, Neon Postgres, deployed on Render (`lakbay-api`) |
| `docs/ADMIN_MAP_AND_NEARBY_PLAN.md` | The plan these features came from |
| `docs/ROUTING_ACCURACY_PLAN.md` | Routing / arrival-point background |

Both apps talk to the same API and database. The traveler app downloads active
destinations from the API at startup, so admin edits need no new APK.

## Run the admin app

PowerShell 5.1 (no `&&`):

```powershell
Set-Location apps\admin_app
flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=https://lakbay-api-rioi.onrender.com/api/v1 --dart-define=MAPBOX_PUBLIC_TOKEN=pk.YOUR_TOKEN
```

- `API_BASE_URL` defaults to `http://127.0.0.1:8000/api/v1`.
- `MAPBOX_PUBLIC_TOKEN` is optional. With a public `pk.` token maps use Mapbox
  Streets/Satellite; without it they fall back to OpenStreetMap tiles. `sk.`
  tokens are ignored. The admin is a web build, so the token is readable by
  visitors: restrict it by URL in the Mapbox account.
- Render's `lakbay-admin` static site publishes `apps/admin_app/build/web`,
  which is **not in the repo** and has no build command, so hosted deploys are
  manual today.

## Admin features added (in order)

### 1. Route endpoint editor — `5612d99`
`lib/screens/destination_editor.dart`, section **Route endpoint**.
- Fields: endpoint lat/lng (typed or "Pick endpoint on map"), source link,
  **Route-ready** switch, "Clear endpoint".
- Live distance from the pin; warning past 2 km.
- Saving a sourced endpoint sends a fresh `arrival_verified_at` (API requires
  source URL + verification time for `route_ready`).
- API fields on `destinations`: `arrival_lat`, `arrival_lng`,
  `arrival_source_url`, `arrival_verified_at`, `route_ready`. When
  `route_ready` is true, routes end at the arrival point instead of the pin.

### 2. Mapbox tiles — `1982859`
`lib/core/map_tiles.dart`: `AdminMapTiles` (tile layer, attribution) and
`AdminMapStyleSwitch`. Used by every admin map. Built on `flutter_map` 8.3.1 +
`latlong2`; attribution links use `url_launcher`.

### 3. Destinations map view — `fd10096`
`lib/widgets/destinations_map_view.dart`, toggled by **List / Map** on
`lib/screens/destinations_screen.dart`.
- Photo pin per destination (search and category filters apply), Davao Region
  outline, route endpoints as parking markers with dotted lines.
- Side panel: photo, district/category, coordinates, endpoint status and
  distance, **Edit**, **Move pin** (click map → Save, PATCH `lat`/`lng` only),
  **View details**.

### 4. Destination photo upload — `bca5d57`
- API: `POST /destinations/{id}/image` (admin, multipart field `file`).
  JPEG/PNG/WebP, 5 MB, content sniffed, daily upload cap. Stored in Cloudinary
  under `destinations/{id}`; sets `image_url`. Old image is kept.
- Admin: `lib/widgets/destination_photo_upload.dart` (`ReplacePhotoButton`,
  `replaceDestinationPhoto`). Appears in the map panel, details page and
  editor. Uses `file_picker` 13 (`FilePicker.pickFile`) and `http_parser`.
  `pickDestinationPhoto` is replaceable in tests.
- `ApiService._request` accepts `file: UploadFile` for multipart.

### 5. Add places from the map → review queue — `93c5c05`
`lib/widgets/add_place.dart` (`MapPlaceSearch`, `AddPlacePanel`, `PlaceDraft`).
- Search box: OpenStreetMap places by name within 30 km of the map center
  (`GET /admin/destination-candidates/osm/search`, radius limit now 50 km).
- **Add a place**: drop a pin for a place missing from OpenStreetMap
  (`POST /admin/destination-candidates/manual`).
- Duplicate check: `GET /admin/destination-candidates/nearby?lat&lng&radius_m`
  (destinations + staged candidates, nearest first; under 150 m shown red).
- New places are **candidates** reviewed in
  `lib/screens/destination_candidates_screen.dart`, then published.
- Migration `2026_11_16_1000`: `destination_candidates.osm_type/osm_id/osm_url`
  nullable; new `source` column (`osm` | `manual`); OSM rows keep a required,
  unique OSM identity.
- Mapbox search was rejected: Mapbox Geocoding has no POIs and Search Box
  results may not be stored.

### 6. Road trails, access paths, sea links — `659da71`
Added outside the session that wrote this file; described from its commit
message and file list, not reviewed line by line.
- API: `/admin/sea-ports` and `/admin/sea-links` CRUD
  (`app/features/sea_links/`), migration `2026_11_16_1100` adding
  `destinations.access_trail_polyline`.
- Routing (`app/features/routes/snap_policy.py`, `service.py`,
  `multimodal.py`) emits an admin-drawn access trail as a non-estimated road
  segment instead of a dashed estimate.
- Admin: `lib/widgets/admin_trail_editor_dialog.dart`, endpoint mover,
  island-group editor and live route preview in the destinations map;
  `lib/screens/sea_links_screen.dart` at route `/sea-links`;
  `lib/core/polyline5.dart`.

## Routing rules the admin data feeds (API)

- `app/features/routes/snap_policy.py`: a stop may snap to a road within
  250 m (verified arrival point), 800 m (pier) or 2 km (attraction pin or
  origin). A far snap keeps the road route and adds a dashed "last stretch"
  segment plus a warning, unless an admin access trail exists.
- `scripts/import_arrival_points.py` and `scripts/apply_pin_corrections.py`
  (dry run by default, `--apply` writes) loaded arrival points and corrected
  pins from `app/features/destinations/data/*.csv`.

## State right now

- `main` = `origin/main` = `659da71`; working tree clean.
- Live Neon database is at migration `2026_11_16_1100` (head).
- Whether Render has deployed `659da71` is not confirmed; auto-deploy did not
  fire earlier and needed a manual deploy.
- Last full test runs by the session that wrote this: admin 53 passed (at
  `93c5c05`); API full suite passed at `93c5c05` state. Tests added in
  `659da71` were not run by that session.
- `feature/admin-add-places` still exists locally and on GitHub (merged).

## Conventions and gotchas

- `services/api/AGENTS.md`: ask before code changes; no table changes without
  approval; schema changes only through Alembic.
- Run migrations on Neon **before** deploying an API that needs them; Render
  does not run Alembic.
- Do **not** run `dart format` on large existing files
  (`travel_repository.dart`, `lakbay_mapbox_widget.dart`,
  `destinations_screen.dart`): it rewraps hundreds of unrelated lines.
- `flutter pub get` rewrites `apps/admin_app/{linux,macos,windows}` generated
  plugin files with different line endings; commit them only when the content
  really changed.
- `flutter analyze` on the admin shows ~29 `deprecated_member_use` infos for
  `package:flutter/material.dart`; they predate this work.
- flutter_map reports a single tap only after the double-tap window: widget
  tests need `await tester.pump(const Duration(milliseconds: 400))` after
  `tapAt` on the map.
- Secrets live only in `services/api/.env` and Render. The traveler app's
  `.env` is bundled into the APK and must hold no server secrets
  (`apps/traveler_app/test/env_secrets_test.dart` enforces this).
- Admin tests: `flutter test` in `apps/admin_app`. API tests:
  `.\.venv\Scripts\python.exe -m pytest -q` in `services/api` (~14 minutes).

## Open items

- Decide how the hosted admin site gets built and deployed.
- Create a URL-restricted Mapbox public token for the hosted admin.
- No pin clustering on the destinations map (41 places today).
- Mount Apo permit notice in the traveler app has no contact link.
- A real photo upload against the deployed API has not been verified.
