# Profile, chat history and smarter AI cards: investigation and plan

Status: plan only. Nothing has been changed in the code. Backend rules (`services/api/AGENTS.md`) require your approval before code changes, and the cover photo needs a database migration, which needs a separate approval.

## Part 1. Your requests, and what the code shows

| # | Request | What I found | Plan |
|---|---|---|---|
| 1 | Remove "Account" in Profile (sign out is already in Settings) | `profile_screen.dart:290-323` has an ACCOUNT section whose row signs out in one tap, with no confirmation. Settings already has a confirmed "Log out" (`settings_screen.dart:189`). The same row is also the only "Create account / Sign in" entry for a signed-out traveler. | Remove the row when signed in. When signed out, keep a single "Sign in to sync and save" row so guests are not locked out. Drop the "ACCOUNT" heading either way. |
| 2 | Remove "PHP >" | It is the trailing text on the Profile "Settings" row (`profile_screen.dart:353`). Currency is already changeable inside Settings. | Delete `trailingText` on that row. Currency stays in Settings only. |
| 3 | Let users add a cover photo | The cover is not stored. It is the first saved trip's hero image or a fixed backdrop (`profile_screen.dart:22-24`). Profile photo upload already exists (`users/service.py:171`, `avatar_url`). | Add `cover_url` to the user record, a `POST /users/me/cover` upload that mirrors the avatar one (type and size checks, ownership), and a "Change cover" button on the banner and in Edit profile. No cover set = today's look. A "Remove cover" option returns to the default. **Needs an Alembic migration: approval required.** |
| 4 | Profile picture shows the square's edges | Avatar is a 62 dp circle with a 3 dp white border and a 62 dp image inside it (`profile_screen.dart:110-143`). The image is wider than the area inside the border and is drawn over the ring, so the ring is hidden and corners can show at the edge on some photos. The drawer avatar shows initials only (`home_chat_screen.dart:1013`). I cannot tell which screen you saw without a screenshot, so step 1 of the fix is to reproduce it. | One shared `UserAvatar` widget: `ClipOval` on a square of the inner size, border drawn on top as a foreground ring, `cover` fit, initials fallback, same widget used on Profile, Edit profile and the drawer. Add a widget test with a non-square image. Check on the phone. |
| 5 | Delete history in AI chat | Chats are stored on the phone only (`travel_repository.dart:803`, the last 12). The history drawer has no delete (`home_chat_screen.dart:923-1084`). The server keeps only generation-run summaries, not the messages. | Swipe a chat (and a long-press menu) to delete it, with an "Undo" snackbar instead of a blocking dialog. "Clear all chats" at the bottom of the drawer with one confirmation. Deleting the active chat opens a fresh one. Add `deleteChatSession` and `clearChatHistory` to the repository. Say in the confirmation that this removes chats from this phone. |
| 6 | Improve the New chat button and the profile, with the user's photo, moved down | In the drawer the bottom row is an initials-only circle and a small "New Chat" button (`home_chat_screen.dart:1004-1050`). | Drawer layout: a full-width "New chat" button directly under the search box (the most used action, easy to reach). The profile moves to a footer row at the very bottom: user photo (the shared `UserAvatar`), name, @username, tapping it opens Profile. I read "move it down" as "put the profile at the bottom". Tell me if you meant something else. |

## Part 2. Why 3 picks produced 5 cards

I read the chat path in `services/api/app/features/ai/service.py` and the prompt in `integrations/groq/prompts.py`. I could not reproduce your exact chat, so the causes below come from reading the code. Please send me that chat (or the date and time) so I can confirm against the saved generation run.

1. **The card count is fixed, not decided.** `MAX_SUGGESTIONS` is 5, the prompt says "limit 1 to 5", and the ranking is asked to "fill to limit" with near matches (`service.py:1396`). Nothing ties the number to what the traveler needs. Three picks and a trip of a few days still gets a full row of five.
2. **Cards come back after picks.** Once stops are picked, any message where retrieval detects an interest (for example "museum") triggers a fresh ranking and shows up to 5 more cards (`service.py:1372-1405`). A message that merely mentions a kind of place is treated as "show me more of it".
3. **A place you name after picking is never matched by name.** The by-name matcher runs only when no destination is selected (`service.py:1196-1205`), and the catalog list it needs is not even loaded once there are picks (`service.py:473-477`). So when you picked three and then typed a museum that was not on the cards, the server could not add it. It relied on the model to return the right id, and rejects it if the id was not in the retrieved set (`service.py:1137-1148`, "I couldn't match that destination"). The fallback was another interest ranking: five museum-type cards, none of which was the one you asked for. The catalog has only four museums, so five cards of "museum" also pads with near matches.
4. **The prompt contradicts itself.** It says "recommend one to three destinations" and also "show at most 5 places", says the app draws the cards and also forbids asking you to choose in prose, and is one 4,000-character paragraph with the rules mixed together. Small models follow such text unevenly.

