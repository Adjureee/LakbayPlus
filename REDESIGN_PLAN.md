# Lakbay+ Redesign Plan (v8)

**Goal:** rebuild the traveler app to the v8 design (dark teal and mango), fix the UX bugs found in the study, and bring the admin app into the same family. Everything should stay honest about what the AI and the data can actually do.

- **Reference design:** `.impeccable/mocks/v4/v8.html` (render: `v8.png`). It has four screens: Welcome, Trips home, Chat, Trip live day.
- **Product rules:** `PRODUCT.md`. Key rules: AI only, no invented ratings or counts, wordmark only, no sparkle icons, WCAG AA, 48dp targets.

The plan has seven phases, done in order. Each phase ends with something you can run and show.

---

## Phase 0: Safety net (small) ✅ done

> Done 2026-11-17. Git initialized with a baseline commit (`.env` files and local `.pgdata` excluded). Baseline: `flutter analyze` clean, 124 traveler tests passing.

The project folder is **not a git repository** today, so nothing can be reviewed or undone.

1. Run `git init` and make a first commit of the current state. Each phase then becomes its own commit, so any step can be rolled back before the defense.
2. Record a baseline: `flutter analyze` and `flutter test` in both apps, plus a screenshot of each current screen for before/after slides.

## Phase 1: Design system (medium) ✅ done

> Done 2026-11-17.
> - **Code:** `lib/design/`. Tokens are in `lakbay_tokens.dart`, type in `lakbay_type.dart`, the theme in `lakbay_design_theme.dart`, and shared widgets in `widgets/`. Import everything with `design/design.dart`.
> - **Tests:** `test/design_system_test.dart` (21 tests) covers AA contrast for every text color pair, 48dp targets, screen-reader labels, motion off, confirm and undo, the snackbar sitting above the tab bar, and the preview at 1.0× and 1.3× text without overflow.
> - **Live gallery:** in debug builds, open `/#/design-preview`.
>
> **Changes from the original plan:**
> - **The app-wide theme switches in Phase 4, not here.** The old screens hard-code the light palette (for example `LakbayColors.tealDeep` 212 times, often on white cards), so flipping the whole app to dark now would leave unreadable text. Each screen moves to `LakbayDesignTheme.dark` as it is rebuilt. The old `theme/lakbay_theme.dart` is deleted once the last screen has moved.
> - **Fonts:** at first these loaded at runtime. They have been bundled since Phase 2 (see below).
> - **The tab bar goes in `Scaffold.bottomNavigationBar` with `extendBody: true`,** so snackbars sit above it and scrolling content gets the right bottom padding automatically.

This is the foundation. Every later phase uses it.

The traveler app currently has **two theme files** (`lib/theme/lakbay_theme.dart` and `lib/core/theme/app_theme.dart`), **three fonts** (Outfit, FigGrotesk, Inter) and **98 hardcoded `Color(0x…)` values**. All of these go into one system.

**New folder: `apps/traveler_app/lib/design/`**

| File | Contents |
|---|---|
| `lakbay_colors.dart` | `bg #04191C`, `s1 #0A2A2F`, `s2 #0F353B`, `s3 #15434A`, `stroke white 9%`, `text #EAF4F3`, `muted #8FB0AD`, `mango #FFB547`, `mangoInk #2A1900`, `lagoon #2CC5BC`, `danger #FF5A4F`, budget colors (stay/food/rides/entrance) |
| `lakbay_type.dart` | Bricolage Grotesque for display, titles and big numbers; Manrope for body, labels and buttons. One `TextTheme`; tabular numbers for prices and times |
| `lakbay_spacing.dart` | 4-pt scale, radii (10 / 14 / 20 / 26 / 30), elevation shadows |
| `lakbay_motion.dart` | Durations and curves, plus `LakbayMotion.of(context)`, which returns zero durations when `MediaQuery.disableAnimations` is on |
| `lakbay_theme.dart` | One `ThemeData` (Material 3, dark `ColorScheme` built from the tokens) with component themes for buttons, inputs, chips, sheets, snackbars and dialogs |

