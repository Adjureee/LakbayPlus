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
