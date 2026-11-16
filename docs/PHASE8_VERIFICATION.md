# Phase 8: verification record

Run on the TECNO phone (1080x2460, 120 Hz) with the Phase 1 to 7 build, signed in. A second phone was not available, so anything needing two accounts is listed as **needs a person**.

Legend: **Pass** = seen working; **Pass (tests)** = covered by an automated test, not seen on the phone; **Fix** = problem found and fixed in this phase; **Needs a person** = cannot be checked from here.

## Measured on the phone
| Check | Result |
|---|---|
| Cold start | 630 to 680 ms (first run after install: 1461 ms). Budget: under 2 s. **Pass** |
| Scroll Discover (716 frames) | median 8.3 ms, 1.1% slow frames, worst 16.9 ms. Budget: under 5%. **Pass** |
| Scroll Memories (915 frames) | median 8.3 ms, 1.6% slow, one 133 ms frame (likely the tab switch). **Pass** |
| Scroll Trips (911 frames) | median 8.3 ms, 1.3% slow. **Pass** |
| App errors while opening all five tabs | none in the Flutter or Android runtime log. **Pass** |

How: `adb shell input swipe` on each tab, then frame times from `dumpsys SurfaceFlinger --latency` on the app's surface (Flutter does not report to `gfxinfo`).

## Screens and actions
| Area | Check | Result |
|---|---|---|
| Sign-in | Signed in, name and `@username` shown | **Pass** |
| Profile | Profile photo shown in the header after upload | **Pass** (seen) |
| Profile | Edit sheet camera picks and uploads a photo, shows the server's reason on refusal | **Pass (tests)**; upload seen to work |
| Profile | "Detecting location..." showed forever when no location was saved | **Fix**: now "Location not set" |
| Trips | Hero card and list render; trip opens | **Pass** |
| Trips | "1 travellers" | **Fix**: "1 traveller" |
| Discover | Cards, filters and search render | **Pass** |
| Discover | Pull to refresh, no assumed party size | **Pass (tests)** |
| Trip detail | Commute button, mode chips, forecast note, honest stays | **Pass (tests)** |
| Commute | Drive card, verified commute routes, Start checklist, Copy | **Pass (tests)**; no route is verified in production yet, so travelers see "No verified public-transport directions" |
| Map | Car / transit / walking, access trails | **Pass (tests)**; not opened on the phone |
| PDF | Built on the phone, works signed out | **Pass (tests)**; **Needs a person** to export on the phone with airplane mode on |
| Memories | Upload a photo to a trip | **Needs a person**: production has 0 memories |
| Notifications | Inbox filters, tap routing | **Pass (tests)** |
| Notifications | Push arriving and tapping through to the trip on a second phone | **Needs a person** (two accounts, two phones) |
| Admin app | Commute editor and AI draft | **Pass (tests)**; not opened on the phone |

## Not done
- Chat, Trip detail and the map were not frame-timed.
- The commute migration `2026_11_19_0900` has not been run on production, and the API has not been redeployed with Phases 1 and 4, so the live server does not yet serve commute routes or the Phase 1 sign-in confirmation.
