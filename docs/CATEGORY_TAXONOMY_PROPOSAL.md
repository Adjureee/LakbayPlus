# Proposed Controlled Category Taxonomy (D5)

Read-only proposal mapping all **45 distinct `category` values** (63 places) from the `2026-11-20` catalog snapshot ([catalog.json](../services/api/tests/accuracy/corpus/catalog.json)) into **8 controlled kinds**. No database or backend changes have been made.

> **Note:** Counts come from the committed snapshot (`catalog.json`, 63 places); live DB categories should be re-queried before any migration.

## Summary of Proposed 8 Kinds

| # | Proposed Kind Key | Traveler Label | Current Categories Mapped | Snapshot Places | Alignment (`place_kinds.dart` / `preference_groups.json`) |
|---|---|---|---:|---:|---|
| 1 | `beach_island` | Beaches & Islands | 9 | 14 | `PlaceKind.beach` / `beaches`, `islands` |
| 2 | `waterfalls_springs` | Waterfalls, Rivers & Springs | 3 | 6 | `PlaceKind.water` / `waterfalls`, `springs_lakes` |
| 3 | `mountains_viewpoints` | Mountains & Viewpoints | 4 | 5 | `PlaceKind.mountain` / `mountains_viewpoints` |
| 4 | `nature_wildlife` | Nature Parks & Wildlife | 9 | 11 | `PlaceKind.nature` / `parks_wildlife` |
| 5 | `farms_agritourism` | Farms & Gardens | 3 | 3 | `PlaceKind.nature` / `gardens_farms` |
| 6 | `culture_heritage` | Culture, Heritage & Faith | 7 | 11 | `PlaceKind.culture` / `culture_heritage` |
| 7 | `city_parks_recreation` | City Parks & Recreation | 6 | 6 | `PlaceKind.nature`/`other` / `parks_recreation` |
| 8 | `resorts_dining` | Resorts, Water Parks & Dining | 4 | 7 | `PlaceKind.stay` / `resorts_leisure` |
| | **Total** | | **45** | **63** | |

---

## Complete Mapping (All 45 Categories)

### 1. `beach_island` — Beaches & Islands (9 categories, 14 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `beach resort` | 4 | DDG Beach Resort, Dahican Surf Resort, Isla Reta Beach Resort |
| `beach` | 3 | Dahican Beach, Little Boracay Beach, Samal Island Beach Area |
| `island` | 1 | Balut Island |
| `5-Star Luxury Beachfront Resort, Convention Hub, and Island Staycation Retreat.` | 1 | Discovery Samal |
| `Boutique Heritage Beach Resort` | 1 | Lanikai Hijo Estate Resort |
| `Boutique Nature Beach Resort, Balinese-Style Island Retreat, and Pet-Friendly Hideaway.` | 1 | Chema's by the Sea |
| `Classic Beachfront Resort, Family Eco-Park, and Day-Tour Island Getaway.` | 1 | Paradise Island Park & Beach Resort |
| `Eco-Agritourism Beach Resort` | 1 | Banana Beach at Hijo Resorts Davao |
| `Island Resort, Heritage Beach Sanctuary` | 1 | Pearl Farm Beach Resort |

### 2. `waterfalls_springs` — Waterfalls, Rivers & Springs (3 categories, 6 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `waterfall` | 4 | Aliwagwag Falls, Pyalitan Falls, Tagbibinta Falls |
| `hot spring` | 1 | Mainit Hot Springs |
| `Eco-Tourism Park` | 1 | Tagum City River Cruise / Nabintad River *(borderline: could also fit `nature_wildlife`)* |

### 3. `mountains_viewpoints` — Mountains & Viewpoints (4 categories, 5 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `mountain resort` | 2 | Camp Sabros Mountain Resort, New Barili Heights and Sights |
| `mountain` | 1 | Mount Apo Trail Area |
| `scenic cape` | 1 | Cape San Agustin |
| `sea of clouds viewpoint` | 1 | Calamba Farm Sea of Clouds |

