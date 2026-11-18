# Place data design (Phase 2 data work)

Status: **draft for review. Nothing in this document is implemented. No table or column changes until you approve each step** (backend rule: existing tables change only with explanation and approval).

Source: specification section B4 (destination and activity data), B5 (incomplete data), and the gap list in `AI_CHAT_STRESS_TEST_PLAN.md`. Written against the current model in `services/api/app/features/destinations/models.py`.

## 1. Why this is needed

The assistant is only as honest as the records behind it. The stress runs showed the AI inventing times, fares and routes because the record has nothing to say, and the grounding checks can only reject a figure; they cannot tell the traveler *how sure* a figure is. Today a place record cannot say:

- when its fee or opening hours were last checked, or where the information came from (only the arrival point has that);
- opening hours by day, or a holiday exception (one 255-character text field);
- a price for an adult, a child or a senior (one text field `entrance_fee`);
- what each activity costs, when it runs, how long it takes, who may join;
- the difference between "not wheelchair accessible" and "nobody has checked" (the flags default to `false`);
- whether booking is needed, whether it is open at all.

## 2. Principles

1. **Additive only.** New nullable columns and new tables. The existing text columns (`entrance_fee`, `operating_hours`, `activities`, `best_time_to_visit`) stay and keep working; the app and the AI fall back to them when structured data is missing.
2. **Unknown is a value.** An empty field means "not listed", never "no" and never "free". This matches B5.
3. **A fact that can be quoted carries its source and date.** Fees, hours and activity details each have a source and a last-verified date. The AI may say "last checked 12 Oct 2026" and may rank unverified data lower.
4. **Admins enter the data.** Every new field has an admin app form. Places with gaps keep working and show "not listed".
5. **Small steps, each shippable.** Four steps (section 7), each with its own migration, API, admin form and AI use.

## 3. Changes to `destinations`

All new columns nullable unless stated.

| Column | Type | Meaning |
|---|---|---|
| `operating_status` | varchar(20), check in (`open`, `temporarily_closed`, `permanently_closed`) | `NULL` = unknown. `permanently_closed` places are excluded from recommendations (today only `is_active` does this) |
| `open_24_hours` | boolean | Quick flag for places like beaches; replaces guessing from text `24/7` |
| `hours_source_url`, `hours_verified_at` | varchar(2048), timestamptz | Where and when the hours were last checked |
| `fees_source_url`, `fees_verified_at` | varchar(2048), timestamptz | Same for entrance fees and prices |
| `booking_requirement` | varchar(20), check in (`required`, `recommended`, `not_required`) | `NULL` = unknown |
| `booking_note` | text | How to book, a contact, lead time |
| `parking_note` | text | Parking availability and fee, as free text |
| `typical_visit_min_minutes`, `typical_visit_max_minutes` | integer, check `> 0`, min ≤ max | Typical stay, for the itinerary timeline |
| `best_time_basis` | text | The reason behind `best_time_to_visit` ("cooler in the morning", "crowds after 10 am"), so the card can show recommended time *with its basis* |

### Accessibility flags: unknown vs no

`is_wheelchair_accessible`, `is_kid_friendly`, `is_pet_friendly`, `is_elderly_friendly` (and `family_friendly`, `couple_friendly`, `group_friendly`) are non-null booleans defaulting to `false`. Proposal: make them **nullable, no default**, with this backfill:

- `true` stays `true`;
- `false` becomes `NULL` (unknown), because `false` was the default and nobody can tell which ones were checked.

Consequences to handle in the same step: every reader treats `NULL` as "not listed" rather than "no" (audit: `ai/rag.py`, `recommendations/service.py`, `planning/draft.py`, `geo_analytics/service.py`, the traveler `lakbay_api_catalog_service.dart`, the admin editor). Filters like "wheelchair accessible" keep matching only `true`. A traveler who states an accessibility need is shown places that are `true`, plus a note on places that are unknown.

**Decision 1 for you:** backfill `false → NULL` (recommended, honest), or leave existing values and only allow `NULL` for new entries (no data change, but old `false` stays ambiguous).

