# Chat and Home redesign: less crowded, calmer, with motion

Written from the two screenshots (Home before chatting, Chat after "hi show me some beaches") and the current code in `apps/traveler_app/lib/screens/home_chat_screen.dart` and `lib/widgets/notifications_sheet.dart`. Nothing in this plan has been built yet, except the "1 DAYS" fix (section 1).

---

## 1. Already done: "1 DAYS"

The badge on a place header said "1 DAYS • RELIGIOUS LANDMARK". Fixed with one shared helper, `DayLabels` (`lib/core/day_labels.dart`):

| Where | Before | After |
|---|---|---|
| Place / trip header badge (trip screen, chat cards) | `1 DAYS • NATURE` | `NATURE` (a one-day visit says nothing useful about length); `3 DAYS • BEACHES` stays |
| Trip lists, profile, map header | `1 Days` | `1 Day`, `6 Days` |

Tests: `test/day_labels_test.dart`.

---

## 2. What is wrong with the two screens (from the screenshots)

**Home (idle)**
1. **Eight separate things compete in the top 60%:** header (3 controls), greeting, composer card (with 3 controls inside it), then three stacked pill buttons, then "Browse by category" and a chip row, then a mic button, then a floating nav bar.
2. **The starting place is shown twice** ("Start: 7.092°, 126.399° · Samal Is…" in the header and a "Start: 7.092°, 126.399°" pill below). Both show raw coordinates, which mean nothing to a traveler.
3. **Three actions that do almost the same thing** sit as equal-weight pills: starting place, "Things to do in Samal Island", "Surprise me".
4. **Heavy circular buttons** (hamburger, bell) with a white fill and a shadow draw the eye before the content does.

