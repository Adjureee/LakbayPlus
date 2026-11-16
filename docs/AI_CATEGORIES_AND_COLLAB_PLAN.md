# Categories, a reliable itinerary step, group notifications, memories, AI language, fallbacks and onboarding

Date: 2026-11-16 · Status: **implemented across Phases 1–8** · Based on `main` at `efab430`
Follows `docs/AI_CHAT_ITINERARY_PLAN.md` (all six phases are merged).

Reported so far:

1. The AI should recognize **every place category in the admin database** and show matching places as cards.
2. "I couldn't build an itinerary from your picks just now. Please try again." keeps appearing.
3. For **collaborate and shared tasks**: when someone is invited, where are they notified, and is there a notifications feature?
4. **Memories:** fix the bug; where can travelers upload their memories?
5. A **language setting for the AI itinerary**.
6. The **AI fallback must work every time**, including when planning a trip from the **Davao Region Encyclopedia** in Explore.
7. **Remove Payment and Connected apps** from Settings.
8. Ask for the **location permission in onboarding**.
9. Make the **onboarding AI** a high-grade trip planner, like Layla, and not deterministic.

"Encyclopedia" is read here as the **Davao Region Encyclopedia** section of the Explore tab (city guides with a "Plan Trip" button). Tell me if you meant something else.

Evidence below comes from the live database (read-only) and the code. No data was changed.

---

## Findings

### A. Categories: the AI knows a fixed list, not what is in the database

The live catalog has **41 active places in 24 distinct categories**:

| Places | Category | Preference group today |
|---|---|---|
| 4 | beach resort | beaches, resorts |
| 4 | museum | culture |
| 4 | waterfall | nature |
| 3 / 3 | beach / resort | beaches / resorts |
| 2 each | church, mountain resort, nature park, nature reserve | culture / nature+resorts / nature / nature |
| 1 each | farm, flower farm, hot spring, island, lake park, mountain, nature resort, religious landmark, scenic cape, sea of clouds viewpoint, water park, wildlife | nature, culture, resorts |
| **1 each** | **`park`, `city park`, `Park / Public Plaza`** | **no group at all** |

What this means:

- **3 places (7%) can never come up from a preference chip**, and a new category an admin adds tomorrow will not either. The groups live in a static file (`data/preference_groups.json`), not in the database.
- The AI prompt lists `available_interests` from that same file, so the model does not know about categories the file lacks. Free-text words still match a category by text, which is why "park" mostly works by accident and "museum" works by design; nothing guarantees either.
- Category spelling is free text in the admin app ("beach resort" vs "Beach Resort" vs "Park / Public Plaza"), so the same kind of place can split into several categories.
- The app shows cards only after the AI's reply. There is no way to browse a category without spending an AI call.

### B. "I couldn't build an itinerary from your picks": the server is rate-limited, then the fallback fails

From `ai_generation_runs` (all-time: **17 itinerary generations failed, 9 succeeded**; the recent ones show one pattern):

```
chat call        gpt-oss-120b   succeeded
itinerary call   gpt-oss-120b   FAILED  "Groq rate limit reached"      (not run)
itinerary call   gemini-flash   FAILED  "AI output was not valid JSON" (fallback)
```

| Failure | Count | Cause |
|---|---|---|
| Primary model rate limit, then fallback invalid JSON | 8 + 6 | Groq limit hit, weaker fallback cannot produce valid JSON |
| Model rejected / server error / output failed validation | 3 | Occasional |

Why it happens:

1. **Two model calls back to back.** "Plan with N picks" sends a chat message (about 2.7k tokens), and as soon as it returns the app calls itinerary generation (2.6k to 4.5k prompt tokens plus up to 4k output). Together they exceed Groq's per-minute token budget.
2. **The server asks for 5 options** (`AI_ITINERARY_OPTION_COUNT` default is 5). A successful run produced about 3,800 output tokens against a cap of 4,096, so five options are one long sentence from truncation. A truncated JSON object is "not valid JSON".
3. **The fallback model fails more often.** Generation on `gemini-3.5-flash-lite` failed 6 times and succeeded 3.
4. **The app hides the reason.** `generateAiItineraries` returns `null` for any non-2xx answer, so a rate limit, an over-budget plan and a broken model all show the same sentence, and nothing says when to retry.
5. **A real bug in waiting:** `planning_input_mismatch` (HTTP 400) is returned when the request budget differs from the plan's whole-trip budget. If the budget scope is "per person", the app sends the per-person figure, so generation is refused. This has not appeared in the logs yet, but the code path is certain.
6. `planning_over_budget` (409): several picks can cost more than the budget; the traveler gets the same generic sentence instead of "raise your budget or remove a place".

