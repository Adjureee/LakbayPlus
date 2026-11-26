# Flagship UX baseline (F0)

Part of `docs/FLAGSHIP_UX_PLAN.md`. This records what was **measured** before any UI change, so later phases can show a before and after. Rows marked "to measure" need a phone or real users and are not filled in.

Measured on 27 Nov 2026 from the saved production snapshot `services/api/tests/accuracy/corpus/catalog.json` (committed 20 Nov, 63 places, all active) and the traveler source. It is a snapshot, so re-run before F3.

## 1. Catalog coverage

| Measure | Value | Target (plan) |
|---|---|---|
| Places with a photo | **41 of 63 (65%)** | 100% on shown places, 90% overall |
| Places with a known cost (`estimated_cost` above 0; the app treats 0 as "not listed") | **36 of 63 (57%)** | 90% |
| Places with operating hours | 59 of 63 (94%) | keep |
| Places with any stay or transport rate | **13 of 63 (21%)** | rates for the most-viewed places first |
| Places missing both a photo and a cost | 2 (Agriya Naturetainment, Museo Panabo) | 0 |
| Duplicate records | 1 name appears twice: Sky Deck Garden Cafe and Restaurant | 0 |
| Distinct values in `category` | **45 for 63 places** (35 used once, 5 longer than 40 characters) | a short controlled list |

The `category` field holds free text such as "5-Star Luxury Beachfront Resort, Convention Hub, and Island Staycation Retreat." This is why the Home category chips and the chat card tags look uneven ("Beach Resort (4)" next to one-off labels). It is a data fix, not a screen fix.

### Admin to-do: 22 places with no photo
21 of the 22 are in Davao del Norte (Tagum, Panabo and the Samal island resorts):
Agriya Naturetainment, Banana Beach at Hijo Resorts Davao, Chema's by the Sea, Davao del Norte Sports and Tourism Complex, Discovery Samal, Energy Park, Huyong-huyong Nature Park, LYR Agro Inland Resort, Lanikai Hijo Estate Resort, Maria Clara Resort, Museo Panabo, Panabo City Seawall and Park, Paradise Island Park & Beach Resort, Pearl Farm Beach Resort, San Agustin Botanical Park, Sky Deck Garden Cafe and Restaurant (two records), Tagum City Historical & Cultural Center, Tagum City River Cruise / Nabintad River, Tagum Freedom Park, Tagum New City Hall, World's Largest Rosary.

### Admin to-do: 27 places with no known cost
Agriya Naturetainment, Bemwa Farm, Bukid Amara, Calamba Farm Sea of Clouds, Cape San Agustin, Casas Con Vistas Resort, Christ the King Cathedral Parish, Christ the Redeemer (Jose Abad Santos), D' Bone Collector Museum, DDG Beach Resort, Dahican Surf Resort, Digos City Eco Park and Arboretum, Isla Reta Beach Resort, Lake Leonard Eco-Tourism Park, Malagos Garden Resort, Meskeen Resort (Malita Dives), Monfort Bat Sanctuary, Mount Hamiguitan Range Wildlife Sanctuary, Museo Dabawenyo, Museo Panabo, National Museum of the Philippines - Davao, New Barili Heights and Sights, Panabo Mangrove Forest Park, Pyalitan Falls, Rizal Park Digos, San Salvador del Mundo Church (spelled "Churcg" in the record), Uraya's Peak Adventure Park.

The admin app already has photo and price editors, so this is data entry, not new software.

## 2. Wording baseline (the string scan F1 must clear)

**31 user-visible string literals** in `apps/traveler_app/lib` mention Mapbox, Region XI, IGaCoS, "trip tray", Groq or Gemini. Main groups:

A line can match more than one word, so the rows add up to more than 31.

| Word | Lines | Examples |
|---|---|---|
| "Region XI" | 12 | `travel_models.dart:252,414`, `my_trips_screen.dart:68`, `profile_screen.dart:342`, `travel_repository.dart:241,3332,5575` |
| "IGaCoS" | 3 | `travel_models.dart:205`, `travel_repository.dart:313`, `settings_screen.dart:768` |
| "trip tray" | 1 | `explore_screen.dart:916` |
| "Mapbox" | 18 | `explore_screen.dart:300,315`, `trip_detail_screen.dart:835,1727,2144`, `trip_route_map_screen.dart:824,912,913`; one is the required attribution |
| "Groq" or "Gemini" | 1 | `settings_screen.dart:704` (About text) |

Part of the Mapbox lines is a token-entry screen: `lakbay_mapbox_widget.dart:553,618,626,920,921` and `trip_route_map_screen.dart:913`, plus the status row at `settings_screen.dart:299`.

Two things the plan did not say before:
- **A token-entry UI is in the shipped app.** Normal travelers should never see "Set Mapbox Access Token" or "Tap Mapbox Key to set MAPBOX_ACCESS_TOKEN". That belongs in a debug-only build.
- **Mapbox attribution must stay.** `mapbox_service.dart:51` returns "© Mapbox", which the map's terms require. The F1 string test must allow that one line.

## 3. Entry points and structure

| Measure | Value |
|---|---|
| Ways to start a trip | 4 (chat "Plan it", Discover trip tray, My Trips "+" form, first-run wizard) |
| Bottom tabs | 5 (Trips, Discover, Chat, Memories, Profile) |
| Reporting | None: `pubspec.yaml` has `firebase_core` and `firebase_messaging`, no analytics or crash reporting |

## 4. Still to measure

| Measure | Who | Method |
|---|---|---|
| Taps and seconds from first launch to first result cards | You, on the phone | `docs/FLAGSHIP_UX_USER_TEST.md`, section 4 |
| Round 1 user test (5 to 8 travelers) | You recruit and run; the kit is ready | Same file |
| Fresh screenshots of Home, Chat, Discover, Place, Trips, Trip detail, route map | You | Phone, as in `docs/redesign/` |
| Play Console crash and ANR rates | Needs a release build and reporting | After the analytics step |
| Accessibility at 1.25x to 2.0x text | Existing tests plus the phone | `flutter test` plus a manual pass |

## 5. Chat answer quality (reference, not re-run)

Not re-run for F0, because a live run spends model quota. The offline replay (`tests/test_accuracy_replay.py`) is the gate for every phase that touches chat; the last live record is `docs/AI_STRESS_BASELINE.md`.