## 4. New tables

### `destination_hours` (weekly schedule)

| Column | Type | Notes |
|---|---|---|
| `id` | pk | |
| `destination_id` | fk destinations, index | on delete cascade |
| `weekday` | smallint 0–6 (Monday = 0), check | |
| `opens_at`, `closes_at` | time | local time (Asia/Manila); both null when `is_closed` |
| `is_closed` | boolean, default false | closed that day |
| `last_admission_at` | time, nullable | |

A place can have several rows for one weekday (lunch break, split hours). A place with no rows has unknown hours, not "closed". Constraint: `opens_at < closes_at` unless the row crosses midnight (modelled as two rows; keep it simple).

### `destination_hour_exceptions` (date-specific)

`id`, `destination_id`, `starts_on` date, `ends_on` date (equal for one day), `is_closed` boolean, `opens_at`/`closes_at` time nullable, `reason` text ("Holy Week", "typhoon closure"). An exception wins over the weekly row for its dates.

### `destination_prices` (fee policy)

| Column | Type | Notes |
|---|---|---|
| `id`, `destination_id` | | |
| `item` | varchar(20), check in (`entrance`, `overnight`, `parking`, `cottage`, `other`) | |
| `audience` | varchar(20), check in (`adult`, `child`, `senior`, `pwd`, `student`, `resident`, `non_resident`, `everyone`) | |
| `amount` | numeric(10,2) ≥ 0 | `0` only when the source says free; otherwise no row |
| `unit` | varchar(20), check in (`per_person`, `per_group`, `per_vehicle`, `per_night`) | |
| `age_min`, `age_max` | smallint, nullable | "child: 4 to 12" |
| `note` | text | "free for residents with ID" |

Verified with the destination's `fees_verified_at` and `fees_source_url`. This is what makes "estimated vs supported" (B7) real: a price with a row is **supported**; a legacy text fee with no verified date is **estimated**; no row is **unknown**.

### `destination_activities`

| Column | Type | Notes |
|---|---|---|
| `id`, `destination_id` | | |
| `name` | varchar(255), not null | |
| `description` | text | |
| `availability` | varchar(20), check in (`always`, `scheduled`, `seasonal`, `by_arrangement`) | `NULL` = unknown |
| `schedule_note` | text | sessions, seasons ("Dec to May") |
| `last_admission_at` | time | |
| `duration_min_minutes`, `duration_max_minutes` | integer | typical duration |
| `extra_fee` | numeric(10,2) ≥ 0, nullable | |
| `fee_included_in_admission` | boolean, nullable | `NULL` = unknown |
| `effort_level` | varchar(20), check in (`easy`, `moderate`, `challenging`) | same vocabulary as the planning state |
| `accessibility_note` | text | |
| `min_age`, `max_age` | smallint | participation limits |
| `restriction_note` | text | health or gear requirements |
| `weather_dependency` | varchar(20), check in (`none`, `dry_weather`, `calm_seas`, `daylight`) | `NULL` = unknown |
| `best_time_note`, `best_time_basis` | text | recommended time and why |
| `source_url`, `verified_at` | | per-activity, since activities change faster than the place |
| `is_active` | boolean default true | |
| `sort_order` | integer default 0 | |

The legacy `destinations.activities` text is **not** auto-split (it is free prose). Admins convert places one at a time; the card uses structured rows when present and the text otherwise. A destination being open never implies an activity is available: the AI is told to name an activity only from an active row or the legacy text, and to say "availability not confirmed" when `availability` is `NULL`.

## 5. How the data reaches travelers

