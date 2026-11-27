# Davao Region Catalog Enrichment & Source Attribution Log (D6 / M5B)

## 1. Run Metadata & Environment Readiness
- **Run Timestamp (UTC)**: `2026-11-27T04:59:39Z` (`--apply`) and `2026-11-27T05:00:14Z` (post-apply `--dry-run` idempotency verification)
- **Execution Mode**: `live-applied` (authenticated Admin API writes against existing production schema; post-apply `--dry-run` confirmed `0` remaining diffs)
- **API Base URL**: `https://lakbay-api-rioi.onrender.com/api/v1`
- **Env Key Presence (booleans only, zero secrets logged)**:
  - `LAKBAY_API_BASE_URL`: `UNSET` (used default `https://lakbay-api-rioi.onrender.com/api/v1`)
  - `LAKBAY_ADMIN_EMAIL`: `SET` (authenticated as `role=admin` via `POST /auth/login`, HTTP `200`)
  - `LAKBAY_ADMIN_PASSWORD`: `SET`
- **Existing Schema Scope**: Enriched strictly against the live production schema (`PATCH /destinations/{id}`, `PUT /destinations/{id}/hours`, `PUT /destinations/{id}/prices`, `PUT /destinations/{id}/activities`, `POST /destinations/{id}/image`). M5A's destination clip migration (`2026_11_27_0415_destination_media_clips.py`) is **unapplied**, so sample GIF/WebM clips are staged below pending explicit migration approval.
- **Script & Offline Suite**:
  - CLI: `services/api/scripts/enrich_davao_catalog.py`
  - Offline test suite: `services/api/scripts/test_enrich_davao_catalog.py`

---

## 2. Live Catalog Gap Summary (62 Active Destinations: Before vs. After)

| Metric (62 Active Destinations) | Before D6 (`2026-11-27T04:43Z`) | After D6 (`2026-11-27T05:00Z`) | Notes |
|---|---|---|---|
| Active destinations | 62 (`IDs 1..46, 48..63`) | 62 (`IDs 1..46, 48..63`) | `ID 47` previously soft-deleted |
| Missing `description` (`IDs 31..41`) | 10 (`31..37, 39..41`) | **0** | Grounded descriptions added from verified primary/OSM sources |
| Missing `activities` (`IDs 31..44`) | 5 (`31, 32, 41, 42, 44`) | **0** (plus `ID 63` de-contaminated) | `ID 63` Discovery Samal copy-paste cleared to `null` |
| Missing `image_url` (`IDs 42..63`) | 21 (`100%`) | 17 | 4 verified CC/PD Wikimedia Commons photos uploaded (`51, 52, 54, 60`); 17 kept `null` without verified CC/PD photos |
| Non-canonical `"Davao Del Norte"` district | 20 (`42, 43, 44..46, 48..52, 54..63`) | **0** | All normalized to `"Davao del Norte"` |
| Corrupted `budget_class` (`"0"` or `"true"`) | 19 (`7, 44, 46, 48..63`) | **0** | Normalized to `"budget"`, `"mid_range"`, `"premium"` |
| Structured `/hours` = `supported` (in 40-target set) | 0 | **10** (`1, 3, 19, 32, 33, 35, 36, 39, 40, 41`) | Aqua Water Park (`16`) intentionally skipped due to Tuesday schedule conflict |
| Structured `/prices` = `supported` (in 40-target set) | 0 | **4** (`1, 14, 16, 32`) | Unconfirmed fees kept omitted/`null` |
| Structured `/activities` = `supported` (in 40-target set) | 0 | **6** (`1, 2, 3, 15, 31, 32`) | Confirmed operator/LGU activities with `source_url` + UTC `verified_at` |
| Guarded `arrival_*` / `route_ready` mutated | 0 | **0** | Script enforces hard guard preventing unverified `arrival_*`/`route_ready` writes |

---

## 3. Destination Enrichment Ledger (All 40 Targets)

Verification timestamp for all live writes: `2026-11-27T04:45:00Z`.