**Fonts:** bundle Bricolage Grotesque and Manrope as `.ttf` under `assets/fonts/` instead of loading them at runtime through `google_fonts`. That way the defense demo works offline and the first frame doesn't flash the wrong font. Remove Outfit, FigGrotesk and Inter.

**Shared widgets (`lib/design/widgets/`), each with built-in semantics and a 48dp minimum:**

| Widget | Purpose |
|---|---|
| `LkButton` | Primary (mango), secondary (s2), text; optional icon; loading state |
| `LkIconButton` | 48×48, rounded square, glass or solid variant, required `tooltip` (doubles as the screen reader label) |
| `LkGlassChip` | Blurred chip for use over photos (dates, people, price) |
| `LkPhotoCard` | Full-bleed photo with gradient and title, `CachedNetworkImage` or asset, placeholder and error states |
| `LkSectionHeader` | Title plus an optional "See all" action |
| `LkFloatingNavBar` | Floating 5-tab bar with mango pill on the active tab, built on `NavigationBar` semantics |
| `LkStickyActionBar` | Bottom action area with fade (Directions, Add to trip, Save) |
| `LkWarningRow` | Mango-tinted warning with one fix action ("Move earlier") |
| `LkEmptyState`, `LkErrorState`, `LkSkeleton` | One look for loading, empty and failed states on every screen |
| `showLkConfirm()`, `showLkUndoSnack()` | Confirmation sheet for destructive actions, and a snackbar with Undo |

**Done when** (now checked at the end of Phase 4): the app builds on the new theme, no screen imports the old theme files, and `grep "Color(0x" lib/screens` returns nothing.

## Phase 2: Brand cleanup (small) ✅ done

> Done 2026-11-17.
> - **Compass mark removed everywhere.** That covers the widget, the SVGs and the PNG in both apps. Its users now show:
>   - the name-only wordmark (Bricolage, mango "+")
>   - an "L+" tile for Lakbay AI in the traveler app
>   - an "L+" monogram in the admin login and sidebar
> - **All 11 sparkle icons replaced,** with chat, sort, review and hourglass icons, along with the ✦ and ✨ glyphs in text.
> - **Invented claims removed from onboarding:**
>   - "Your travel expert makes it", "No fees", "24/7 Davao care"
>   - "1M+ Trips planned", "50k+ 5 star reviews"
>   - the "Carla" and "Aleks, travel expert" testimonials
>   - the stock-photo faces
>
>   They are replaced by short, true descriptions of what the product does. Sign-in no longer mentions a travel expert.
> - **Trip tips:** shown as plain "Travel notes" from the catalog, not as a quote with an avatar. The `assets/experts/` photos and the model's default expert photo are deleted.
> - **Splash:** the Android splash (including Android 12+), the Flutter loading screen and the web manifest now use deep teal `#04191C`.
> - **Fonts bundled now, not in Phase 7:** Manrope 400–800 and Bricolage 800 are in `assets/google_fonts/`, hash-checked against Google Fonts, with their OFL licenses on the app's licenses page. `test/flutter_test_config.dart` preloads them for tests.
> - **Launcher icon:** the hand-drawn "LAKBAY+" bus artwork stays; this is the owner's decision. The "L+" proposal is kept for reference in `.impeccable/mocks/icon/`.

1. **Retire the compass/star mark.** Delete `widgets/brand/lakbay_compass_mark.dart`, `assets/brand/lakbay_mark.svg` and `assets/images/lakbay_logo.png`, then fix their users:
   - traveler `main.dart`, `theme/lakbay_theme.dart`, `lakbay_wordmark.dart`, `lakbay_ai_avatar.dart`
   - admin `login_screen.dart`, `sidebar.dart`
