# Flagship UX plan: plain words, one front door, trust, then reach

Status: **plan only. No code changed, nothing built, nothing committed.** The backend guide (`services/api/AGENTS.md`) requires your approval before code changes, so section 8 lists the decisions I need.

Written from a first-time-traveler audit of five phone screenshots (`docs/redesign/after_*.png`, taken 17 Nov) and the current traveler code. I did not drive a live build, and competitor remarks are general knowledge, not checked live. Findings are about the screens in those screenshots, not the whole app.

## 1. What "flagship" means here

"A billion downloads" is a distribution outcome, not a design target, so it is replaced by things that can be measured on the phone:

| Goal | How it is measured | Today |
|---|---|---|
| A first-time traveler gets a useful answer fast | Taps and seconds from install to the first result cards, counted by hand on the TECNO phone | Not measured (F0) |
| One obvious way to start a trip | Number of entry points that create a trip | 4 |
| No insider wording on screen | Search of `lib/` strings for vendor and jargon words returns none in user-visible text | About 10 hits (section 3) |
| Every card is trustworthy | Share of catalog places with a photo and a known cost | Snapshot of 20 Nov (63 places): **photo 41 of 63 (65%)**, **cost known 36 of 63 (57%)**, stay or transport rate for only **13 of 63** (full table: `docs/FLAGSHIP_UX_BASELINE.md`) |
| We can see what users do | A usage and crash report exists | **None.** The app has `firebase_core` and `firebase_messaging` only: no analytics, no crash reporting |
| Answers stay correct while the UI changes | The chat accuracy checks keep passing | Offline replay passes; the live baseline (`docs/AI_STRESS_BASELINE.md`) records the known gaps |
| Stays accessible and smooth | `redesign_phase6_a11y_test`, `phase7_smooth_ui_test` keep passing; large-text check at 1.25x to 2.0x | Passing at last record |
| Healthy in the Play Console | Crash and ANR rates below Play's bad-behaviour thresholds | Not measured (needs a release build) |

## 1a. What this plan cannot guarantee, and what it does instead

No plan can ensure that an app becomes the best trip planner. What decides that is whether real travelers finish a trip plan, whether the answers are correct, whether the data is complete and current, and whether people find the app. A screen redesign alone touches only the first of those.

So the plan is built to **stop and reconsider** instead of continuing blindly. It has four additions beyond the UI work:

1. **A real-user test**, because the audit was an imagined tourist from five screenshots.
2. **Quality gates** on answer accuracy and data coverage, so UI work cannot hide weak answers or empty cards.
3. **One positioning sentence** that every phase must serve.
4. **Measurement after launch** (usage and crash reporting), because today the app reports nothing.

### Positioning (draft, for you to confirm or change)

> The trip planner that knows Davao's ferries, jeepneys and real costs, in the traveler's own language.

A change that does not strengthen this sentence, or remove friction from it, waits.

### Go / no-go gates

| Gate | Before | Must be true | If not |
|---|---|---|---|
| **G0** | F1 starts | F0 baseline is recorded; round 1 of the user test is done (section F0); the positioning line is confirmed; the section 4 branch cleanup is done | Do not start; fix the gap |
| **G1** | F2 starts | F1 merged; `flutter analyze` clean and traveler tests pass; no new failures in the offline chat replay | Fix before moving on |
| **G2** | F4 and F5 start | Round 2 of the user test: at least 4 of 5 testers finish "start a trip" without help, and taps to the first result are no worse than the F0 count | Stop and rework F2 with what the testers hit; do not add features on top |
| **G3** | F6 starts | F3 targets met (section F0 targets); analytics live for at least 2 weeks of real use | Spend the next phase on data and trust, not on reach |

## 2. Corrections to my earlier audit

- **Onboarding is not duplicated.** `OnboardingScreen` shows `YesAiOnboardingFlow` as one branch of a single wizard (`onboarding_screen.dart:145`). I withdrew it from the "remove" list.
- **The bell is one shared component** (`notifications_sheet.dart:41`) placed on Home and Trips. That is consistent, not redundant, so it stays.

## 3. Findings, each with its place in the code

**Remove or merge**

| # | Finding | Where |
|---|---|---|
| R1 | Four ways to start a trip (**corrected 28 Nov: three already go to chat; the tray sheet is a deliberate no-AI planner, so F2 became "two named doors"**): chat "Plan it", the Discover trip tray, the My Trips "+" form, the first-run wizard | `home_chat_screen.dart`, `explore_screen.dart:657`, `my_trips_screen.dart:31`, `yes_ai_onboarding_flow.dart` |
| R2 | The first trip is shown twice: a hero card and again in the list | `my_trips_screen.dart:159,270` (`heroTrip = allTrips.first`, list built from `allTrips`) |
| R3 | Repeated words: "Davao del Norte • Davao Del Norte", "TOP DAVAO PICK … TOP DA…" | Trips and Discover screenshots |