## Part 3. Making the AI more intelligent about cards

### Rules (server, deterministic; the model only suggests)

1. **Named place beats ranking.** If the message names a catalog place (or the model returns a valid id), resolve it by name even when other stops are picked. Show that single place as a card with an "Add" button (or add it directly when the wording is clear, like "add Museo Dabawenyo"). Never replace it with an interest ranking.
2. **Never re-show what is picked.** Exclude picked ids from every card list (already done for one branch, applied everywhere).
3. **Card count follows need, not a constant.** Starting a search: up to 5. With picks and a request for "more": 3. A named place: 1. Logistics, questions, small talk: 0. Cap picks-plus-cards at about three stops per trip day when the day count is known.
4. **Relevance floor.** Show a card only if its score clears a threshold; fewer good cards beat padded ones. If under the floor, say so ("only two museums are listed") instead of filling. Keep near matches labelled, as now, but never to reach a number.
5. **Say why.** Each card keeps its reasons; the reply names how many were chosen and why that many.
6. **Stage-aware replies.** At the picking stage the reply acknowledges the picks, offers "add more" or "plan the trip", and shows cards only when the message asked for more.

### Prompt rewrite (outline)

Split the single string into labelled sections: Role and voice; Facts and grounding; Output JSON contract; Intent table (which intent gives how many cards); Rules for picks; Examples. Remove the contradictions above. Add two worked examples that match your case:

- Picks present, message "add the National Museum" → `intent: "modify_trip"`, `state_updates.destination_ids` = existing picks + the museum, no `place_query`, short acknowledgement naming all picks.
- Picks present, message "any other museums?" → `intent: "show_places"`, `place_query: {categories: ["museum"], limit: 3}`, and the server removes picked places.

The prompt version constant is bumped so saved runs show which prompt produced them.

## Part 4. Phases

Each phase is its own branch, merged after your OK, as in the redesign.

| Phase | Scope | Touches | Needs approval |
|---|---|---|---|
| A | Profile cleanup: remove Account row (keep guest sign-in), remove "PHP >" | `profile_screen.dart` | none beyond this plan |
| B | Shared `UserAvatar`, edge fix, used in Profile, Edit profile, drawer | new widget, 3 screens, test | none |
| C | History: delete one, clear all, undo; drawer layout (full-width New chat on top, profile footer with photo) | `home_chat_screen.dart`, repository, tests | none |
| D | Cover photo: DB column, upload endpoint, app UI | migration, users feature, app | **migration approval** and a Render deploy |
| E | Card rules (named place, exclude picks, dynamic count, relevance floor) | `ai/service.py`, `recommendations`, tests | backend change approval |
| F | Prompt rewrite and bumped version; a set of about 20 scripted conversations (including your 3-picks case) run against fake model outputs to check cards, plus a small live check on the real model | `prompts.py`, tests | backend change approval |
| G | Phone verification and a written record; push, deploy API (D, E, F) | docs | deploy approval |

Order: A, B, C (app only, can ship without the server), then E, F, then D, then G. Phases E and F change what travelers see only after a Render deploy.

## Part 5. Risks and checks

- Deleting history is permanent on the phone. The single delete has Undo; clear-all asks first.
- Removing the Account row must not remove the only sign-in path for guests (handled in A).
- Cover uploads need the same file checks as avatars; a failed upload keeps the old cover.
- Card rules must not hide a place the traveler asked for. Tests cover: named place with picks, "more" with picks, no picks, logistics question, category with fewer places than the limit.
- AI tests use fake model replies so they are repeatable. The live check is a smoke test, not a guarantee.

## Questions for you

1. Is my reading of the 3-picks case right: after choosing 3 places you typed or tapped a museum that was not among the 5 cards, and then got 5 museum cards instead of it being added? A screenshot or the time of the chat would let me confirm.
2. Which screen showed the square edges: Profile, Edit profile, or somewhere else?
3. For "move it down": profile at the bottom of the history drawer, as planned?