1. **API.** New optional fields on the destination read schema (`hours`, `exceptions`, `prices`, `activities`, status, booking, verified dates). Existing clients ignore them. Writes stay admin-only.
2. **Retrieval (`rag.py`).** Each retrieved record carries the structured facts and a `data_quality` label per group: `supported` (row exists and `*_verified_at` is set), `estimated` (only legacy text), `unknown`. The grounding checks (`grounding.py`) already restrict figures to the supplied facts, so adding structured facts widens what the AI may truthfully quote; nothing else loosens.
3. **Cards.** Supported activities, visit duration, recommended time with its basis, and an "important unknowns" line (B3). "Opens 8 am to 5 pm" comes from `destination_hours`, with the weekday of the trip date once the itinerary knows it.
4. **Itinerary timeline (next phase).** Uses opening hours, last admission and typical durations to check feasibility, and prices to build a known/estimated/unknown budget.
5. **Staleness.** A `*_verified_at` older than a threshold (proposal: 12 months for fees and hours) is shown as "last checked <date>" and downgraded from `supported` to `estimated`.

## 6. Admin app

Extend `apps/admin_app/lib/screens/destination_editor.dart` in sections, not a new screen:

- **Status and booking:** status, 24-hour toggle, booking requirement and note, parking note.
- **Hours:** a weekly grid (day, opens, closes, closed, last admission) with "copy to all days", and an exceptions list. Source URL and verified date at the top, with a "verified today" button.
- **Prices:** a small table (item, audience, amount, unit, ages, note), with source and verified date.
- **Activities:** an add/reorder list; each opens a form with the fields above.
- **Accessibility and suitability:** each flag becomes a three-way choice: Yes, No, Not checked.
- **Completeness meter:** per place, which groups are filled and verified, so data entry can be prioritised (suggestion: start with the places that appear most often in AI cards).
- **Duplicate warning:** when saving a name that matches an existing active place (the catalog currently holds "Sky Deck Garden Cafe and Restaurant" twice). This is a data fix plus a form check, not a schema change.

## 7. Delivery in steps

Each step is a separate branch, migration, deploy and approval.

| Step | Contents | Risk |
|---|---|---|
| 1 | Section 3: new `destinations` columns, nullable accessibility flags with the backfill, reader audit, admin form sections "Status and booking" and accessibility three-way | Medium: touches existing columns and every reader of the flags |
| 2 | `destination_hours` and exceptions, API, admin weekly grid, cards show hours | Low: new tables only |
| 3 | `destination_prices`, API, admin price table, budget labels supported/estimated/unknown | Low |
| 4 | `destination_activities`, API, admin activity list, cards show activities and unknowns, prompt/grounding rules about activity availability | Low |

Migration rules (from `docs/migrations.md` and past deploys): create the migration with Alembic, review the generated file, write a working `downgrade`, apply to **Neon first**, then deploy Render (Render does not run Alembic). Step 1's downgrade restores `NOT NULL DEFAULT false` after turning `NULL` into `false`, which loses the unknown/no distinction but loses no other data.

## 8. Testing

- Migration up/down on a copy of the catalog snapshot, with row counts compared.
- Constraint tests (`opens_at < closes_at`, price ≥ 0, enums, min ≤ max).
- Reader tests for tri-state flags: unknown never matches "accessible", never shows as "no".
- Retrieval tests: structured facts appear with the right `data_quality`; a stale date downgrades it.
- The stress script gets scenarios for hours on a given weekday, child pricing, an activity with unknown availability, and a place with no data (must say "not listed", never invent).

## 9. Decisions for you

1. **Accessibility backfill** (section 3): `false → NULL` (recommended) or keep as is.
2. **Verification granularity:** separate fees and hours pairs (proposed) or one source and date per place. One pair is simpler to enter but cannot say "hours checked in October, fees in March".
3. **Staleness threshold:** 12 months (proposed) or another value.
4. **Legacy text columns:** keep them as the permanent fallback (proposed) or retire them once every place is converted.
5. **Who enters the data:** you, in the admin app, as decided. Suggested order: places most shown in AI cards first, one step's fields at a time.
6. **Start with Step 1**, or begin with Step 2 (hours), which has no risk to existing data and gives the biggest visible gain on cards.

## 10. Out of scope here

Live opening status from external sources, user-submitted corrections, per-room accommodation data (the accommodation and transport rate tables stay as they are), and the itinerary timeline itself (designed after this).