**Fix**

| # | Finding | Where |
|---|---|---|
| X1 | The vendor name is a button label and in the subtitle ("Mapbox", "Mapbox pins") | `explore_screen.dart:300,315` |
| X2 | Insider words: "Region XI", "IGaCoS", "trip tray" | `travel_models.dart:205,252,414`; `explore_screen.dart:916`; `my_trips_screen.dart:68`; `profile_screen.dart:342`; `settings_screen.dart:704,768`; `auth_screen.dart:555` |
| X3 | The Discover tab uses a video-player icon | `main.dart:267-269` |
| X4 | Category chips show developer-style counts, "Beach Resort (4)" | `home_chat_screen.dart:912,1474` |
| X5 | "Top-5 Match" does not say what it does | `explore_screen.dart:331` |
| X6 | Cards say "Cost not listed" and a travel time with no starting place | `models/travel_models.dart:1221`, `home_chat_screen.dart:2128`, `trip_detail_screen.dart:923,1030` |
| X7 | Photos repeat or do not match the place (22 of 63 without a photo on 16 Nov) | `widgets/lakbay_image.dart`, catalog data |
| X8 | Chat boilerplate reads like a system message: "from the catalog (tap + Add to plan from them)" | `travel_repository.dart:2637` |
| X9 | Deleting a trip is a bare trash icon with no undo | `my_trips_screen.dart:568` |
| X10 | Titles and placeholders are cut off | Trips and chat screenshots |
| X11 | The catalog `category` field is free text: 45 different values for 63 places, 35 used once. This is why category chips and card tags look uneven. Fix the data (a short controlled list), not the chips | `docs/FLAGSHIP_UX_BASELINE.md` section 1 |
| X12 | A Mapbox token-entry screen ships to users ("Set Mapbox Access Token"). It should exist only in a debug build. **Keep the "© Mapbox" attribution**, which the map terms require; the F1 string test must allow it | `lakbay_mapbox_widget.dart:553-626,920`, `mapbox_service.dart:51` |

**Add**: a map view of chat results (A1), a "continue your trip" card on Home (A2), offline trips (A3), a share link (A4), place ratings (A5), and a first answer before sign-in (A6).

## 4. Before starting

The working tree holds uncommitted traveler changes (`travel_models.dart`, `trip_detail_screen.dart`, `trip_route_map_screen.dart`, `route_trail.dart` and others) on `feat/cycling-traffic`. F1 touches some of the same files. Commit or merge that work first, or build in a separate worktree, so the two changes do not tangle.

Each phase ships on its own branch with the repo's usual shape: a `Plan:` commit, the step commit, then a `Merge:` commit.

## 5. Phases

Effort is S, M or L (relative size, not a time estimate).

### F0: Measure first (S to M, almost no code)
- **Screens and taps.** Fresh phone screenshots of Home, Chat, Discover, Place, Trips, Trip detail and the route map. Count taps and seconds from first launch to the first result cards. (Your phone.)
- **User test, round 1.** Five to eight real travelers on a mid-range Android phone, observed and not helped, with three tasks: (1) find a beach near you and add it to a trip; (2) plan a 2-day trip for 2 people with a budget of your choice; (3) work out how to get to a place from where they are staying. Record for each: finished or not, taps, seconds, and where they hesitated or asked a question. Do not explain the app first. (You or a helper; I write the script and the sheet.)
- **Data coverage.** Done offline from the 20 Nov production snapshot (section 1). Re-run before F3 from a fresh snapshot.
- **Measurement.** Decide on usage and crash reporting. Firebase is already in the app, so the natural choice is Firebase Analytics and Crashlytics. That adds two dependencies and changes the Play Data Safety answers, so it needs your approval (decision 8).
- **Targets (proposed):**
  - Data: photo on 100% of places shown on Home, Discover and suggested routes, and 90% overall (now 65%); a known cost on at least 90% of places (now 62%); rates added first for the most-viewed places, not all 63.
  - Answers: the offline replay (`tests/test_accuracy_replay.py`) must pass on every phase that touches chat; a live accuracy run, when wanted, follows `lakbay-ai-accuracy` (Gemini only, at most 20 calls, reported as counts).
  - Journey: taps to first result no worse than the F0 count after F2, ideally fewer; 4 of 5 testers finish "start a trip" unaided by G2.
