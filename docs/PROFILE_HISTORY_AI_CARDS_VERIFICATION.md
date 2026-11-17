# Profile, history and AI cards: verification record

Plan: `docs/PROFILE_HISTORY_AI_CARDS_PLAN.md`. Phases A to F are merged on `main` and pushed (up to `8219f21`).
Phone: Android `10944373BA109672`, release build of `main` after phase D.

## Checked on the phone

| Item | Result |
|---|---|
| Profile: no ACCOUNT section, no "PHP" beside Settings | Confirmed (signed in as the account owner) |
| Profile picture | A clean round photo with the white ring on top; no square corners |
| History drawer: full-width "New chat" under the search box | Confirmed |
| History drawer: profile row at the bottom with photo, name, @username | Confirmed |
| Trash-list icon (Clear all chats) visible beside the profile row | Confirmed (not pressed) |
| Profile banner: camera button next to Edit | Confirmed |
| Camera button opens "Choose a cover photo" sheet | Confirmed (no photo chosen) |

## Checked by automated tests only

- Swipe-to-delete a chat, Undo, Clear all (with confirmation), deleting the open chat opens a blank one.
- Guest still sees "Create account / Sign in" on Profile.
- Cover upload and remove (app calls and API endpoints), cover that cannot load falls back to the default, 48 dp camera button.
- AI card rules: an explicit "add" puts a named place in the plan; naming a place without "add" offers only that card; "more of a kind" with picks gives 3 cards or fewer and never a picked place; show-places never lists picks; a place named only by generic words ("National Museum") is matched when typed together.
- Prompt v13 contains the CARD RULES and no longer says "Show at most 5 places".

Results at the last full runs: traveler app 275 passing; API 907 passing, 1 skipped (before phase D; the user, auth and migration tests were re-run after it: 69 passing).

## Not checked

- Production does **not** have these changes yet. The live API has no `/users/me/cover` endpoint, so a cover upload from the phone cannot work until the API is deployed and migration `2026_11_20_0900` is applied.
- The AI card rules and prompt v13 have not been tried against the real model. The tests use scripted replies. This should be checked after the deploy with the three-picks case (pick three places, then "add the National Museum", then "any other museums?").
- Swipe-to-delete and Clear all were not pressed on the phone, to avoid deleting real chats.
- A real cover photo was not uploaded.
- The bottom-bar Profile tab still shows initials instead of the photo (not part of the plan).
- No TalkBack run.

## Still to do

1. Deploy the API on Render and apply the migration to the production database.
2. After that: upload a cover from the phone, remove it, and run the three-picks conversation against the live model.

## Live check against production (17 Nov 2026)

Done on the phone against the live API, in a new chat: "show me beach resorts", pick one resort, "add the National Museum", then "any other museums".

| Round | Deployed | Result |
|---|---|---|
| 1 | Prompt v13 and card rules (`efe7a7b`) | The museum was added, but the reply also said "I couldn't match that destination…", and beach cards came back after the add. |
| 2 | `c749793` | Both fixed. But the model wrote "Added Dahican Surf Resort" while the server added the National Museum. |
| 3 | `9b64fe4` | The model labelled the message a question and said the museum was outside the region; nothing was added. |
| 4 | `52e2639` | Passed: "Added National Museum of the Philippines - Davao: that makes 2 stops in your plan (Lanikai Hijo Estate Resort, National Museum of the Philippines - Davao). Want to add more or start planning?" No contradictory note, no stray cards. |

"Any other museums?" in the final round returned museum cards (Museo Panabo and others).

Fixes made because of the live runs, each with a test that reproduces the live case: a name-based add no longer prints the "couldn't match" note and shows no cards; only the named place is added and the server writes the confirmation; an explicit "add" works whatever intent the model chose.

### Still imperfect

- The model's wording is not fully controlled. In round 1 of one run it listed place names in prose, and "any other museums?" named D' Bone Collector and Museo Dabawenyo in the text while the cards showed Museo Panabo and another. The cards come from the server; the prose comes from the model.
- On one run the model's first reply was unusable and the app showed "I couldn't safely update your plan from that response" (the cards still appeared).
- The 3-card limit for "more of a kind" was seen only in tests; the number of cards on the phone was not counted.
- The "any other museums?" step after a name-based add was run once.

### Still not checked

- Cover photo upload and remove from the phone (the endpoint is live; no photo was uploaded).
- Swipe-to-delete and Clear all on the phone.