| ID | Name | Actions Applied (`200 OK`) | Fields Updated | Fields Kept `null` / Omitted | `data_quality` After (`H / P / A`) | Authoritative `source_url` | `source_type` |
|---|---|---|---|---|---|---|---|
| 1 | People's Park | `PATCH`, `PUT /hours`, `PUT /prices`, `PUT /activities` | `operating_hours`, `operating_status`, `booking_requirement`, `how_to_get_there`, 7d `13:00-22:00` weekly hours, `₱0.00` entrance, 3 activities | `arrival_lat`, `arrival_lng`, `route_ready`, `parking_note` | `supported / supported / supported` | `https://tourism.davaocity.gov.ph/explore-the-city/attractions/man-made-nature-parks/peoples-park/` | `official_lgu` |
| 2 | Philippine Eagle Center | `PATCH`, `PUT /activities` | `operating_status`, `booking_requirement`, `booking_note`, `Into the Wild Tour` (45 min) | `hours_payload`, `prices_payload`, `arrival_lat`, `arrival_lng` | `estimated / estimated / supported` | `https://www.philippineeaglefoundation.org/book-online`, `https://www.philippineeaglefoundation.org/service-page/into-the-wild-tour` | `operator_site` |
| 3 | Eden Nature Park | `PATCH`, `PUT /hours`, `PUT /activities` | `operating_hours`, `operating_status`, 7d `09:00-17:00` weekly hours, 7 activities | `prices_payload`, `extra_fee`, `arrival_*` (untouched) | `supported / estimated / supported` | `https://www.edennaturepark.com.ph/rates/`, `https://www.edennaturepark.com.ph/recreational-activities/` | `operator_site` |
| 7 | Panabo City Parks and Plaza | `PATCH` | `category` (`public plaza`), `budget_class` (`budget`, fixed from `"true"`) | `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/way/614154998` | `osm` |
| 14 | Museo Dabawenyo | `PUT /prices` | `entrance` (`everyone`, `0.00`, 2026 Charter) | `hours_payload`, `arrival_lat`, `arrival_lng` | `estimated / supported / unknown` | `https://davaocity.gov.ph/wp-content/uploads/2026/03/CGD_CC2026_VOLUMEIIE.pdf` | `official_lgu` |
| 15 | National Museum of the Philippines - Davao | `PATCH`, `PUT /activities` | `description`, `operating_status`, 2 museum exhibit activities | `hours_payload`, `prices_payload`, `arrival_lat`, `arrival_lng` | `estimated / estimated / supported` | `https://www.nationalmuseum.gov.ph/nmp-davao/` | `official_lgu` |
| 16 | Aqua Water Park | `PUT /prices` | `entrance` (`adult`, `570.00` 2026 weekday pass) | `hours_payload` (conflicting daily vs closed Tue), `arrival_*` | `estimated / supported / unknown` | `https://onlineshopping.aquaria.landcolifestyleventures.com/?ID=413&page=product&val1=aqua-water-park-samal-islanddavao-2026-day-tour-pass-for-adults-weekdays` | `operator_site` |
| 19 | Panabo Mangrove Forest Park | `PATCH`, `PUT /hours` | `operating_hours`, 7d `08:00-17:00` weekly hours | `prices_payload`, `estimated_cost`, `budget_class` | `supported / estimated / unknown` | `https://www.openstreetmap.org/way/1436929311` | `osm` |
| 22 | San Salvador del Mundo Church | `PATCH` | `name` (`Churcg` -> `Church`) | `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://davaooriental.gov.ph/wp-content/uploads/2022/01/0.0-Citizens-Charter-v1.3.pdf` | `official_lgu` |
| 31 | Malagos Garden Resort | `PATCH`, `PUT /activities` | `description`, `activities`, `operating_status`, `booking_requirement`, `best_time_to_visit`, `best_time_basis`, `how_to_get_there`, 9 activities | `entrance_fee`, `estimated_cost`, `budget_class`, `hours_payload`, `prices_payload` | `estimated / unknown / supported` | `https://www.malagos.com/explore`, `https://www.malagos.com/our-story` | `operator_site` |
| 32 | Casas Con Vistas Resort | `PATCH`, `PUT /hours`, `PUT /prices`, `PUT /activities` | `location`, `description`, `activities`, `estimated_cost` (`1050.00`), `budget_class`, `operating_status`, `booking_requirement`, `best_time_*`, `how_to_get_there`, 7d `10:00-18:00` hours, 4 itemized prices, 3 activities | `arrival_lat`, `arrival_lng`, `route_ready` | `supported / supported / supported` | `https://www.casasconvistas.ph/day-tour`, `https://www.casasconvistas.ph/` | `operator_site` |
| 33 | D' Bone Collector Museum | `PATCH`, `PUT /hours` | `description`, `entrance_fee` (paid admission note), `activities`, `operating_status`, `best_time_*`, Mon-Sat `10:00-16:00` / Sun closed | `prices_payload`, `estimated_cost`, `budget_class` | `supported / estimated / unknown` | `https://www.openstreetmap.org/way/201735372` | `osm` |
| 34 | Monfort Bat Sanctuary | `PATCH` | `location`, `description`, `activities`, `how_to_get_there` | `operating_hours`, `hours_payload`, `prices_payload`, `estimated_cost` | `unknown / estimated / unknown` | `https://www.openstreetmap.org/way/666853611`, `https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits` | `official_lgu` |
| 35 | Bukid Amara | `PATCH`, `PUT /hours` | `description`, `best_time_to_visit`, `best_time_basis`, 7d `08:00-17:30` hours | `entrance_fee`, `estimated_cost`, `budget_class`, `prices_payload` | `supported / unknown / unknown` | `https://www.openstreetmap.org/way/1470781676` | `osm` |
| 36 | Calamba Farm Sea of Clouds | `PATCH`, `PUT /hours` | `location`, `description`, `best_time_*`, `open_24_hours=True` | `entrance_fee`, `estimated_cost`, `budget_class`, `prices_payload` | `supported / unknown / unknown` | `https://calambafarm.com/`, `https://www.openstreetmap.org/node/7159866285` | `operator_site` |
| 37 | Mount Hamiguitan Range Wildlife Sanctuary | `PATCH` | `location`, `description`, `entrance_fee` (permit/guide note), `activities`, `booking_requirement` (`required`), `booking_note` | `operating_hours`, `hours_payload`, `prices_payload`, `estimated_cost` | `unknown / estimated / unknown` | `https://www.openstreetmap.org/way/1120154773`, `https://denr.gov.ph/wp-content/uploads/2023/07/DENR_News_Alerts_April_13_2022_Wednesday.pdf` | `official_lgu` |
| 39 | Dahican Surf Resort | `PATCH`, `PUT /hours` | `description`, `entrance_fee` (paid fee note), `activities`, `best_time_*`, `open_24_hours=True` | `prices_payload`, `estimated_cost`, `budget_class` | `supported / estimated / unknown` | `https://www.openstreetmap.org/node/6427841589` | `osm` |
| 40 | Isla Reta Beach Resort | `PATCH`, `PUT /hours` | `location`, `description`, `activities`, `how_to_get_there`, `open_24_hours=True` | `entrance_fee`, `estimated_cost`, `budget_class`, `prices_payload` | `supported / unknown / unknown` | `https://www.openstreetmap.org/relation/14964367`, `https://vatphil.com/viewchart.php?id=484` | `osm` |
| 41 | Uraya's Peak Adventure Park | `PATCH`, `PUT /hours` | `location`, `description`, `activities`, `estimated_cost` (`160.00`), `budget_class`, `best_time_*`, 7d `06:00-17:00` hours | `prices_payload`, `arrival_lat`, `arrival_lng` | `supported / estimated / unknown` | `https://www.openstreetmap.org/way/1161948892` | `osm` |
| 42 | Agriya Naturetainment | `PATCH` | `district`, `category` (`nature park`), `activities`, `operating_status` | `image_url`, `entrance_fee`, `estimated_cost`, `budget_class` | `estimated / unknown / unknown` | `https://damosaland.com/agriya/`, `https://www.openstreetmap.org/node/14282996052` | `operator_site` |
| 43 | Panabo City Seawall and Park | `PATCH` | `district`, `category` (`park`), `budget_class`, `how_to_get_there` | `image_url`, `hours_payload` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/way/1304265317` | `osm` |
| 44 | Museo Panabo | `PATCH` | `district`, `location`, `category` (`museum`), `activities`, `budget_class`, `how_to_get_there` | `image_url`, `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://panabocity.gov.ph/`, `https://www.openstreetmap.org/way/304043759` | `official_lgu` |
| 45 | Maria Clara Resort | `PATCH` | `district`, `category` (`beach resort`), `budget_class` | `image_url`, `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://www.waze.com/live-map/directions/ph/davao-region/panabo/maria-clara-resort?to=place.ChIJq3rCZq5F-TIRYk5gNwuC0sQ` | `osm` |
| 46 | Sky Deck Garden Cafe and Restaurant | `PATCH` | `district`, `category` (`cafe / restaurant`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://panabocity.gov.ph/` | `official_lgu` |
| 48 | Tagum Freedom Park | `PATCH` | `district`, `category` (`public plaza`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://sp.tagumcity.gov.ph/wp-content/uploads/2022/10/CO-848-18.pdf` | `official_lgu` |
| 49 | Energy Park | `PATCH` | `district`, `category` (`nature park`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://issuances-library.senate.gov.ph/executive-issuance/proclamation-no-1748-s-2009` | `official_lgu` |
| 50 | San Agustin Botanical Park | `PATCH` | `district`, `category` (`garden`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/relation/19697552` | `osm` |
| 51 | Tagum New City Hall | `PATCH`, `POST /image` | `district`, `category` (`landmark`), `budget_class`, `image_url` | `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://commons.wikimedia.org/wiki/File:Newtagumcityhall.jpg` | `wikimedia_commons` |
| 52 | World's largest Rosary | `PATCH`, `POST /image` | `district`, `category` (`religious landmark`), `budget_class`, `image_url` | `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://commons.wikimedia.org/wiki/File:Christ_The_King_Cathedral_Tagum.jpg` | `wikimedia_commons` |
| 53 | Huyong-huyong Nature Park | `PATCH` | `category` (`nature park`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/way/926328738` | `osm` |
| 54 | Davao del Norte Sports and Tourism Complex (DNSTC) | `PATCH`, `POST /image` | `district`, `category` (`sports complex`), `budget_class`, `image_url` | `operating_hours`, `hours_payload` | `unknown / estimated / unknown` | `https://commons.wikimedia.org/wiki/File:DNSTC_Aquatic_Center.jpg` | `wikimedia_commons` |
| 55 | Tagum City Historical & Cultural center | `PATCH` | `district`, `category` (`museum`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://sp.tagumcity.gov.ph/wp-content/uploads/2022/10/CO-848-18.pdf` | `official_lgu` |
| 56 | Tagum City River Cruise / Nabintad River | `PATCH` | `district`, `category` (`nature park`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits` | `official_lgu` |
| 57 | Banana Beach at Hijo Resorts Davao | `PATCH` | `district`, `category` (`beach resort`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://depeddavnor.ph/records/officememo/DM-OSDS-2025-0199%20-%20LAND%20TITLING%20ISSUES%20AND%20SOLUTIONS%20A%20MULTI-PERSPECTIVE%20APPROACH.pdf` | `official_lgu` |
| 58 | Lanikai Hijo Estate Resort | `PATCH` | `district`, `category` (`beach resort`), `budget_class` | `image_url`, `operating_hours`, `entrance_fee` | `unknown / estimated / unknown` | `https://mirror.pia.gov.ph/news/2022/06/03/colors-of-mindanao-banners-5-davnor-tourism-circuits` | `official_lgu` |
| 59 | LYR Agro Inland Resort | `PATCH` | `district`, `category` (`resort`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/way/1431254432` | `osm` |
| 60 | Pearl Farm Beach Resort | `PATCH`, `POST /image` | `district`, `category` (`beach resort`), `budget_class`, `operating_status`, `image_url` | `hours_payload`, `prices_payload` | `estimated / estimated / unknown` | `https://pearlfarmresort.com/`, `https://commons.wikimedia.org/wiki/File:Pearl_Farm_Davao_Philippines.jpg` | `operator_site` |
| 61 | Paradise Island Park & Beach Resort | `PATCH` | `district`, `category` (`beach resort`), `budget_class` | `image_url` | `estimated / estimated / unknown` | `https://www.openstreetmap.org/relation/9472621` | `osm` |
| 62 | Discovery Samal | `PATCH` | `district`, `category` (`beach resort`), `budget_class`, `operating_status` | `image_url`, `entrance_fee` | `estimated / estimated / unknown` | `https://www.discoverysamal.com/`, `https://www.openstreetmap.org/way/1002108565` | `operator_site` |
| 63 | Chema's by the Sea | `PATCH` | `district`, `category` (`beach resort`), `budget_class`, cleared `activities=None`, cleared `overnight_fee=None` | `image_url`, `entrance_fee`, `activities`, `overnight_fee` | `estimated / unknown / unknown` | `https://www.openstreetmap.org/way/158515617` | `osm` |

---

## 4. Photo Attribution Ledger (Wikimedia Commons -> Live Cloudinary)

| ID | Destination | Wikimedia Commons Page | Direct Source File | License | Author | Bytes | Live Uploaded `image_url` |
|---|---|---|---|---|---|---|---|
| 51 | Tagum New City Hall | `https://commons.wikimedia.org/wiki/File:Newtagumcityhall.jpg` | `https://upload.wikimedia.org/wikipedia/commons/2/26/Newtagumcityhall.jpg` | `CC BY-SA 3.0` | `S5switch` | 174,472 | `https://res.cloudinary.com/bh2rda7z/image/upload/v1795755543/lakbay/destinations/51/dest_51_amlmln.jpg` |
| 52 | World's largest Rosary | `https://commons.wikimedia.org/wiki/File:Christ_The_King_Cathedral_Tagum.jpg` | `https://upload.wikimedia.org/wikipedia/commons/5/5f/Christ_The_King_Cathedral_Tagum.jpg` | `CC BY 3.0` | `S5switch` | 1,278,474 | `https://res.cloudinary.com/bh2rda7z/image/upload/v1795755554/lakbay/destinations/52/dest_52_np9jfn.jpg` |
| 54 | Davao del Norte Sports and Tourism Complex (DNSTC) | `https://commons.wikimedia.org/wiki/File:DNSTC_Aquatic_Center.jpg` | `https://upload.wikimedia.org/wikipedia/commons/8/8a/DNSTC_Aquatic_Center.jpg` | `CC BY-SA 4.0` | `S5switch` | 1,776,723 | `https://res.cloudinary.com/bh2rda7z/image/upload/v1795755565/lakbay/destinations/54/dest_54_mktzv6.jpg` |
| 60 | Pearl Farm Beach Resort | `https://commons.wikimedia.org/wiki/File:Pearl_Farm_Davao_Philippines.jpg` | `https://upload.wikimedia.org/wikipedia/commons/b/bc/Pearl_Farm_Davao_Philippines.jpg` | `CC BY-SA 4.0` | `Jimboyperez` | 1,741,823 | `https://res.cloudinary.com/bh2rda7z/image/upload/v1795755576/lakbay/destinations/60/dest_60_nyj1et.jpg` |

**Intentionally Left `image_url = null` (17 records)**: `42, 43, 44, 45, 46, 48, 49, 50, 53, 55, 56, 57, 58, 59, 61, 62, 63`. No venue-specific CC-licensed or public-domain Wikimedia Commons photographs were verified for those properties; proprietary resort/operator marketing photos were intentionally not scraped or uploaded without license.

---

## 5. Staged Sample GIF / Short Video Clip Ledger (Post-Migration Ready)

These 4 verified Wikimedia Commons clips are staged for upload via M5A's `POST /api/v1/destinations/{id}/media` **after** Alembic migration `2026_11_27_0415_destination_media_clips.py` is explicitly approved and applied.

| Target ID & Name | `media_type` | Wikimedia Commons Page | Direct File URL | License & Author | Raw Size / Duration | Requires Trim / Mute | Exact `ffmpeg` Preparation Command |
|---|---|---|---|---|---|---|---|
| `6` Dahican Beach | `gif` | `https://commons.wikimedia.org/wiki/File:Breaking_waves_fast.gif` | `https://upload.wikimedia.org/wikipedia/commons/9/94/Breaking_waves_fast.gif` | `CC BY-SA 3.0` — `Jahobr` | `5,643,128` B (5.38 MB) / `14.20s` (318x178) | `no` (meets `<=10 MB`, `<=15s`) | None (generic coastal wave loop sample; ready as-is) |
| `61` Paradise Island Park & Beach Resort | `video` | `https://commons.wikimedia.org/wiki/File:Samal_Island_Views_-_September_2018.webm` | `https://upload.wikimedia.org/wikipedia/commons/1/1c/Samal_Island_Views_-_September_2018.webm` | `CC BY-SA 4.0` — `RoyKabanlit` | `27,706,071` B (26.4 MB) / `84.82s` (1280x720) | `yes` (exceeds `15s` & `15 MB`) | `ffmpeg -ss 00:00:05 -t 12 -i Samal_Island_Views_-_September_2018.webm -an -c:v libvpx-vp9 -b:v 1.5M -vf "scale='min(1280,iw)':-2" samal_island_views_12s.webm` |
| `1` People's Park | `video` | `https://commons.wikimedia.org/wiki/File:Greetings_from_WikiClub_Davao.webm` | `https://upload.wikimedia.org/wikipedia/commons/a/a9/Greetings_from_WikiClub_Davao.webm` | `CC BY-SA 4.0` — `MadayawDavao` | `3,142,989` B (3.00 MB) / `9.50s` (1024x576) | `optional` (strip audio for muted auto-loop) | `ffmpeg -i Greetings_from_WikiClub_Davao.webm -an -c:v copy greetings_davao_muted.webm` |
| `4` Samal Island Beach Area | `video` | `https://commons.wikimedia.org/wiki/File:Waves_at_Hikkaduwa_beach,_Sri_Lanka.webm` | `https://upload.wikimedia.org/wikipedia/commons/1/16/Waves_at_Hikkaduwa_beach%2C_Sri_Lanka.webm` | `CC BY-SA 4.0` — `Jan Kranendonk` | `1,602,290` B (1.53 MB) / `7.02s` (720x556) | `optional` (generic non-Davao surf sample; strip audio) | `ffmpeg -i Waves_at_Hikkaduwa_beach,_Sri_Lanka.webm -an -c:v copy coastal_waves_muted.webm` |

---

## 6. Reproducible Commands

From `services/api/`:

- **Dry-run (live read + schema validation + diff check)**:
  ```powershell
  ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --dry-run
  ```
- **Offline dry-run (no network required)**:
  ```powershell
  ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --dry-run --offline
  ```
- **Authenticated live apply (requires `LAKBAY_ADMIN_EMAIL` & `LAKBAY_ADMIN_PASSWORD` in env)**:
  ```powershell
  ./.venv/Scripts/python.exe -m scripts.enrich_davao_catalog --apply
  ```
- **Offline verification suite**:
  ```powershell
  ./.venv/Scripts/python.exe -m pytest -q scripts/test_enrich_davao_catalog.py tests/test_davao_region_data.py tests/test_destination_hours.py tests/test_destination_prices.py tests/test_destination_activities.py
  ```
