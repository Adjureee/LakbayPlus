# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

The traveler app (`apps/traveler_app`) is Flutter, Android-first, also run in Chrome. The admin workspace (`apps/admin_app`) is a Flutter Web app used in a desktop browser. Both use Material 3.

## Users

- **Travelers** to and within the Davao Region (Region XI, Philippines):
  - domestic tourists from elsewhere in the Philippines
  - Davao locals planning weekend trips and day tours
  - foreign tourists new to the Philippines
  - students and barkada (friend groups) planning on a budget, often together

  Their job: turn "I want to go somewhere in Davao" into a realistic, costed, routed itinerary they can follow on the ground.
- **Administrators** who keep the destination catalog, sea ports and trails, and market rates (accommodation and transport costs) accurate, and who review submitted places, user accounts, reviews and trips.

## Product Purpose

Lakbay+ is an AI travel planner for the Davao Region. A traveler chats with Lakbay AI, gets a day-by-day itinerary built from an admin-maintained catalog of real Region XI destinations, sees the route on a map, estimates budget, collaborates with companions, and keeps memories of the trip. Success means a traveler leaves with a plan they trust and actually use, and admins can keep the underlying data current.

## Positioning

The planning is grounded in a curated, admin-verified Davao Region catalog: destinations with coordinates, sea links, and local market rates. That is what separates it from a general-purpose chatbot. The planner is **AI only**: there is no human travel expert and no 24/7 human support.

## Operating Context

- Traveler flow: onboarding → account (email or Google) → bottom navigation with Trips, Discover, Chat (center), Memories, Profile. Most creation actions hand off to Chat.
- Trip detail covers overview, day-by-day stops, stays and transit, route optimization, Mapbox route playback, collaboration (members and tasks), budget split and PDF, memories, and review/survey.
- Admin workspace: Overview, Destinations (with map and editor), Place review, Sea Ports & Trails, Market Rates (accommodation and transport), User Accounts, Reviews & Feedback, Trip Information, Settings and Profile.
- Backend: FastAPI `/api/v1` on Render with Neon Postgres/PostGIS. AI via Groq/Gemini. Images via Cloudinary. Maps via Mapbox.
- Judged first as a capstone defense demo (Android phone plus admin in a browser), then released to real travelers.

## Capabilities and Constraints

- Flutter and Material 3 in both apps. The traveler app bundles the FigGrotesk and Inter font files and also loads Outfit through google_fonts.
- The admin app has light, dark and system themes. The traveler app is light only today.
- Coverage is limited to Region XI (Davao).
- Trip status (upcoming, ongoing, past, no dates) is derived from the trip's real start and end dates, stored in the API's `trips.start_date`/`end_date`.

## Brand Commitments

- The name **Lakbay+** is kept and shown as a wordmark only.
- The Android launcher icon stays the hand-drawn "LAKBAY+" bus artwork (`android/app/src/main/res/mipmap-*/ic_launcher.png`). This is the owner's decision (2026-11-17); the "L+" icon proposal was declined.
- The compass/star mark (`widgets/brand/lakbay_compass_mark.dart`, `assets/brand/lakbay_mark.svg`, `assets/images/lakbay_logo.png`) is retired: the user rejected it because it reads as the generic AI sparkle.
- Sparkle or star icons (Material `auto_awesome` and similar) are never used for AI features. Chat uses a chat-bubble icon.
- **Visual direction** (user's choice, binding): **the dark teal and mango look.** The reference mockup is `.impeccable/mocks/v4/v8.html` (four screens: Welcome, Trips home, Chat, Trip live day). It refines v5, which the user brought back after trying other styles.
  - Deep teal surfaces: bg #04191C, s1 #0A2A2F, s2 #0F353B, s3 #15434A, hairline rgba(255,255,255,.09).
  - Text is #EAF4F3, muted #8FB0AD.
  - Mango (#FFB547, ink #2A1900) is the single action color: primary buttons, the active tab, user chat bubbles and warnings.
  - Lagoon (#2CC5BC) is used for routes, progress and links.
  - Type: Bricolage Grotesque for display and numbers, Manrope for UI text.
  - Full-bleed Region XI photos with dark gradients, glass chips over photos, a floating tab bar, a big countdown number, route lines drawn on maps, and sticky bottom actions.
  - Motion: the route draws in, the live dot pulses, cards rise in, and all of it is disabled under reduced motion.
  - Rejected along the way: the light Airbnb-style looks (v6, v7) and the Apple-style look (v3). A light variant has not been designed yet.

## Evidence on Hand

- Real destination photography: `apps/admin_app/assets/destinations/` and the traveler backdrop assets. Photographer credits are surfaced in Settings → Photo credits.
- The seeded Davao destinations catalog lives in `services/api/app/seeds`.
- None of these exist, and none may be fabricated: user counts, ratings, testimonials, press, human experts, 24/7 support, or fee and pricing guarantees.

## Product Principles

1. **Grounded, not generic.** Every suggestion should trace back to a real Region XI place, route or rate.
2. **Chat is the engine, the plan is the product.** The conversation is how a plan gets made; the itinerary on the ground is what the traveler keeps.
3. **Honest AI.** Never imply humans, guarantees or data the product does not have.
4. **Works for every traveler type.** It should be clear for a first-time foreign visitor and quick for a local, and should fit a barkada's budget.
5. **Admins move fast with confidence.** Dense, scannable, safe-by-default editing.

## Accessibility & Inclusion

- Target WCAG 2.2 AA contrast.
- Touch targets of at least 48dp on Android.
- Every interactive element needs screen-reader labels.
- Respect the system text-scale and reduced-motion settings.
- English UI. Consider Filipino and Bisaya terms for place names.