### C. Collaboration and notifications

**There is a notifications feature, and it works for invitations.** What exists today:

| Event | Who is notified | Where they see it |
|---|---|---|
| Invited to a trip | The invited traveler (with Accept / Decline) | Bell icon on the **Chat** tab; checked every 60 s and when the app returns to the foreground |
| Invitation accepted / declined | The trip owner | Same bell |
| Task assigned | The assignee | Same bell |
| Expense added / changed / voided, trip edited, route saved | Every active member except the actor | Same bell |

Gaps found:

1. **Task notifications never reach anyone.** Creating a task always assigns it to `_members.first`, which is the owner, so the assignee is the person who created it. The server rightly skips notifying you about your own action. **An invited member is never assigned a task from the app**, so they are never notified. There is no "assign to" control at all.
2. **Expenses are always "paid by" the first member** (the owner); there is no payer choice.
3. **Signed-out and unsynced trips show invented local data**: a local-only task and expense list, and a local expense with `paidByTripMemberId: 1`. Members only exist once the trip is saved to the account.
4. **The bell exists only on the Chat tab.** There is no badge on the bottom navigation and none on My Trips, where Collaborate is opened.
5. **Nothing arrives when the app is closed.** There is no push (FCM) or email, only polling while the app is open. This is the open decision from the earlier plan.
6. Tapping a task or expense notification does nothing useful; only trips you already own open.

### D. Memories: hard to find, easy to lose

Where a traveler can upload today: **Memories tab, "Add Photo"** (or "Upload First Memory" when empty). Nowhere else; the trip screen has no "add a memory".

What is wrong (found in code; to be reproduced on a phone in Phase 5):

1. **A saved trip is required first.** With no saved trip the only response is a snackbar, "Save a Davao Region trip first before adding memories." A traveler who just wants to post a photo cannot.
2. **Silent local copy.** If the cloud path fails for any reason other than an error the server explains (the trip has no destination to create it with, the server returns nothing, or the traveler is a guest), `uploadAndAddMemory` stores the photo **only on the phone** and shows it as saved. It is never uploaded, so companions never see it, and it is lost on reinstall. The traveler is not told.
3. **Server rules the app does not explain.** Only an **active** member can post (an invited-but-not-accepted member cannot), archived trips are read-only, and the memory's place must belong to the trip. Each returns a plain error the app shows as "Failed to save memory: …".
4. **Likes are optimistic.** The count goes up on the phone first and a failed request is ignored, so the number can be wrong.
5. The upload has a 30-second limit and no progress; large photos on mobile data can time out. The image is already reduced to 1600 px, which helps.

### E. AI language

Settings has a **Language** row (English, Filipino, Cebuano, Spanish, French), but it only changes app text. It is **not sent to the AI**. The chat prompt says "reply in the traveler's language", which works by guessing from the message. The **itinerary prompt has no language instruction at all**, so itineraries are always English. The trip-draft prompt guesses like chat does.

### F. "Plan Trip" depends entirely on the AI

The Encyclopedia's "Plan Trip" and the Explore search "Plan a trip to X" buttons now open the AI chat (that replaced the invented 4-day template). If the AI is rate-limited or down, the traveler gets an error and **no plan**. There is no step that still works without the AI. The app already has a deterministic planner that needs no AI: the trip tray, the Explore plan sheet (lock first stop, must-visit, pace, live recalculation) and the server's route and budget preview, all using real catalog data. It is just not connected to these buttons as a fallback.

### G. Settings shows things that do not exist

- **Payment** ("Set at checkout"): the app has no checkout, booking or payment, so this row does nothing useful.
- **Connected apps** ("Lakbay AI + Mapbox", "Pending .env"): developer diagnostics that travelers should not see.

