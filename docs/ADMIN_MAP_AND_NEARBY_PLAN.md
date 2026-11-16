# Admin map, photo editing and nearby places — implementation plan

Date: 2026-11-16 · Status: Phases 1 and 6 implemented (feature/sync-and-nearby-places); Phases 2–5 proposed

## Your request, rewritten as a prompt

> **Goal:** make places easier to manage in the admin app and easier to
> discover in the traveler app.
>
> 1. **Admin — map of all places.** Add a Mapbox map to the admin
>    Destinations screen showing every destination as a pin. Clicking a pin
>    opens a side panel with the place's photo, name and key details, and
>    buttons to edit it, replace its photo, or move its pin.
> 2. **Admin — add places the catalog doesn't have.** Let an admin search
>    for a place by name (Mapbox/OpenStreetMap search), or drop a pin anywhere
>    on the map, then fill in the details and publish it as a new destination.
>    Warn when the new place is close to an existing one (possible duplicate).
> 3. **Admin — edit photos.** Let an admin upload a new photo for a
>    destination (stored in Cloudinary through the API), not only paste an
>    image URL.
> 4. **Traveler app — show nearby places.** On a trip's route map, also show
>    other catalog places near the route as smaller pins, so a traveler sees
>    what else is close by. Tapping one shows its name, photo and distance,
>    with an "Add to trip" action.
> 5. **Sync fixes.** An admin edit to fees, hours, notes or activities must
>    reach the traveler app on its next sync, and saved trips must show the
>    current pin location.
>
> **Constraints:** keep Mapbox tokens out of shipped code where possible;
> no database schema changes unless needed; tests for each part; don't
> deploy or write to the live database without asking.

## What exists today

| Area | Today | Gap |
|---|---|---|
| Admin map | `admin_map_pin_picker.dart` uses `flutter_map` with **OpenStreetMap** tiles, only inside a pick-a-pin dialog | No map of all places; no Mapbox |
| Admin destinations | Table list + editor (`destinations_screen.dart`, `destination_editor.dart`) | No map view; photo is an `image_url` text field only |
| Unrecognized places | "Destination candidates" screen with OSM lookup → review → publish (`candidate_*` in the API) | No name search on a map; no free "drop a pin" flow from the map |
| Photo upload | API has `CloudinaryStorageClient.upload_image` (used for trip memories) | No destination photo upload endpoint |
| Traveler route map | Shows only the trip's own stops, user location and piers | Nearby catalog places never shown |
| Catalog sync | `refreshFromApi` replaces a place only if name/pin/photo/description/price/island/visit length changed | Fee, hours, notes, activities edits skipped within a session; saved trips keep old stop coordinates |

## Plan

### Phase 1 — Sync fixes (traveler app, small)
- `refreshFromApi`: always replace a catalog place with the API version (or
  compare every field), so any admin edit lands on the next sync.
- When a saved trip's stop has a `destinationId`, show the catalog's current
  coordinates for its map pin (route requests already use the server's).
- Refresh the catalog when the app returns to the foreground if the last sync
  is older than ~15 minutes.
- Tests: fee-only edit is applied on sync; a moved pin shows on a saved trip.

### Phase 2 — Mapbox base map in the admin app
- Switch admin map tiles from OSM to Mapbox (`flutter_map` with the Mapbox
  Styles tile URL). Keep the OSM tile URL as fallback when no token is set.
- Token: a **public** `pk.` Mapbox token passed at build time
  (`--dart-define=MAPBOX_PUBLIC_TOKEN=...`), restricted in the Mapbox account
  to the admin site's URL. Never the server's secret token.
- Shared `AdminMapView` widget used by the picker dialog and the new screen.

### Phase 3 — Admin "Map" view of all destinations
- Add a List / Map toggle on the Destinations screen.
- Map: a pin per destination (photo thumbnail markers, clustered when zoomed
  out), Davao Region outline, filters reused from the list (category,
  province, active/inactive).
- Click a pin → side panel: photo, name, district, category, route endpoint
  status, and buttons **Edit**, **Replace photo**, **Move pin** (drag, then
  Save / Cancel through the existing PATCH).
- Route endpoints shown as small secondary markers with a line to their pin.

### Phase 4 — Add unrecognized places from the map
- Search box on the map. The **API** proxies the search (new
  `GET /admin/places/search?q=`), using the existing OSM lookup and, if
  wanted, Mapbox Search with the server token. The admin app never holds a
  secret token.
- **Licensing note:** Mapbox's standard (temporary) geocoding results may not
  be stored permanently; saving them into the catalog needs Mapbox's
  permanent geocoding. OpenStreetMap results can be stored with attribution.
  Recommendation: use Mapbox search to *find* the spot and OSM for the stored
  coordinates, or enable permanent geocoding.
- "Drop a pin" mode: click anywhere → opens the destination editor prefilled
  with coordinates (and name/district if search found them).
- Duplicate guard: warn when an existing destination is within 500 m or has a
  similar name.
- New places go through the existing candidate review → publish flow, or
  straight to a destination for admins (your choice; see decisions).

### Phase 5 — Destination photo upload
- API: `POST /destinations/{id}/image` (admin only, multipart), reusing
  `read_validated_image` + `CloudinaryStorageClient.upload_image` into a
  `destinations/{id}` folder; sets `image_url`; deletes the old Cloudinary
  image only if it was uploaded by this endpoint.
- Admin: "Replace photo" in the map panel and editor, with preview, size/type
  checks matching the API's limits.
- Traveler app picks up the new photo on its next catalog sync.
- Tests: API upload with a fake storage client; admin widget test for the
  upload flow.

### Phase 6 — Nearby places on the traveler route map
- From the in-app catalog (`repo.allTrips`), pick places within ~10 km of any
  trip stop (or ~3 km of the route line), excluding the trip's own stops;
  cap at ~15, nearest first.
- Draw them as smaller, muted pins under the trip pins; hidden below a zoom
  level to avoid clutter; a "Show nearby places" toggle in the map controls.
- Tap → card with photo, name, distance from the nearest stop, and
  **Add to trip** (uses the existing trip-builder / optimize flow, which then
  re-plans the route).
- Works offline from the bundled catalog; no new API needed.
- Tests: nearby selection (radius, exclusion, cap); widget test that nearby
  pins render and "Add to trip" adds the stop.

### Phase 7 — Verification
- Admin: `flutter test`; manual check in Chrome against the Render API.
- Traveler: `flutter test`, new APK, check on the TECNO phone.
- API: `pytest`.

## Suggested order
Phase 1 → 6 first (traveler-visible, no new services), then 2 → 3 → 5 → 4.

## Decisions needed
1. **Admin hosting:** the Render admin site publishes `build/web`, which is
   not in the repo. Should Render build it (add a build command), or do you
   upload builds yourself?
2. **Mapbox public token for admin:** create a URL-restricted `pk.` token for
   the admin site, or keep OpenStreetMap tiles in admin?
3. **Search provider for new places:** OSM only (free, storable) or Mapbox
   Search with permanent geocoding (paid)?
4. **New places from the map:** publish straight to destinations, or go
   through the candidate review queue first?