**Chat (active)**
1. **The reply is squeezed into about 35% of the screen.** The bottom 40% is permanently taken by "Browse by category" chips, the composer and the floating nav bar, so a result card is cut off after its second line ("Cost not listed." is the last visible text, and the card's buttons are hidden).
2. **Category chips keep showing while the traveler is reading a reply.** They are only useful before the first message.
3. **The compass logo appears three times** on one screen: next to the reply, inside the composer, and as the centre nav button.
4. **The reply card is dense:** category tag on a photo, name, region, time, a match reason, a distance estimate and a cost note all at the same size and weight.
5. **No clear separation between the traveler's message and the answer** other than colour; the user bubble is close to the header controls.
6. **White text on a busy photo** (palm tree, clouds) at the top: the status area and header icons lose contrast.

---

## 3. Design direction

**Principle: one primary thing per screen state.**
- Idle: *talk or type to Lakbay+*.
- Chatting: *read the answer*.
Everything else becomes quiet, secondary, or appears only when it helps.

Spacing on an 8 dp grid; 16 dp screen margin; 48 dp minimum tap targets (icons can be 24 dp inside a 48 dp area); body text 16, secondary 13/14, captions 12; two weights only (regular, semi-bold).

### 3.1 Header: remove the circles (decision made)
You asked me to choose. **Decision: plain icons, no circle, no border, no shadow.**
- Hamburger and bell become 24 dp white icons inside a 48 dp transparent tap area, with a ripple only on press.
- Legibility without the circle comes from a **soft dark gradient (scrim) behind the top 140 dp** of the photo, 35% to 0% black. This also fixes the status bar text.
- The unread badge becomes a small **solid dot** (or a number when more than 9) on the bell's top-right, not a pill.
- The starting-place pill stays, but is **one line, quiet** (no shadow), and shows a place name, not coordinates (see 3.2).
- Same treatment for the Trips tab bell, so the app is consistent (`NotificationBellButton` is shared).

### 3.2 Starting place: one place, named
- Keep **only the header pill**; delete the duplicate pill below the composer.
- Show the **place name** ("Tubaon, Tarragona") and fall back to "Set starting place" when unknown. Coordinates only appear inside the picker.
- Tapping it opens the existing origin picker sheet.

### 3.3 Home (idle) layout, top to bottom
1. Header (icons + start-place pill), over the scrim.
2. Greeting, left aligned, **smaller** (28 sp, two lines max): "Hi John, where to next?" (the highlighted "wake up" chip is dropped).
3. **Composer** (the one prominent card): text field, `+`, and the send/"Plan it" button. "Within budget" moves **inside the `+` menu** as an option, not a permanent chip.
4. **Two suggestion chips**, not three, in one horizontal row: "Things to do in <current area>" and "Surprise me". Chips are outlined, no fill, so they read as suggestions.
5. **Browse by category** becomes a single horizontally scrolling row with a small heading, directly under the chips. It is the *only* place category chips appear on this screen.
6. The big **mic button** becomes a mic icon **inside the composer** (replacing the third compass), freeing about 220 dp of vertical space.
7. Bottom nav (see 3.6).

### 3.4 Chat (active) layout
1. The greeting, suggestion chips and category row **collapse away** (animated, 200 ms) once there is a message. Browse by category is reachable from the composer's `+` menu instead.
2. The message list fills from under the header to just above the composer. Messages scroll **under** a short fade at the top and bottom edges rather than being clipped.
3. **User bubble:** right aligned, max 80% width, 12 dp corner radius, 8 dp vertical gap. **Answer:** a single left-aligned surface, no avatar beside every message; the small compass appears once at the start of each answer, 20 dp, not 40 dp.
4. **Result cards** (the part that is crowding you most):
   - Horizontal **carousel** of cards, each about 78% of the screen width so the next card peeks in.
   - Card content, in order: photo (16:9) with the category tag, **name** (semi-bold 16), **one line** "Davao Oriental · about 34 min by car", then a **single price line** ("Cost not listed" or "From ₱150"). The match reason ("Matches beach, beach resort") moves behind a "Why this?" tap.
   - Two buttons at the bottom of the card: **View** and **Add to trip**, always visible without scrolling.
   - The distance wording stays honest ("straight-line estimate") but only in the detail view, not on the card.
5. **Composer** stays pinned; it shrinks to 56 dp and loses the left compass.
6. After the answer, **2 follow-up chips** appear above the composer (for example "Show waterfalls", "Within my budget"); they disappear when the traveler starts typing.

### 3.5 What goes away or moves
| Item | Now | Proposed |
|---|---|---|
| Header circles | white circle + shadow | none (plain icons + scrim) |
| Duplicate start pill | header and below composer | header only, with a place name |
| "Within budget" chip | always visible | inside the composer's `+` menu |
| Third suggestion pill | three pills | two |
| Browse by category in chat | always visible | idle screen only; `+` menu in chat |
| Big mic button | 120 dp circle | icon inside the composer |
| Compass logo | 3 per screen | 1 (centre nav) plus one small mark per answer |

### 3.6 Bottom navigation
- Keep five destinations and the raised centre Chat button.
- Make the bar **shorter** (64 dp content) and **auto-hide while scrolling the chat down**, returning on scroll up or when the keyboard closes. While the keyboard is open it is already hidden; keep that.
- Selected tab: filled icon + label in the brand colour; others: outline icon + label in 60% opacity. No pill background.

---

## 4. Animation: what is best for this app

The app is a **map and place explorer** with a **chat** at its centre. Motion should explain *where things came from*, stay quick, and never delay the next tap. Recommended set (Material 3 motion, which Flutter supports directly):

| Moment | Animation | Time | Why |
|---|---|---|---|
| **Switching bottom tabs** | **Fade-through** (old fades out, new fades in with a 4% scale-up) | 250 ms | Tabs are siblings, not parent/child; a slide would imply a direction that does not exist. |
| **Tapping a place card → place screen** | **Container transform** (the card grows into the place screen, photo keeps its position) | 350 ms | The strongest cue that "this card became that page"; fixes the feeling of a page just replacing another. Uses the official `animations` package (`OpenContainer`). |
| **Pushing deeper screens** (route map, commute directions) | **Shared axis, horizontal** | 300 ms | Clear forward/back direction. Already close to the fade-forwards transition set in Phase 7. |
| **Bottom sheets** (notifications, origin picker, budget) | Slide up with a fading scrim, drag to dismiss | 250 ms | Familiar and spatially correct. |
| **New chat messages** | Fade + 12 dp slide up, **staggered 60 ms** per item (user message first, then the answer, then each card) | 200 ms each | Makes a long answer arrive in a readable order without a spinner. |
| **Home idle → chat** | The greeting and chips **collapse** (height + fade) while the message list expands | 220 ms | Shows the screen *changing job*, not jumping. |
| **Typing / AI working** | Three-dot "thinking" indicator inside the answer position (replaces any spinner) | loop | Keeps the traveler's place. |
| **Add to trip** | Button swaps to a check mark with a small scale pulse; the tray badge bounces once | 200 ms | Confirms the tap without a snackbar. |
| **Pull to refresh** | Already added in Phase 1 | | |

Rules for all of it:
- **Curves:** emphasized decelerate for things entering, accelerate for leaving; never linear.
- **Durations:** 150 to 350 ms; nothing over 400 ms.
- **Respect "Remove animations"** in Android settings (`MediaQuery.disableAnimations`): fall back to instant changes.
- **Budget:** hold the Phase 7 numbers (under 5% slow frames while scrolling; no frame over 32 ms), measured again on the phone after each motion change.

Why not the alternatives: a plain slide for everything feels slow on a 120 Hz phone and hides the page behind it; heavy parallax and long hero flights cost frames and delay the next tap.

---

## 5. Implementation plan

Each phase ends with tests, a phone check and its own branch and commit, as before.

### Phase 0: Baseline (half a day)
- Take "before" screenshots of Home (idle), Chat (answer with 1 and 3 cards), Trips, Discover at 1080 × 2460 and a small 720 × 1280 size.
- Record frame stats for the chat scroll with the existing SurfaceFlinger script, so "after" can be compared.

### Phase 1: Header and quick wins
- `NotificationBellButton` and the hamburger: remove the circle, border and shadow; 48 dp tap area; solid unread dot.
- Add the top **scrim gradient** to the Home/Chat background.
- Delete the duplicate start-place pill; show a place name (reverse label) instead of coordinates; keep the pill in the header only.
- Tests: widget tests for the bell badge, the start pill label, and that only one start control exists.

### Phase 2: Home (idle) layout
- Smaller greeting, drop the highlighted "wake up" chip.
- Composer with `+` menu (Within budget, Add place, Browse categories), mic inside the composer.
- Two suggestion chips; one category row.
- Tests: idle screen shows exactly one composer, at most two chips, one category row; the budget option lives in the menu and still changes the plan request.

### Phase 3: Chat layout and result cards
- Collapse greeting/chips/categories on the first message (animated).
- New card widget: photo, name, one info line, one price line, **View** and **Add to trip**; horizontal carousel; "Why this?" bottom sheet for the match reason.
- One small mark per answer; remove the avatar beside every bubble.
- Follow-up chips after an answer.
- Tests: card shows a price line or "Cost not listed" and never a made-up value; both buttons visible on a 360 dp wide screen; carousel scrolls; chat history still restores.

### Phase 4: Composer and bottom nav
- 56 dp composer, left compass removed; auto-hide nav on chat scroll; unselected tabs at 60% opacity, no pill.
- Tests: nav hides and returns; keyboard behaviour unchanged.

### Phase 5: Motion system
- Add `animations` (official package) and a small `lakbay_motion.dart` holding the curves, durations and the transition builders.
- Tab fade-through; container transform for place cards; shared-axis for pushed screens; staggered message entrance; collapse/expand for Home→Chat.
- Reduce-motion fallback everywhere.
- Tests: with animations disabled, screens still show the right content; frame-budget run on the phone.

### Phase 6: Accessibility and polish
- Contrast check of text over the photo (target 4.5:1), larger text (1.3×) layout check, TalkBack labels on the icon-only buttons, 48 dp targets.
- Small-screen (720 × 1280) pass: nothing overlaps, composer never hides behind the nav.

### Phase 7: Verify on the phone
- "After" screenshots beside the "before" ones, frame stats, a written checklist like `docs/PHASE8_VERIFICATION.md`.

**Files expected to change:** `lib/screens/home_chat_screen.dart` (largest), `lib/widgets/notifications_sheet.dart`, `lib/main.dart` (nav bar), `lib/theme/lakbay_theme.dart` (transitions), a new `lib/widgets/chat_place_card.dart` and `lib/core/lakbay_motion.dart`, plus tests. No server or database changes.

---

## 6. Decisions I need from you

1. **Header icons:** plain icons with a top scrim (my recommendation), or keep a very light circle on press only?
2. **"Within budget" inside the `+` menu:** OK, or should it stay visible as a chip?
3. **Category browsing in chat** reachable from the `+` menu only: OK?
4. **Result cards** as a carousel with **View** and **Add to trip** (and the match reason behind "Why this?"): OK?
5. **Adding the official `animations` package** (small, maintained by the Flutter team) for the card-to-page transition: OK?
6. **Order:** I suggest 1, 2, 3 first (the congestion), then 4, 5, 6.