### H. Location permission is skipped on the main path

The onboarding screen has a "First, share your location" step, but it is the **last step of the non-AI path**. The main path ("I have a trip") jumps straight into the AI onboarding chat and skips it. The permission is then requested out of the blue when the app opens for the first time (`autoDetectLocationOnShellEntry`), and the AI chat asks "where are you starting from?" without having tried the GPS.

### I. The onboarding AI is a script with an AI bolted on

`yes_ai_onboarding_flow.dart` (1,500 lines):

- Opening lines are chosen at random from a fixed list; the first options are fixed chips.
- The "inspire me" cards are **hard-coded with invented data**: dates "Dec 14", temperatures "29°", prices "₱5,400".
- Destination is guessed by keyword (`mati`, `buda`, `apo`, `samal`), and the five-step flow (vibe, party, dates, game plan) is a fixed script with fixed options. It runs **whenever the AI call fails**, without telling the traveler.
- "Looks perfect" is detected by matching text.
- It uses the one-shot `trip-draft` call, not the planning chat the main chat uses, so it has no saved preferences, no Top 5 cards with reasons, no picks and no "one question at a time". Guests cannot call the validated itinerary generator, so it can only ever produce a loose draft.
- Copy claims "Your travel expert checks it" (already removed in Phase 6).

---

## Target design

### 1. Categories from the database (single source of truth)

- `GET /destinations/facets` gains **`categories`**: every distinct category in the live catalog, normalized, with its place count and its group. Computed from the database on each request (cached about 60 s), so a new admin category appears with no deploy.
- **Normalization:** lower-case, trim, singular/plural (`waterfalls` to `waterfall`), a small synonym file `data/category_aliases.json` (for example `falls`, `cascade` to `waterfall`), and a fuzzy fallback (shared word) for categories nobody has listed yet.
- **No orphan places:** add a `parks_recreation` group (park, city park, public plaza) and an automatic **Other** bucket for any category no group claims. A review script warns when a place lands in Other.
- **The AI is told the live list** (`available_categories`) instead of a fixed file, with place counts and two example names each.
- **Browse without AI:** a "Browse by category" row of chips in the chat, from the facets. Tapping one asks the server for the top places (up to 5, ranked) and shows cards immediately, with no model call. This also saves rate limit.
- **Admin app:** the category field becomes a dropdown/autocomplete of existing categories (with "add new"), and a banner shows categories that belong to no group.

### 2. A reliable itinerary step