- **F0 status (27 Nov):** data coverage, the wording baseline and the entry-point count are measured and recorded in `docs/FLAGSHIP_UX_BASELINE.md`; the user-test kit is written (`docs/FLAGSHIP_UX_USER_TEST.md`). **Open:** tap and second counts, round 1 with real travelers, fresh screenshots (all need you), and the analytics step (approved; it is code, so it is its own branch off `main`, see section 4).
- **Done when:** the section 1 table has real "today" values for the rows still marked "not measured", round 1 findings are written down in `docs/FLAGSHIP_UX_BASELINE.md`, and the plan is adjusted to what the testers actually hit (it may reorder F1 to F3).

### F1: Plain words and obvious defects (S to M)
Covers R2, R3, X1 to X5, X9, X10. No schema, no backend, no new screens.
- One word list in `lib/core/` (for example "Davao Region", "Samal Island", "Map") used by every screen, so the wording lives in one place.
- Rename the "Mapbox" button to "Map" and the subtitle to plain text; change X2 strings; rename "trip tray" to "your trip".
- Discover icon to a compass or magnifier glyph.
- Drop the `(count)` from category chips; show the count only when it helps, as a muted number.
- Merge R2: the hero card shows the next trip and the list excludes it.
- Undo for delete: swipe or trash then a snackbar with "Undo".
- Make long titles wrap to two lines instead of cutting at one.
- **Tests:** new `test/plain_words_test.dart` (a scan of `lib/` strings for the banned words), updated `redesign_phase4_nav_test`, `profile_history_abc_test` and trips tests; `flutter analyze --no-pub`.
- **Done when:** the string scan passes, no duplicated hero row, delete can be undone.

### F2: Two clearly named doors (S) — scope changed after reading the code
**Original idea:** make chat the single way to start a trip. **What the code showed (28 Nov):** three of the four paths already end in chat. The My Trips "+" form and Discover city search call `planInChat`, and the first-run wizard runs through the chat pipeline. The fourth, the Discover tray's "Plan Your Route" sheet, is a separate planner built on purpose with no AI (`isCatalogFallback`, "Lakbay Catalog Planner (No AI)"): it spends no model quota and offers pace, lock-first-stop and must-visit options. Removing it would delete the app's only no-AI planner, so R1 was overstated. **Decision (you, 28 Nov): keep both and name them by what they do.**
- **Door 1, "Plan with Lakbay AI":** the My Trips "+" sheet is titled "Plan a trip with Lakbay AI" (was "Create Davao Region Trip"), the "+" tooltip says "Plan a trip" (was "Create Trip"), and the form still hands off to chat.
- **Door 2, "Build my trip (no AI)":** in the tray sheet the main button reads "Build my N-day trip (no AI)" (was "Optimize & Create N-Day Trip") and the busy text "Building your trip..." (was "Optimizing & Refining Route..."). The second button reads "Plan it with Lakbay AI instead" (was "Improve with AI", which wrongly sounded like editing an existing trip). The sheet subtitle says "Build it yourself, or let Lakbay AI plan it".
- Both doors end on the trip screen (the tray pushes `TripDetailScreen`; a chat plan opens the same screen from its trip card).
- **Tests:** `test/two_doors_test.dart` (new, My Trips hand-off), the tray labels asserted in `trip_builder_flow_test.dart`, and `phase2_catalog_planner_fallback_test.dart` updated for the renamed button.
- **Not done, on purpose:** removing the "+" form or the tray sheet. Revisit only if user-test round 1 shows people are confused by having two doors.
- **Done when:** both doors are named by what they do and neither uses jargon ("Optimize", "Improve with AI" for planning).

