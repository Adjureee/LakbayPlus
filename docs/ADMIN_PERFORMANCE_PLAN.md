# Admin app performance — analysis and implementation plan

Date: 2026-11-16 · Status: Phases A and B implemented; C–G proposed

## What was measured

| Check | Result |
|---|---|
| Destination photos (41, all on Cloudinary) | **39.9 MB total**, largest 8.4 MB, loaded at full size |
| Same photo resized by Cloudinary to a 96 px pin | **~3 KB** (`f_auto,q_auto,c_fill,w_96,h_96`) |
| Same photo resized for the side panel (720×400) | ~65 KB |
| `GET /destinations?limit=100` | 57 KB uncompressed, **9.5 KB gzipped**; 1.6 s first call, 0.5 s after |
| Davao Region outline | 682 points — not a problem |
| Blur effects / running animations in admin code | none found |

## Causes of the lag, most important first

1. **Full-size photos as map pins.** `destinations_map_view.dart` draws each
   38 px pin with `Image.network(image_url)` on the original upload. Opening
   the Map view downloads and decodes up to 40 MB of images, several over
   5 MB, in the browser's UI thread. The side panel and details page also
   load the original.
2. **Debug mode.** `flutter run -d chrome` runs the unoptimized debug build,
   which is many times slower than a release build for map panning and long
   lists. The hosted admin has no build pipeline, so the debug run is what
   gets used day to day.
3. **Whole-list reloads.** After Move pin, Replace photo or an endpoint
   change, `destinations_screen.dart` calls `_refresh()`: the full list is
   refetched, a spinner replaces the page, and the map is rebuilt from
   scratch (camera reset, tiles and all pin photos requested again).
4. **Every screen refetches destinations.** Dashboard, Destinations and
   Market Rates each create their own `ApiService` and call
   `getDestinations()` on open; nothing is shared or cached.
5. **Heavy tiles.** Mapbox tiles are requested as 512 px `@2x`; on a normal
   screen this is four times the pixels needed.
6. **Fonts fetched at runtime.** `GoogleFonts.outfitTextTheme` downloads the
   font on first paint, delaying text.
7. **API cold start.** Render's free instance sleeps; the first request can
   take 30–60 s. This looks like a hang but is outside the admin code.

Not verified: a browser performance trace. The ranking comes from code reading
and the measurements above; item 1 is by far the largest measured cost.

## Plan

### Phase A — Right-sized images (biggest win, small change)
- New `lib/core/image_urls.dart`: `cloudinaryThumb(url, width, height)` that
  inserts `f_auto,q_auto,c_fill,w_…,h_…` after `/image/upload/` for
  `res.cloudinary.com` URLs and returns other URLs unchanged.
- Use it for: map pins (96 px), map side panel (720×400), details page
  (960×400), photo-upload preview is local so unchanged.
- Add `cacheWidth`/`cacheHeight` on those `Image.network` calls so non-
  Cloudinary images are also decoded small.
- Tests: URL rewriting (Cloudinary, already-transformed, non-Cloudinary).
- Expected: Map view image load ~40 MB → ~0.15 MB.

### Phase B — No full reload after an edit
- After Move pin / Replace photo / endpoint or trail save, replace that one
  record in the loaded list instead of refetching, and keep the map mounted
  (no spinner, camera and selection preserved).
- Keep the "Refresh" button for an explicit reload.
- Tests: moving a pin does not issue a second `GET /destinations` and the map
  stays on screen.

### Phase C — Shared destination cache
- One `DestinationsStore` (a `ChangeNotifier`) holding the list with a
  timestamp; Dashboard, Destinations and Market Rates read from it, refetching
  only when older than a few minutes or on Refresh.
- One shared `ApiService` instead of one per screen.
- Tests: opening two screens issues one destinations request.

### Phase D — Lighter map
- Request Mapbox `@2x` tiles only when `devicePixelRatio > 1.5`.
- Build pin markers once per records/selection change instead of on every
  rebuild; wrap the marker layer in a `RepaintBoundary`.
- Show the Davao outline at reduced opacity only below zoom 11.

### Phase E — Faster start
- Bundle the Outfit font as an asset and set
  `GoogleFonts.config.allowRuntimeFetching = false`.
- Show a "Waking the server…" message when the first API call takes over
  5 s, so a Render cold start is not mistaken for a hang.

### Phase F — Run and ship the release build
- Document and use `flutter run -d chrome --release` (or
  `flutter build web --release` + a static server) for daily admin use.
- Add a Render build for `lakbay-admin` (or a script that builds and uploads
  `build/web`) so the hosted admin is a release build of `main`.
  Needs your decision on hosting.

### Phase G — Same image fix for the traveler app (optional, recommended)
- The traveler app also loads original photos for thumbnails and map pins
  (`LakbayImage`, `thumbnailUrl`). Apply the same Cloudinary sizing there to
  cut mobile data and speed up Explore. Requires a new APK.

## Suggested order
A → B → F (release run) → C → D → E, then G.

## Decisions needed
1. Hosting for the admin release build (Phase F): Render build step, or a
   local build-and-upload script?
2. Include the traveler app image fix (Phase G) in this work?