- **Remove the double call.** "Plan with N picks" goes straight to itinerary generation when the details are known (days, party, budget). The chat model is used only to ask for a missing detail.
- **Two options by default** (`AI_ITINERARY_OPTION_COUNT=2`, differing by pace and focus on the same picks). Smaller output, faster, far less likely to truncate.
- **Compact output** (new prompt below) and a higher token cap for this call only.
- **Rate-limit handling:** honor `Retry-After` (wait up to about 10 s on the server for generation), then the app retries once on its own and shows "The AI is busy, trying again…".
- **Fallback that works:** repair truncated or fenced JSON before giving up, and retry once with a "JSON only" nudge on the same model.
- **Show the real reason** (typed errors from the app's API layer):

| Server code | What the traveler sees |
|---|---|
| `groq_rate_limit_exceeded` | "The AI is busy. Trying again in N seconds…" (auto retry once) |
| `planning_over_budget` | "Your picks cost more than your budget. Raise the budget or remove a place." with buttons |
| `planning_input_mismatch` | Fixed in code (send the plan's whole-trip budget); should not reach the traveler |
| `ai_generation_failed` | "I couldn't draft that one. Try again" with a Retry button |

- **Run report:** `scripts/ai_run_report.py` summarizes recent failures by cause, so this can be watched instead of guessed.

### 3. Collaboration that actually notifies

- **Assign to** picker on every new task (members who accepted; default "Unassigned"), the assignee's name on each task, and an "Assigned to me" filter.
- **Paid by** picker on expenses (default: me). The member id comes from the signed-in user, never a placeholder.
- **Remove invented local data**: unsynced trips show "Save this trip to your account to invite companions and share tasks", not a fake list.
- **Notifications everywhere:** the bell on Trips and Chat, an unread badge on the bottom navigation, and a tap that opens the right place (an invitation shows Accept / Decline; a task opens the Collaborate sheet on Tasks).
- **Pending invitations** show "Resend" for the owner.
- **Push when the app is closed:** needs your decision (see below). Until then the app polls every 60 s while open.

### 4. Memories that cannot silently fail

- **Upload from three places:** the Memories tab, an "Add memory" button on every trip the traveler is an active member of, and a prompt after a trip ends.
- **No trip yet?** The sheet says so and offers "Plan a trip" instead of a dead-end snackbar (see decision 6 about memories that belong to no trip).
- **Never a silent local copy.** A photo that has not reached the server is shown with a clear **"Not uploaded yet. Retry"** state in a small outbox, and is removed from it only when the server confirms. Guests are told to sign in.
- **Say why** for each server rule: an invited member sees "Accept the invitation to add photos"; an archived trip says it is read-only.
- A progress bar, a longer limit for slow connections, and one automatic retry.
- Likes change the count only when the server confirms (or roll back).

### 5. AI language

- A new **AI language** setting, separate from the app language: **Auto** (answer in the language I write in, the default), English, Filipino, Bisaya/Cebuano, plus Spanish and French as the app already lists.
- A `language` field on the chat, guest chat, trip-draft and itinerary requests, validated against that list and saved with the traveler's preferences.
- The prompts apply it (see "Improved prompts"): every sentence meant for the traveler is in that language; JSON keys and fixed values stay English; place names stay as the catalog spells them.
- An itinerary is saved in the language it was written in. Translating an existing one is out of scope; the traveler regenerates it.

### 6. A planner that works every time

Layers, in order; the traveler always ends with a plan:

1. The main model, waiting for `Retry-After` and retrying once (Phase 1).
2. The fallback model with JSON repair and a "JSON only" nudge (Phase 1).
3. **A planner that needs no AI.** A server endpoint `POST /planning/draft` (guests and signed-in travelers) that ranks candidate places with the same scoring, orders them by the route, packs days using each place's visit length and the travel times, and prices them from the catalog. It returns the same itinerary shape and is labelled **"Built from Lakbay's catalog, without AI"** with an **"Improve with AI"** button. Unknown prices stay "not listed"; nothing is invented.
4. In the app, the **Encyclopedia "Plan Trip"** and the Explore search button first gather the city's real places (by district) and open the existing Explore plan sheet already filled in, which works even offline from the bundled catalog. "Improve with AI" is the optional second step, so these buttons never depend on the AI.

### 7. Settings cleanup

Remove the **Payment** and **Connected apps** rows and sheets, the `preferredPaymentMethod` field and its saved value (old saved state is ignored). The connection status moves to a diagnostics screen shown only in debug builds.

### 8. Location permission in onboarding

- Make the location step part of **every** onboarding path, **before** the AI chat.
- A short rationale first ("Lakbay uses your location to find places near you and estimate travel time. You can change this any time."), then **Allow location** (the system prompt) or **Not now, I'll choose a starting place**.
- Denied: go straight to the search-or-pin starting place sheet. Denied permanently: explain how to turn it on, with a button to open the app's settings.
- The AI receives the result (coordinates and a place name) so it never asks where the traveler is when it already knows.
- Remove the surprise prompt on first opening the app; refresh quietly only if permission was already granted. Settings shows the status and an "Open app settings" button.

### 9. An onboarding planner like Layla

"Like Layla" here means what travelers expect from a good AI trip planner: **a conversation, not a form**; one question at a time; places shown as rich tappable cards; a trip that visibly builds as they answer; changes by chat ("make it more relaxed", "add a waterfall"); short reasons for every suggestion; and never a dead end.

How it is built (reuse, not another script):

- Run onboarding on the **same planning chat engine** as the main chat: saved plan state, the stages (collect, recommend, picking, generate, refine), Top 5 cards with reasons, the nature questions, picks, itinerary options, the AI language and the location result. One engine to improve, one behavior to test.
- A dedicated **onboarding prompt** (below): warmer, first-run aware, tells the traveler what it can do, and shows something useful after at most three questions.
- **Everything comes from data.** The opening message is written by the AI from what is known (language, location, time of day); quick-reply chips come from the AI plus the live category chips; place cards come from the catalog (real photo, category, price only when listed). The invented "Dec 14", "29°" and "₱5,400" cards, the keyword matching, the fixed vibe/party/date options and the scripted offline flow are deleted.
- **A live trip preview** above the chat (places, days, budget, route) updates after each answer.
- **Guests get a real itinerary.** Add `POST /ai/itineraries/generate/guest` (strict per-device limits, nothing saved) so onboarding ends with a validated itinerary and "Save to your account" at sign-up. See decision 7.
- **If the AI is down:** the planner from section 6. The traveler picks 2 to 5 real places and gets a plan; there is no scripted detour.
- Tested with first-run personas: an unsure traveler, a traveler with a specific plan, a Bisaya speaker, a family with kids, and a nature lover.

---

## Improved prompts

### Chat prompt (`phase5_chat_v12_live_categories`), added text

```
available_categories lists every kind of place in the Lakbay catalog right now:
[{key, label, count, examples}].
- When the traveler names a kind of place in any wording or language (English,
  Filipino, Bisaya; singular or plural; "falls", "talon", "museo", "swimming"),
  map it to the closest `key` and answer with intent "show_places" and
  place_query.categories set to that key. Use only keys from the list; never
  invent one.
- A place word that fits two keys (for example "resort"): use both.
- If the matching category has count 0, or nothing in the list fits, say plainly
  that Lakbay has no places of that kind listed, and offer the two closest
  categories by label. Do not describe places that are not in
  retrieved_lakbay_context.
- Record the traveler's lasting preference in state_updates.interests using the
  group `key` from available_interests, not free text.
- Show at most 5 places. The app draws the cards; do not list them in prose.
```

### Itinerary prompt (`phase15e_picks_compact_v7`), changed text

```
Return exactly {option_count} options as ONE JSON object, nothing before or after,
no markdown. Keep it compact: activity `description` at most 140 characters,
`notes` at most 80 characters or null, day `summary` one sentence. Never drop a
selected destination to save space; shorten the wording instead.
Use only the destinations in the request. Options share the same places and differ
only in pace and focus, taken from traveler_preferences. State the difference in
the option `summary`. If something is unknown, write null; do not guess prices,
times or opening hours.
```

### Retry nudge (sent once, on the same model, when the first answer is not valid JSON)

```
Your last answer was not valid JSON. Return the same itinerary again as a single
JSON object that matches the schema exactly, with shorter descriptions. No prose.
```

### Language rule (chat v12, itinerary v7 and trip-draft), added text

```
The request has `language`. If it is "auto", write for the traveler in the language
of their latest message (English, Filipino or Bisaya/Cebuano) and keep using it.
Otherwise write in that language: {language_label}.
Everything meant for the traveler is in that language: chat_response, titles,
summaries, descriptions, notes and suggested_replies. Keep JSON keys, enum values,
ids and intents in English exactly as the schema shows. Keep place names as the
catalog spells them. Write money as ₱ with digits. Do not mix languages inside one
sentence, except common local words (for example "salamat") when they fit.
```

### Onboarding prompt (`onboarding_v1`), added to the chat prompt when the app says it is the first run

```
This traveler is opening Lakbay for the first time. Be a warm, curious trip planner,
not a form.
- Open by greeting them in their language, say in one sentence what you can do
  (find places that match what they like, pick a few, and draft a day-by-day plan),
  and ask ONE easy question. If `known.location` is set, use it and never ask where
  they are; if not, ask for a starting place once.
- Ask at most three questions before showing something useful. After the first
  answer that names a place, a mood or a kind of trip, show up to 5 places.
- One question per message. Never ask for something already in planning_state.
  Offer 2 to 4 tappable replies written in their voice, specific to this
  conversation (never generic).
- Give a short reason for every suggestion tied to what they said ("quiet, easy
  trail, close to Davao City"). Say plainly when a detail is not listed.
- When they pick places, confirm them by name and offer to build the plan. When they
  ask to change something, change only that and say what changed in one sentence.
- Never invent places, prices, dates, temperatures or opening hours.
- If you cannot continue, say so briefly and ask them to pick from the places shown.
```

---

## Implementation plan

Each phase ends with tests and a commit on its own branch. Order matters: later phases reuse the earlier ones.

### Phase 1: Itinerary reliability and AI language (API, then app)
- Server: option count default 2; compact itinerary prompt v7; JSON repair and one retry; wait for `Retry-After` up to about 10 s; higher token cap for generation.
- Server and app: the `language` field on chat, guest chat, trip-draft and itinerary requests; the AI language setting (Auto by default); language rule in all prompts.
- App: skip the chat call on "Plan with N picks" when details are known; typed errors from `generateAiItineraries`; one automatic retry on rate limit; per-reason messages and buttons; send the plan's whole-trip budget.
- `scripts/ai_run_report.py`.
- Tests: fake model returns rate limit then invalid JSON, truncated JSON, valid on retry; per-person budget; over-budget message; language is sent and appears in the prompt; app error mapping.

### Phase 2: A planner that works every time (API, app)
- Server: `POST /planning/draft` (no AI): ranking, route order, day packing from visit lengths and travel times, catalog prices, same itinerary shape, labelled as built without AI.
- App: automatic fall-through when the AI fails after its retry ("AI is busy, here's a plan from Lakbay's catalog"); "Improve with AI" button.
- App: Encyclopedia "Plan Trip" and the Explore search button gather the city's real places and open the Explore plan sheet already filled in (works offline).
- Tests: both models fail and a plan is still returned; Encyclopedia button with the AI mocked down; offline from the bundled catalog.

### Phase 3: Categories from the database (API, admin, app)
- Facets with live categories; normalization and `category_aliases.json`; `parks_recreation` group and an Other bucket; `available_categories` in the chat prompt (v12).
- App: "Browse by category" chips and a no-AI category endpoint; cards from it.
- Admin: category dropdown/autocomplete and the "not in any group" banner.
- Tests: all 24 current categories resolve to a group; singular/plural/synonym/fuzzy; a brand-new category appears in facets; 24 category cases added to `chat_eval_davao.json`.

### Phase 4: Settings cleanup and location in onboarding (app)
- Remove Payment and Connected apps (rows, sheets, the saved field); debug-only diagnostics screen.
- Location step before the AI chat on every path, with the rationale, denied and permanently-denied handling, and an "Open app settings" button; remove the surprise prompt on first launch.
- Tests: each permission outcome (allowed, denied, permanently denied) leads to a working starting place; no Payment or Connected apps text; old saved state still loads.

### Phase 5: Memories (app, small API change)
- Add-memory entry points on the Memories tab, every trip screen and after a trip ends.
- Outbox with "Not uploaded yet. Retry"; no silent local copy; messages for pending members and archived trips; progress and a longer limit; likes confirmed by the server.
- First, **reproduce the failure on a phone** and record the exact error, because the code review lists several possible causes.
- Tests: upload succeeds; server refuses (pending member, archived trip, wrong place); no network; retry; like rollback.

### Phase 6: Collaboration and notifications (app, small API change)
- Assign-to and paid-by pickers; assignee shown; remove invented local data.
- Bell on Trips and Chat, nav badge, tap routing by event type; Resend invitation.
- Tests: a task assigned to an accepted member notifies them; expense payer; tap routing.
- Optional: push (needs a decision).

### Phase 7: Onboarding planner like Layla (app, API)
- Onboarding on the planning chat engine with the onboarding prompt; live trip preview; AI-written opening and chips; catalog cards; refine by chat.
- `POST /ai/itineraries/generate/guest` (or the Phase 2 planner for guests).
- Delete the scripted flow, the invented cards, keyword matching and fixed options.
- Tests: widget tests for first message, chips, cards, pick, itinerary, failure fallback; eval cases for the five first-run personas.

### Phase 8: Prompt evaluation
- Run `manual_chat_eval.py` before and after, compare totals, and record the result in this file.

Suggested order: **1, 2, 3, 4** (what travelers hit most, and the planner everything else falls back to), then **5, 6**, then **7** (the largest, built on 1 to 4), then **8**.

## Decisions needed

1. **Option count:** 2 (recommended, reliable) or 3.
2. **Push notifications when the app is closed:** Firebase Cloud Messaging (needs a Firebase project and `google-services.json` from you, Android only), an email provider, or keep in-app polling only. Recommendation: FCM.
3. **Parks:** a separate group (recommended) or fold them into Nature attractions.
4. **Admin category field:** a dropdown of existing categories with "add new" (recommended) or free text.
5. **"Plan with N picks"** skips the chat model when details are complete (recommended), or keeps one short model reply first.
6. **Memories with no trip:** keep "a memory belongs to a trip" and guide the traveler to plan or save one (recommended, no database change), or allow personal memories that belong to no trip (needs a database change and your approval under `AGENTS.md`).
7. **Guest itinerary in onboarding:** a rate-limited guest generation endpoint (recommended, best quality) or use the no-AI planner only for guests.
8. **AI languages:** Auto, English, Filipino, Bisaya, Spanish and French (as the app lists today), or only the first four.
9. **"Encyclopedia":** confirm it means the Davao Region Encyclopedia in Explore.

---

## Phase 8 — Prompt Evaluation & Final Regression Verification

Updated `services/api/tests/manual_chat_eval.py` (added `is_onboarding` forwarding, `cards` count metric, `LAKBAY_EVAL_OFFSET`, `LAKBAY_EVAL_FILTER`, `LAKBAY_EVAL_DELAY`, and eval-only user limiter headroom) and added 5 onboarding persona cases (`onb-vague-explorer`, `onb-island-hopper`, `onb-mountain-hiker`, `onb-budget-traveler`, `onb-off-path-adventurer`) to `services/api/tests/fixtures/chat_eval_davao.json` (total 89 eval cases).

Live model evaluations (against configured `openai/gpt-oss-120b` + `gemini-3.5-flash-lite` fallback) surfaced three issues that were fixed cleanly in `prompts.py` and `service.py`:
1. `ask_next` was overriding `"show_places"` / `"Inspire me!"` requests with `"What kind of places do you enjoy?"` (`intent="question"`, hiding cards). Updated `prompts.py` + `onboarding_v1` with concrete JSON examples so browse and inspire turns emit `"show_places"` + matching `place_query` first.
2. Broad browse queries (`"Show me nice beaches"`, `"Show mountain resorts around Buda"`) were implicitly filtered to the origin label `"Davao City"`; scoped automatic origin-province filtering in `service.py` to explicit proximity queries (`"near me"`, `"nearby"`, `"around here"`, `"here"`, `"closest"`).
3. Added tolerant outer JSON extraction in `_strip_json_fence` and defaulted omitted `state_updates` to `{}` in `_parse_planning_chat_output` so valid fallback replies are preserved while retaining all validation guardrails.

### Live Chat Eval Results (`tests/manual_chat_eval.py`)

| Slice | Metric | Before prompt/routing fix | After fix |
|---|---|---|---|
| Onboarding 5 personas (`onb-`) | `cards` | `1/5` | `4/5` |
| Onboarding 5 personas (`onb-`) | `valid` / `intent` / `content` / `interest` / `style` | `5/5`, `2/5`, `5/5`, `5/5`, `5/5` (`88%`) | `5/5`, `5/5`, `5/5`, `5/5`, `5/5` (`100%`) |
| First 12 categories baseline (`cat-`) | overall | `68%` (10 run, 2 local `429`) | — |
| All 24 DB categories post-fix (`cat-`) | `cards` / `valid` / `intent` / `content` / `interest` / `style` | — | Combined 20 non-429 (`task-8245`) + 4 remaining (`task-8252`): `22/24` cards, `23/24` valid, `22/24` intent, `21/24` content, `24/24` interest, `24/24` style |

### Final Regression Suites (Post-Edit)

- **Backend (`services/api`)**: `.venv\Scripts\python.exe -m pytest -q` → **876 passed, 1 skipped**.
- **Traveler App (`apps/traveler_app`)**: `dart analyze` → **No issues found!**; `flutter test --no-pub -j 2` → **148 passed** across all 22 test files.
- **Admin App (`apps/admin_app`)**: `flutter test --no-pub` → **62 passed**.