### F3: Trust: prices and photos (M, needs data work)
Addresses X6, X7, X8. **Status (28 Nov): built on `feat/ux-f3`, one item deliberately not done.**
- **Photos (X7), done.** The code showed the cause: any place without its own photo got `davaoBackdropAssetFor`'s loose keyword guess, and anything unmatched got People's Park's photo (e.g. "Huyong-huyong Nature Park" got Eden's, "Pyalitan Falls" got Aliwagwag's). Cards also fell back to the home background. Now `ownPhotoAssetFor` matches only the 10 places that are a bundled photo's own subject, and everything else shows `PlacePhotoPlaceholder`, an illustration tinted for the kind of place (`lib/core/place_kinds.dart` reads the free-text category). The loading state no longer flashes a regional photo either.
- **Travel time (X6, part), done.** "~34 min" now reads "~34 min from Tubaon" (`repo.travelTimeLabel`).
- **Chat boilerplate (X8), done.** "Here are top Beach Resort spots from the catalog (tap + Add to plan from them):" is now "Top Beach Resort places. Tap + Add to start a trip with them."
- **"Cost not listed" (X6, part), NOT done, on purpose.** The plan wanted a next step (ask the place or open its page), but the catalog has no website or phone field, so any such action would be invented. The wording is also set by the server (`recommendations/service.py:1387`), and backend changes need your approval. The real fix is data: 27 places have no known cost (list in `docs/FLAGSHIP_UX_BASELINE.md`), and a future "Suggest a price" feature would give travelers a real action.
- **Known gap:** trips already saved on a phone keep the photo they were saved with, so some old saved trips can still show a regional photo.
- **Data work still yours:** 22 places need a photo and 27 a cost (admin app). The placeholder is the honest fallback until then.
- **Done when:** no new card shows another place's photo (met, by test) and the data targets in section 1 are reached (not met: needs admin data entry).

### F4: A Home that rewards the return visit (S to M)
Addresses the empty lower half of Home (A2). Show a "Continue planning" or "Your next trip" card when a trip exists, and a short "Popular this week" row from the existing popularity data.
- **Done when:** Home has no dead space at 1.0x and 1.25x text, and a returning user reaches their trip in one tap.

### F5: Map-first results (M to L)
A1: a "Show on map" action on a set of chat cards, reusing the existing `LakbayMapboxMap` widget and its road, sea and estimate styling.
- Follows the invariants in the `lakbay-routing-geo` skill (no invented geometry, labelled estimates).
- **Done when:** a card set opens a map with the same pins, and each pin opens its card.

### F6: Reach: research spikes, no commitment (L, each needs its own approval)
- **Offline** (A3): saved trips already restore without a routing request; measure what still needs a network and propose offline map tiles only if the numbers justify it.
- **Share link** (A4): needs a new public endpoint and page, which is a backend and privacy decision.
- **Ratings** (A5): the backend has a `reviews` feature; find out what the app already uses before adding anything.
- **First answer before sign-in** (A6): the guest chat endpoint exists; measure the current first-run path in F0 before changing it.

## 6. Order and dependencies

The gates in section 1a apply. F0 first. F1 can start after G0 (including the section 4 cleanup). F2 follows F1 (shared wording and tests). F3 can run in parallel with F2 because it touches cards and data, not creation flows. F4 and F5 after F2. F6 only after F0 numbers.

## 7. How we will know it works

- **Automated:** `flutter analyze --no-pub` is clean and `flutter test --no-pub -j 2` passes in `apps/traveler_app` for every phase (follow the `lakbay-verify` skill for exact commands and reporting). Backend tests only where a phase touches the API.
- **On the phone:** before and after screenshots per phase, in the style of `docs/redesign/`, and the taps-and-seconds count from F0 repeated after F2. I cannot do this part; it needs your phone.
- **Not claimed:** nothing here predicts downloads or ratings. It removes known friction.

## 8. Decisions needed

1. **Start order. Recommended:** F0, then F1, then F2, then F3.
2. **One front door. Recommended:** chat is the single way to start; the My Trips "+" form and the tray hand off to it. Alternative: keep the form as a structured option and remove the tray's own builder instead.
3. **Wording. Recommended:** "Davao Region" and "Samal Island" everywhere. "Region XI" and "IGaCoS" stay only on the About page.
4. **Placeholder photos. Recommended:** illustrated per-category placeholders, with real photos added through the admin app.
5. **"Top-5 Match" (X5).** I do not know what it does for a user. Tell me its purpose and I will name it; otherwise F1 leaves it unchanged.
6. **Worktree. Recommended:** build in a separate worktree so the uncommitted cycling work stays untouched.
7. **Positioning line (section 1a).** Confirm the draft or write your own; it becomes the test for what gets built.
8. **Analytics and crash reporting. Recommended:** Firebase Analytics and Crashlytics (already in the Firebase project). It adds two packages and changes the Play Data Safety form. Alternative: no analytics, which leaves F6 and the gates after G2 without evidence.
9. **Who runs the user test. Recommended:** you recruit 5 to 8 travelers (friends, classmates and local tourists all count); I write the task script and the results sheet.
10. **Data targets.** Confirm 100% photos on shown places, 90% overall, and 90% known cost, or set your own. Someone with admin access has to enter the missing data; the admin editors for photos and prices already exist.
