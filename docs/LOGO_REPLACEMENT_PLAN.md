# New logo: replacing the compass star

![Lakbay+ logo](brand/lakbay_logo_source.jpg)

The original file is `docs/brand/lakbay_logo_source.jpg` (1080 x 1080, white background). The app uses a cropped copy with a transparent background: `apps/traveler_app/assets/brand/lakbay_logo.png` (640 x 332, 256 colours, about 44 KB).

## Decisions (yours)
- Replace the compass star **everywhere it appears**.
- Do **not** change the Android home-screen launcher icon yet.

## Where the star appeared, and what it shows now

| Place | Before | After |
|---|---|---|
| Chat avatar beside AI messages | White star on a teal circle, 22 dp | Logo on a white circle with a thin border, **34 dp** (22 dp would be unreadable) |
| Centre "Chat" tab button | White star on a teal circle | Logo on a white circle; the ring is dark teal when Chat is selected, teal otherwise |
| Wordmark (history drawer, Settings, onboarding, splash) | Star + the text "Lakbay+" | Logo + the text "Lakbay+" (on dark screens the logo sits on a white rounded badge) |
| Trip detail assistant badge | Star avatar, 46 dp | Logo avatar, 46 dp |

One widget draws all of these (`LakbayCompassMark`). Its name is kept so no call site had to change; it now draws the logo, scaled by height, and keeps the logo's own colours.

## What I deliberately did not change
- The small sparkle icons on buttons such as "Ask AI" (`Icons.auto_awesome`). They are a different symbol, not the star. Say if you want them replaced too.
- The Android launcher icon, notification icon and web favicon. They need a square version with safe margins and an icon rebuild.

## Things to know
- **Duplicate name:** the logo already spells LAKBAY, and the wordmark still adds the text "Lakbay+" beside it. If that looks repeated, the next step is to show the logo alone in the headers.
- **Readability:** the logo is a wide, detailed picture. Below about 30 dp wide it becomes a blur of teal and orange. That is why the chat avatar was made larger and put on white; the teal bus would vanish on the app's dark teal.
- **Contrast:** teal on dark teal has weak contrast, so wherever the old star was white on a dark background the logo gets a white badge.

## Checks
- Tests: the file is bundled and has the expected proportions; the mark draws wide-not-tall; dark backgrounds get the white badge; the avatar fits inside its circle at 34 dp and 46 dp; the wordmark shows the logo and the name; the Chat tab button shows the logo. All 281 tests in the app suite pass.
- Phone: built and installed; screenshots of the chat, drawer and tab bar are pending.

## Next, if you want it
1. Launcher icon (square, padded) and notification icon.
2. Drop the duplicate "Lakbay+" text beside the logo in headers.
3. Replace the sparkle icons on AI buttons.
