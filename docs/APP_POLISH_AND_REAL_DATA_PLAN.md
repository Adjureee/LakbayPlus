# Real data, working routes, commuter directions, uploads, notifications and a smoother app

Date: 2026-11-17 · Status: **proposed, nothing implemented** · Based on `main` at `c8d0172`
Follows `docs/AI_CHAT_ITINERARY_PLAN.md` and `docs/AI_CATEGORIES_AND_COLLAB_PLAN.md` (both implemented and merged).

Evidence below comes from the code and from read-only queries on the live database. Nothing was changed.

---

## 1. The request, restated (the improved prompt)

The original message was one long paragraph with about twenty asks. Here it is as groups with a clear result for each ("done when"), and the places where I had to guess are marked **(assumed)**. Please correct any guess.

### A. Discover and Explore
1. **No hidden party size.** A trip started from Discover must not assume 2 travelers. Done when: the app shows no traveler count until the traveler enters one.
2. **Pull to refresh.** Replace the sync button with a smooth pull-down refresh (a spring animation, the catalog updates, the list never jumps). Done when: pulling down refreshes with one smooth animation and the button is gone.
3. **Remove "PHP" from Discover (assumed):** the currency picker and the "PHP" labels. Done when: Discover shows no currency selector and no "PHP" text; amounts keep the ₱ sign.
4. **Suggested routes work and look good.** Done when: every suggested route opens, loads its real places, and shows an honest summary (places, distance from the traveler's position, time).

### B. Real data only (nothing hard-coded)
5. **Weather is real.** Done when: every temperature and icon comes from the forecast service for that place and date; where no forecast exists the screen says "Forecast available within 5 days of travel".
6. **"Handpicked Davao Region Stays" are real.** Done when: stays come from the accommodations in the admin database, with their real price, or "Price not listed"; a place with no stays says so.
7. **Day-by-day and stay transit are real.** Done when: every leg shows a distance and time from a routing service or a catalog record (a transport rate, a sea link), labelled estimate or verified, and none comes from a typed-in list.
8. **"Region XI Route" starts where the traveler is.** Done when: the distance and time run from the traveler's current location (or chosen starting place) to the first stop and between stops; a single place never shows 0 km.

### C. Map and directions
9. **Private car, Public transit and Walking all work on the map**, each with its own route, distance, time and (for public transit) cost.
10. **Road trails are available** for the places that have an access trail, and the map says plainly when a place has none.
11. **New feature from your photo: commuter directions** (see section 4): Drive and Commute side by side, step-by-step directions (for example Jeepney, then Tricycle, then the community fee), fares and times, "Start" and "Add to plan".

### D. Uploads and export
12. **Cloudinary uploads work** for trip memories and for the profile photo.
13. **PDF export works** for any trip, signed in or not, online or off.

### E. Onboarding and account
14. **Preferences are asked in onboarding** (nature, beaches, culture, resorts and the nature questions), and saved.
15. **Explain and fix the sudden sign-in after clearing data.**
16. **Remove the "Age-Weighted Split (50% Child)" description** from expenses.

### F. Notifications
17. **Notifications work for invitations and for everything else that needs them** (tasks, expenses, trip changes), including when the app is closed, and tapping one opens the right place.

### G. Quality
18. **Make the whole app smooth and fluid** (transitions, scrolling, loading states, no jank).
19. **Verify every feature works** with a written check list, run on a phone.

---

## 2. Findings

### A. Discover and Explore
| Item | What I found |
|---|---|
| 2 travelers | `ItineraryTrip` defaults `adults = 2` (and reads `?? 2` in three places); the Explore plan sheet starts `_travelers = 2` (`explore_screen.dart:1938`); trip detail then shows "N pax". Nobody typed 2. |
| Refresh | Discover has a sync icon button (`explore_screen.dart:276`) and no pull-to-refresh. Memories already uses `RefreshIndicator`, so it is inconsistent. |
| "PHP" | A currency picker (`PHP, USD, EUR…`, line 328) and a "Budget per trip, PHP" field (line 1813). |
| Suggested routes | Loaded from the server (`_suggestedRoutes`); a tap pre-fills the trip tray with the first places. The summary line does not use the traveler's position. |

### B. Hard-coded data that is still in the app
- **Invented weather:** `wmoCycle = [1, 2, 0, 2, 3, 80, 1, 2]` (`travel_repository.dart:3578`) assigns a fake weather code to each city guide in turn. The old waypoint library also stores a temperature and weather code for every stop.
- **Invented stays:** `_buildDavaoHotels` (line 5256) fabricates two or three hotels for any place: "{city} Eco Lodge & Resort Stay", a 9.2 rating, "$65 per night", partner "Region XI Estimate". The screen calls them "Handpicked Davao Region Stays". The real catalog has **14 stays across 13 places** (of 49 places).
- **Invented transit:** the same builder holds typed-in strings such as "Sasa Wharf Ferry to Samal • 15m", "Drive to Sasa Wharf • 25m", "Flight to DVO Airport • 1h 55m".
- **Region XI Route distance:** `MapboxService.calculateRouteDistanceKm(waypoints)` is a **straight line between the trip's stops**; the traveler's position and real roads are not used. One stop gives 0 km (`trip_route_map_screen.dart:589, 790`).

### C. Map, trails and commute
- **No travel-mode switch on the map screen.** There is a saved `preferredTravelMode` but the map has no private car / public transit / walking control.
- **Road trails:** **0 of 49 places have an access trail line** (`access_trail_polyline`), so "road trail not available" is true for every place. Only 19 have a verified arrival point.
- **Commute data:** only **12 of 49 places** have any transport record, and those are 5 vans, 3 buses, a taxi, a ferry, a boat and a private car. There are **no jeepney or tricycle records and no multi-step commute at all**. 15 places have "how to get there" text and 2 sea links exist. The server estimates public transport with a straight line at a fixed speed.
- **The screen in your photo does not exist in the app.** The words "Approximate path", "commuter guide" and "Pay the local community fee" appear nowhere in the code, so this is a new feature that also needs new data.

### D. Uploads and PDF
- **Production has 0 saved memories.** No memory upload has ever completed. In contrast, 41 places have Cloudinary photos uploaded by admins, so the server's Cloudinary connection works. The app's multipart upload was fixed during Phase 5 and is deployed now, but it has not been proven on a phone.
- **The profile photo cannot be uploaded from the app.** The camera icon on the profile photo does nothing, and the app has no avatar upload call, although the server endpoint `/users/me/avatar` exists.
- **PDF export** needs a signed-in, cloud-saved trip. Anything else shows a banner, and any failure shows "PDF report unavailable right now" with no reason. Trips that are only on the phone, and offline use, get no PDF.

### E. Sign-in after clearing data
- The app does **not** sign in silently at launch; the only sign-in call is the "Continue with Google" button (`signInWithGoogleBackend`).
- The likely cause: Google remembers that this app was already approved on the phone's Google account, **outside the app's data**, so "Continue with Google" signs in instantly with no account picker. The server then finds the existing account, or creates one if there is none, with no register step. Clearing app data cannot undo either.
- Not yet reproduced: this needs `pm clear` on a phone, which signs you out and deletes local data, so I will only do it with your OK.
- The Android manifest also leaves Auto Backup at its default (on), which can restore saved app data after a reinstall.
- **Age-weighted split:** the text is in `trip_management_sheets.dart:924-933`.

### F. Notifications
Already built: the server creates notifications for invitations, tasks, expenses and trip changes; the app polls every 60 seconds; push (Firebase) is deployed and the TECNO phone has the build that registers a device. Not yet proven: a push actually arriving on a phone. Tapping a push opens the Trips tab only; it does not open the specific trip, task or invitation.

### G. Smoothness
Unmeasured. Large lists use `ListView` and several screens rebuild whole trees on each change (the repository notifies everything at once). No frame-time measurements exist. Phase 7 below starts with a profile run.

---

## 3. Target design

### 3.1 No hidden defaults
Traveler count, days and budget are asked once, shown, and stored; nothing starts at 2. Trips from Discover show "Travelers: not set" until entered.

### 3.2 Real weather
The forecast service (already on the server) is the only source. A place or day beyond its horizon (5 days) shows "Forecast available within 5 days of travel" and nothing else. City guides get their weather from the same service for the traveler's chosen date, or none.

### 3.3 Real stays
Stays come from `accommodations` (name, room type, price, unit, capacity, description). A place with none shows "No stays listed yet" and a link to search nearby places that have one. The admin app gets a clear stays editor so the catalog can grow. The fake builder and its "partner" text are deleted.

### 3.4 Real routing, from where the traveler is
- One routing service (`RouteService`, already on the server with a provider and a straight-line fallback) answers every leg: start to first stop, then stop to stop.
- The start is the traveler's current location, or the starting place they chose, or the first stop if neither is known.
- Each leg is labelled **Verified** (road route), **Estimate** (provider unavailable) or **Catalog** (a transport rate or sea link).
- **Private car, Public transit and Walking** are a segmented control on the map, each calling the route service with its mode. Public transit uses the commute data from section 4; where there is none it shows the catalog's van/bus rates or "Commute details not listed yet".
- **Road trails:** drawn from `access_trail_polyline` where it exists. Admins already have a trail editor; adding trails for the most visited places is a data task listed in Phase 3.

### 3.3b Day-by-day transit
Every day's legs come from 3.4. The typed-in waypoint library and `generateCustomTrip` templates are deleted; what remains is built from the picked places and real legs only.

---

## 4. New feature from your photo: commuter directions

What the photo shows: for one place, **Drive (82.7 km, 1 h 34 min)** and **Commute (about 45 min, 1 transfer, ₱100 per person)** cards; an **approximate path** on a map; **Directions** with numbered steps (**Public Jeepney**, get off at Bemwa Farm, 35 mins, ₱40, then **Tricycle**, get off at Entry Gate, 10 mins, ₱30, then **Pay the local community fee**, ₱30); the note "From the commuter guide. Fares and times are estimates."; a **Start** button and an **Add to plan** button.

### 4.1 Data (needs a database change and your approval)
A new table `commute_routes`, one row per way to reach a place: destination, optional start area (for example "Davao City Proper"), total time and fare (computed from the steps), source, last verified date, `is_verified`. A child table `commute_steps` in order: vehicle (jeepney, tricycle, habal-habal, van, bus, ferry, walk, fee), from, to, "get off at", minutes, fare, charging unit (per person, per trip), notes. A fee step (for example "Pay the local community fee") has an amount and no distance.

### 4.2 Admin
A "How to get there" editor on the place (like the sea-link editor): add steps, fares, times, a source link, and a Verified toggle. The admin can paste the existing "how to get there" text and press **Draft steps**: the AI drafts structured steps from that text only (prompt below), and a person must review and verify before it is shown to travelers as verified.

### 4.3 API
`GET /destinations/{id}/commute?from_lat=&from_lng=` returns the Drive option (from the route service) and each commute option with its steps, totals, flags (verified or estimate) and the last verified date. It never invents a missing step or fare.

### 4.4 Traveler app
A new screen matching the photo: the map with the approximate path, **Drive** and **Commute** cards (the selected one highlighted), the numbered **Directions**, **Start** (opens turn-by-turn in the phone's map app for the drive leg, and a step-by-step checklist for commute steps) and **Add to plan** (adds the place and the chosen mode to the plan). Where a place has no commute data the Commute card says "Commute details not listed yet. Drive time shown." It is reachable from every place card and from the route map.

### 4.5 Data readiness
Today only 15 places have any "how to get there" text and none have steps, so the first release will have Commute for **a handful of places**. Phase 4 includes an entry pass (AI draft, then human verification) for the places with text, and the screen is honest about the rest.

---

## 5. Improved prompts

### 5.1 Draft commute steps from existing text (admin only; a person verifies the result)
```
You turn one place's "how to get there" notes into structured commute steps.
Use ONLY the notes below. Do not add vehicles, stops, fares or times that the notes
do not state. If the notes give no fare or time for a step, set it to null.
Return exactly one JSON object, no markdown:
{"routes":[{"start_area":string|null,
  "steps":[{"vehicle":"jeepney|tricycle|habal_habal|van|bus|ferry|walk|fee",
            "from":string|null,"to":string|null,"get_off_at":string|null,
            "minutes":int|null,"fare_php":number|null,
            "charging_unit":"per_person|per_trip|null","notes":string|null}]}],
 "unclear":[string]}
Put anything ambiguous in "unclear" instead of guessing.
Place: {name}, {district}
Notes: {how_to_get_there}
```

### 5.2 Itinerary prompt rule (transit and weather)
```
Each stop's travel `leg` (distance, minutes, mode, fare) is given in `legs` and comes
from routing or the catalog. Copy it; never compute, round up or invent a leg.
Weather is given in `forecast` per day when it exists. If a day has no forecast, say
nothing about the weather for that day.
When a stay is needed, choose only from `stays`; if `stays` is empty write that no stay
is listed. Never name a hotel that is not in `stays`.
```

### 5.3 The restated request, as a reusable brief (for future work)
```
Goal: <one sentence>.
Where: app screen(s) / API endpoint(s).
Done when: <observable result a person can check>.
Data: <where the facts come from>; if missing, show "not listed", never invent.
Not in scope: <what to leave alone>.
```

### 5.4 Notification copy (short, specific, with the action)
| Event | Title | Body |
|---|---|---|
| Invitation | Trip invitation | "{name} invited you to {trip}. Tap to accept." |
| Accepted / declined | Invitation answered | "{name} accepted your invitation to {trip}." |
| Task assigned | New task | "{name} assigned you: {task}." |
| Expense | New expense | "{name} added {title}, ₱{amount}." |
| Trip changed | Trip updated | "{name} changed {what} in {trip}." |

---

## 6. Implementation plan

Each phase ends with tests and a commit on its own branch. Order matters.

### Phase 1: Quick fixes (no database change)
- Remove the assumed party size (3.1); remove the currency picker and "PHP" labels from Discover; remove the age-weighted split text.
- Pull-to-refresh on Discover with a smooth animation; delete the sync button.
- Preferences step in onboarding (reuse the Settings preference groups and the nature questions) saved to the account.
- Suggested routes: real summary from the traveler's position, loading and empty states.
- Sign-in after clearing data: reproduce on a phone (with your OK), then show the Google account picker every time ("choose account"), disconnect on sign-out, and ask "Create a new account?" with a confirmation when Google sign-in would register someone new; set Android backup rules so the sign-in is never restored.
- Tests for each.

### Phase 2: Real weather and real stays
- Delete `wmoCycle` and every stored temperature; weather only from the forecast service, with the "within 5 days" message.
- Replace `_buildDavaoHotels` with accommodations from the API, "Price not listed" and "No stays listed yet"; rename the section ("Stays from the Lakbay catalog").
- Admin: a stays editor.
- Tests: no stay or temperature appears unless it came from the API.

### Phase 3: Real routing from where you are
- Replace the straight-line "Region XI Route" with route-service legs from the traveler's position; verified/estimate/catalog labels.
- Segmented control for Private car, Public transit and Walking on the map and in the plan; each mode uses its own route and cost.
- Remove the typed-in waypoint library and `generateCustomTrip` templates; every day's transit from real legs.
- Road trails drawn where present; "No trail for this place" otherwise; admin data task to add trails for the top places.
- Tests: one place gives a non-zero distance from the traveler; each mode changes the route; no typed transit string remains.

### Phase 4: Commuter directions (database change, needs approval)
- Migration: `commute_routes` and `commute_steps`.
- API: the commute endpoint; admin CRUD and the AI "Draft steps" (prompt 5.1) with verification.
- Admin: the "How to get there" editor.
- App: the new screen from the photo; "Start" and "Add to plan".
- Data entry pass for the 15 places that have text.
- Tests: totals from steps, missing fare shown as not listed, verified vs estimate flags, screen states.

### Phase 5: Uploads and PDF
- Memories: prove the upload on a phone, show the exact error on failure, keep the outbox.
- Profile photo: tap the camera, pick, crop, upload through `/users/me/avatar`, show progress.
- PDF built on the phone from the itinerary, stays, legs, costs and weather (works unsigned and offline); the server PDF stays as an option for saved trips; real error messages.
- Tests: upload success, refusal, offline retry, avatar, PDF content.

### Phase 6: Notifications end to end
- Prove push on two phones (invite, accept, task, expense); a real `Open` target for each event type (a trip, the Collaborate sheet on Tasks, the invitation card); copy from 5.4; a notification center with unread, filters and "mark all".
- Tests for routing and copy.

### Phase 7: Smooth and fluid
- Start with a **profile run** (frame times on Discover, the map, Trip detail, the chat) and fix what it shows.
- Narrow rebuilds (split what the repository notifies), image caching and sizing, list virtualization, skeleton loading, consistent page and sheet transitions, no layout jumps.
- A written budget (for example, no frame above 16 ms on scroll).

### Phase 8: Verify everything
- A written check list of every screen and action, run on the two phones, with the result recorded in this file. Fix what fails.

Suggested order: **1, 2, 3, 4, 5, 6, 7, then 8.** Phase 1 and 2 give the most visible honesty fixes quickly; Phase 3 and 4 depend on data.

## 7. Decisions needed

1. **Database change for Phase 4** (`commute_routes`, `commute_steps`): approved? (Required by `AGENTS.md`.)
2. **"Remove the PHP in the discover page":** remove the currency picker and "PHP" labels, keeping ₱ amounts? Or remove prices from Discover completely?
3. **Weather beyond 5 days:** show "forecast available within 5 days" (recommended), or also show a typical-climate note from a data source you choose?
4. **Walking and public-transit routing provider:** the current route server may only drive. Use Mapbox Directions (already in the project) for walking, with a monthly request limit, or add your own routing server?
5. **Clearing data and sign-in:** may I run `pm clear` on a phone to reproduce it? (It signs you out and deletes local data on that phone.)
6. **Commute data:** who verifies the AI-drafted steps before travelers see them as "verified" (you, or an admin account)?
7. **Profile photo:** upload only, or also allow removing it?
8. **The photo:** is it from another app, a design, or an older Lakbay version? If you have more screens (the Start flow, the plan view), please send them.