2. **Wordmark:** "Lakbay" in white plus a mango "+", set in Bricolage 800.
3. **AI avatar:** a small rounded square with "L+" in mango on `s3`, as in the v8 chat.
4. **No sparkles:** replace all **11** `Icons.auto_awesome` uses with chat or forum icons, or use no icon.
5. **No fake expert.** `ItineraryTrip` has `expertName`, `expertAvatarAsset` and `expertTip`, used in **13** places on screens. Show the tip as "Lakbay tip" with no person, name or avatar. The model fields can stay for API compatibility, renamed later.
6. Splash screen in `bg #04191C`. The launcher icon keeps the bus artwork (owner's decision).

## Phase 3: UX and honesty fixes (medium) ✅ done

> **What was built (2026-11-17)**
> - **Trip dates:** `ItineraryTrip` has `startDate`/`endDate`, read from and sent to the API's `start_date`/`end_date` (create, from-AI-option, update, sync). A chat plan takes the date the traveler gave in chat. `lib/models/trip_timing.dart` works out Upcoming, Ongoing, Past or Undated, a relative label ("In 5 days", "Day 2 of 3", "Ended") and a range ("Dec 4 – 6").
> - **Adding dates:** Trip detail opens with a "Trip dates" row; picking the first day sets the last day from the day count.
> - **My Trips:** filters are All, Upcoming (includes trips happening now), No dates and Past. The featured card is the trip happening now, else the next one; its badge is the real relative label, or none. The create sheet has a vibe picker ("Any vibe" by default) in place of the hardcoded "Island Hopping & Highlands".
> - **Deletes:** trips and memories ask first (`showLkConfirm`), then show "Deleted · Undo" for 5 seconds. The cloud copy is deleted only after the undo window passes.
> - **Honest numbers:** "See All 24" is "See all". Stays no longer show invented star classes or the 9.2 score (the catalog has neither). The fallback stays are named "Mid-range stay in …" / "Budget stay in …" with "Estimated rate" in place of invented hotel names. "Handpicked" is dropped. The chat plan cards and the stays list carry "Fares are estimates from Lakbay's local rates." The sign-in disclaimer no longer mentions "verified partners".
> - **Errors:** `lib/services/friendly_error.dart` maps exceptions to one plain sentence (offline, timeout, busy, Google sign-in), keeps readable server messages and hides code-like ones. Used on auth, trip sharing and memories.
> - **Auth:** the lavender button is mango with mango ink.
> - **Onboarding copy** was already rewritten in Phase 2.
> - **Tests:** `test/phase3_ux_test.dart` (12 tests) covers timing labels, date round-trip, no invented ratings, error wording, take/restore/commit, the My Trips filters and confirm + undo.

These are the bugs found in the UI/UX study.

| # | Problem | Where | Fix |
|---|---|---|---|
| 1 | Trips have no dates in the app, so status is guessed | `models/travel_models.dart` (`ItineraryTrip`) | Add `startDate`/`endDate`, mapped from the backend `trips.start_date`/`end_date` columns, which already exist. Status is computed: Upcoming, Ongoing, Past, or Undated |
| 2 | "Past" filter always shows nothing | `my_trips_screen.dart:146` | Filter by the computed status |
| 3 | "Starts tomorrow" is hardcoded | `my_trips_screen.dart:259` | Relative label from `startDate` ("In 5 days", "Today", "Day 2 of 3"); none if undated |
| 4 | Vibe is hardcoded to "Island Hopping & Highlands" | `my_trips_screen.dart:31` | Use `trip.vibeTag` |
| 5 | "See All 24 →" is a made-up count | `explore_screen.dart:666` | "See all" |
| 6 | Trips delete instantly | `my_trips_screen.dart` (~409–418) | `showLkConfirm` and an Undo snackbar |
| 7 | Memories delete instantly | `memories_screen.dart:461` | Same as #6 |
| 8 | Auth screen uses an off-brand lavender (`#C5B3F9`) | `auth_screen.dart:193` | Theme tokens |
| 9 | Raw `e.toString()` errors shown to users | 2 places in `screens/` | `friendlyError(e)` mapper: no connection, wrong password, server busy, plus a retry |
| 10 | Onboarding copy overclaims | `onboarding_screen.dart` | Rewrite to match PRODUCT.md: real Region XI places, AI planner, fares are estimates |
| 11 | Prices look like guarantees | chat plan card, trip budget | Add the note "Fares are estimates from Lakbay's local rates." |

**Done when:** a dated trip moves between Upcoming, Ongoing and Past on its own, every delete can be confirmed and undone, and no screen shows a number the data doesn't support.

## Phase 4: Traveler screen rebuilds (large) ✅ done, with gaps listed below

> **What was built (2026-11-17)**
> - **Whole app on v8:** `MaterialApp` uses `LakbayDesignTheme.dark`. Every legacy screen was recolored by role (text, surface, border) to `LkColors`, then the main screens were rebuilt by hand. FigGrotesk, Inter, Outfit and the light `AppTheme` are gone; headings use Bricolage (`LkType.displayFamily`, bundled as `LakbayDisplay`), body text Manrope. `LakbayColors` remains only for the Mapbox widget's markers.
> - **4.1 Shell:** `LkFloatingNavBar` (Trips, Discover, Chat, Memories, Profile).
> - **4.2 Welcome and sign-in:** `widgets/welcome_hero.dart` (drifting photo, mango route Davao City → Samal with glass pins, headline, Start planning / Sign in, reduced-motion aware, scrolls on short screens). Sign-in/register is a dark sheet over the photo with labelled fields, autofill hints and announced errors. No language chip on Welcome: the language setting only changes catalog content, so the chip would overpromise.
> - **4.3 Trips home:** countdown, next-trip card with route line and stacked cards, Explore Region XI rail, date filters, confirm/undo delete. Weather chip only with real data.
> - **4.4 Chat:** v8 header, landing, mango user bubbles, plain AI replies, typing skeleton, quick follow-ups, composer with trip options, mic and send. `widgets/chat_plan_card.dart` draws the route from the trip's own coordinates and shows the budget split only when the server's `budget.category_totals` add up to the total.
> - **4.5 Trip detail:** glass header buttons, mango tab indicator, numbered dotted Day-by-Day timeline with ride/ferry chips. Maps default to the dark Night Nav style. Placeholder day temperatures are no longer shown.
> - **4.6 / 4.7:** Discover copy, Memories grouped by place with the shared empty state, Profile badges from real dates, no assumed travel companion.
> - **Screenshots:** `SHOTS_DIR=<dir> flutter test test/screenshots` renders the main screens to PNG with real fonts, icons and shadows.
>
> **Not built yet (carry into Phase 5 or later):**
> - The **live-day view** (draggable sheet with next stop, ETA, progress bar, "Move earlier" warnings, Directions button). `trip_route_map_screen.dart` is recolored but keeps its old layout.
> - **Onboarding** still has the original steps (trip decision, try-AI, product points, location), restyled. The 3-step "who, budget, interests" version was not built because the try-AI flow is covered by tests and works.
> - **Place detail** with a gallery and sticky "Add to trip" (Discover's existing detail is recolored only).
> - Not checked on a real Android phone yet; all checks were widget tests and test-rendered screenshots (network photos don't load in tests).


Rebuild one screen at a time, in this order, so each step stays demoable. The biggest files get split into `widgets/` as they are touched:
- `explore_screen.dart` (2,553 lines)
- `home_chat_screen.dart` (1,923 lines)
- `trip_detail_screen.dart` (1,939 lines)
- `yes_ai_onboarding_flow.dart` (1,504 lines)

### 4.1 App shell and tab bar (`main.dart`)
- Replace the custom `GestureDetector` bar with `LkFloatingNavBar`.
- Tabs: Trips, Discover, Chat, Memories, Profile. Chat becomes a normal tab with a chat icon, no special compass button.
- Content gets bottom padding so nothing hides under the floating bar.

### 4.2 Welcome, onboarding and auth
**Files:** `onboarding_screen.dart`, `yes_ai_onboarding_flow.dart`, `auth_screen.dart`.

- **Welcome:**
  - full-screen Samal photo with a slow drift
  - a mango route line that draws from Davao City to Samal Island, with glass pins ("Samal Island · 15 min · ₱25")
  - headline "Tell it the vibe. Get the whole trip."
  - "Start planning" (mango) and "Have an account? Sign in"
  - language chip at the top
- **Onboarding:** at most 3 short steps, each skippable:
  1. who's travelling
  2. budget style
  3. interests

  The rest is asked in chat, which the backend already does through `conversation_stage.py`.
- **Auth:** dark sheet over the photo, email and Google, inline field errors, friendly error messages.

### 4.3 Trips home (`my_trips_screen.dart`)
- Header: wordmark, notifications button, avatar.
- **Countdown hero:**
  - A big mango number with "days to {destination}", shown only when the next trip has a `startDate`.
  - On the trip day it shows "Today" or "Day N of M".
  - With no dated trip, it shows a "Plan your next trip" card that opens Chat.
- **Next trip card:** photo, a "Next trip" tag, the Davao City to destination line with a ferry icon when there's a sea crossing, and glass chips for date, days, people and ₱ per person. When there are more trips, darker cards stack behind it.
- Filter chips: Upcoming, Past, Drafts.
- **"Explore Region XI" rail:** photo cards with a category label, taken from the catalog.
- **Weather chip:** shown only when real forecast data is available (`wmoWeatherCode`). Otherwise it's hidden, never invented.

### 4.4 Chat (`home_chat_screen.dart`)
- Header: menu, "Lakbay AI", a lagoon dot with "Plans from real Region XI places", new-chat button.
- **Messages:**
  - user messages in mango bubbles
  - AI replies as plain text under an "L+ Lakbay AI · time" row
  - a typing skeleton while waiting
- **Plan card:**
  - mini route map with stop dots and photo pins
  - one line per day (Sat, Sun, Mon)
  - budget bar split into stay, food, rides and entrance
  - Save trip (mango) and Adjust buttons
  - the fare estimate note
- **Quick chips** (Cheaper, Food stop, Kid-friendly) sit just above the message box and send a ready-made follow-up.
- **Message box:** add button, text field, mic (speech_to_text, already in the app), mango send button. It stays above the keyboard.

### 4.5 Trip detail and live day
**Files:** `trip_detail_screen.dart`, `trip_route_map_screen.dart`, `widgets/route_trail.dart`, `lakbay_mapbox_widget.dart`.

- **Map:**
  - Mapbox map on top, in a dark style that matches the tokens
  - the done part of the route dashed, the next part solid lagoon
  - numbered stops and a "You" marker (from `location_service`)
  - Back, "Day 1 live" and map layers buttons on top
- **Draggable sheet:**
  - **Next stop card:** photo, name, how to get there, fare, and ETA in big numbers.
  - **Progress:** a segmented bar and "1 of 4 done · ₱685 per person today".
  - **Stop list:** numbered stops with times. A stop that will be closed when you arrive shows `LkWarningRow` with "Move earlier", using the existing `routeWarnings` and `route_progress` data.
- **Bottom bar:** chat shortcut plus "Directions to {next stop}" (mango).
- **Planning view (trip not started):**
  - day chips
  - stops linked by dotted lines with transport chips (tricycle, habal-habal, van, ferry, plus time and ₱)
  - the existing tabs for Stays, Budget, Members, Memories and Review, restyled

### 4.6 Discover (`explore_screen.dart`)
- Search field ("Where to in Davao?"), category row (Beaches, Islands, Mountains, Falls, Parks), photo rails by area.
- **Place detail:**
  - photo gallery
  - name and municipality
  - facts row: hours, entrance fee, travel time, each shown **only when the catalog has it** (`operatingHours`, `entranceFee`)
  - "Getting there"
  - sticky "Add to trip"

### 4.7 Memories, Profile, Settings
- Apply the tokens and shared widgets.
- Memories: photo grid grouped by trip, plus an empty state.
- Settings keeps the Photo credits page.
- Profile shows nothing invented (no badges or levels the backend doesn't track).

## Phase 5: Accessibility and polish (medium)

- **Semantics:**
  - Turn the 14 `GestureDetector` taps into `InkWell`, `LkIconButton` or `LkButton`.
  - Every icon-only control gets a tooltip or label.
  - Decorative photos are excluded from screen readers.
  - Today there are only 2 `Semantics` widgets in the whole app.
- **Contrast:** the token pairs already pass AA:
  - muted on bg is about 7.7:1
  - mango ink on mango is far above AA
  - lagoon is not used for small text on `s1` without a check

  Keep any new pairs ≥ 4.5:1.
- **Text scale:** every rebuilt screen works at 130% system text size without clipping. Chips wrap and cards grow.
- **Motion:** route draw, card rise and the live pulse all go through `LakbayMotion`. They are off when the phone's "remove animations" setting is on.
- **States:** every screen that loads data has loading, empty, error and offline states made from the shared widgets.
- **Haptics:** light feedback on Save trip, completing a stop, and delete-with-undo.
- **Chrome build:** check keyboard focus outlines and hover states, since the traveler app also runs in a browser.

## Phase 6: Admin app (medium)

The admin app already has light, dark and system themes and good AA tokens. It needs to look like the same product, not a rebuild.

1. **`core/theme/app_theme.dart`:**
   - The dark theme uses the v8 surfaces; the light theme stays for long data sessions.
   - Mango is the primary action color in both.
   - Bricolage for page titles and big numbers, Manrope for everything else.
2. **`widgets/sidebar.dart`, `topbar.dart`, `login_screen.dart`:**
   - wordmark only
   - mango pill on the active section
   - login on a Region XI photo with a dark panel, as on Welcome
3. **`screens/dashboard_screen.dart`:** stat cards with big Bricolage numbers taken from real API counts only, and a pending-review list.
4. **Data screens** (destinations, sea links, market rates, users, reviews, trips): keep tables dense, apply the new tokens, use the shared confirm dialog, and keep the existing `confirmAdminNavigation` unsaved-changes guard.

## Phase 7: Verify and prepare the defense (small)

1. `flutter analyze` is clean, and `flutter test` passes in both apps.
   (Fonts are already bundled, since Phase 2.)
2. Add a few **widget tests** for logic that is easy to break:
   - trip status from dates (Upcoming, Ongoing, Past, Undated)
   - countdown label
   - delete followed by Undo restores the item
   - `friendlyError` messages
3. Run on a real Android phone and in Chrome. Capture the four v8 screens to compare with the mockup side by side.
4. **Demo script:** Welcome → Chat a weekend in Samal → Save trip → Trips shows the countdown → open the trip → live day with directions → admin edits a fare and the change shows in the next plan.

---

## Summary

| Phase | What changes | Size |
|---|---|---|
| 0 | git, baseline | Small |
| 1 | Tokens, fonts, theme, shared widgets | Medium |
| 2 | Logo, sparkles, "expert" removed | Small |
| 3 | 11 UX and honesty bugs | Medium |
| 4 | Shell, Welcome/auth, Trips, Chat, Trip day, Discover, others | Large |
| 5 | Semantics, text scale, motion, states | Medium |
| 6 | Admin theme and shell | Medium |
| 7 | Tests, device check, demo | Small |

**Not in scope:**
- a light theme for the traveler app (tokens are set up so one can be added later)
- new backend features, except mapping the existing trip dates
- Filipino or Bisaya translation

**Decisions with defaults (change them if you disagree):**
- Bundle the fonts instead of loading them at runtime: **yes**.
- Onboarding cut to 3 steps, with the rest asked in chat: **yes**.
- Weather chip hidden when there is no real forecast: **yes**.