### 4. `nature_wildlife` — Nature Parks & Wildlife (9 categories, 11 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `nature park` | 2 | Digos City Eco Park and Arboretum, Panabo Mangrove Forest Park |
| `nature reserve` | 2 | Monfort Bat Sanctuary, Mount Hamiguitan Range Wildlife Sanctuary |
| `Nature Park` | 1 | Huyong-huyong Nature Park *(case duplicate of `nature park`)* |
| `wildlife` | 1 | Philippine Eagle Center |
| `lake park` | 1 | Lake Leonard Eco-Tourism Park *(borderline: `waterfalls_springs`)* |
| `Nature` | 1 | Agriya Naturetainment |
| `nature resort` | 1 | Eden Nature Park *(borderline: `resorts_dining`)* |
| `Urban Eco-Park` | 1 | Energy Park |
| `Garden / Eco-Park` | 1 | San Agustin Botanical Park *(borderline: `farms_agritourism`)* |

### 5. `farms_agritourism` — Farms & Gardens (3 categories, 3 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `farm` | 1 | Bemwa Farm |
| `flower farm` | 1 | Bukid Amara |
| `Agritourism Vineyard, Inland Pool Resort, and Family Recreational Park.` | 1 | LYR Agro Inland Resort *(borderline: `resorts_dining`)* |

### 6. `culture_heritage` — Culture, Heritage & Faith (7 categories, 11 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `museum` | 4 | D' Bone Collector Museum, Museo Dabawenyo, National Museum of the Philippines - Davao |
| `church` | 2 | Christ the King Cathedral Parish, San Salvador del Mundo Churcg |
| `religious landmark` | 1 | Christ the Redeemer, Jose Abad Santos |
| `Religious Landmark` | 1 | World's largest Rosary *(case duplicate of `religious landmark`)* |
| `Cultural and Historical Landmark` | 1 | Museo Panabo |
| `Cultural Center, Heritage Museum, Public Library, and Performing Arts Venue.` | 1 | Tagum City Historical & Cultural center |
| `Landmark` | 1 | Tagum New City Hall |

### 7. `city_parks_recreation` — City Parks & Recreation (6 categories, 6 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `park` | 1 | People's Park |
| `city park` | 1 | Rizal Park Digos |
| `Coastal Park` | 1 | Panabo City Seawall and Park *(borderline: `beach_island`)* |
| `Cultural / Public Parks` | 1 | Tagum Freedom Park |
| `Park / Public Plaza` | 1 | Panabo City Parks and Plaza |
| `Sports Complex` | 1 | Davao del Norte Sports and Tourism Complex (DNSTC) |

### 8. `resorts_dining` — Resorts, Water Parks & Dining (4 categories, 7 places)
| Current `category` value | Count | Example place(s) |
|---|---:|---|
| `resort` | 3 | Casas Con Vistas Resort, Malagos Garden Resort, Uraya's Peak Adventure Park |
| `Cafe/ Restaurant` | 2 | Sky Deck Garden Cafe and Restaurant *(duplicate records 46 & 47 — see D6)* |
| `water park` | 1 | Aqua Water Park |
| `Resort and Restaurant` | 1 | Maria Clara Resort |

---

## Notable Cleanups Surfaced by the Snapshot
1. **Sentence-length descriptions stored in `category`** (6 places: Discovery Samal, LYR Agro Inland Resort, Chema's by the Sea, Paradise Island, Tagum City Historical & Cultural center, Pearl Farm) should move to `description` / `summary`, leaving a short controlled kind key in `category`.
2. **Case duplicates**: `nature park` vs `Nature Park`, `religious landmark` vs `Religious Landmark`.
3. **Optional split/merge**: If dining should be distinct from resorts later, `farms_agritourism` can be merged into `nature_wildlife` to free a slot for `dining_cafes` while staying at 8 kinds.
