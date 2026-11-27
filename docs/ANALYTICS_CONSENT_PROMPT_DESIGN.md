# Design Proposal: One-Time Analytics Opt-In Prompt (D7)

**Status:** Proposal only (not implemented). Current app behavior is opt-in (off by default, toggleable in Settings).

## Goal
Ask each traveler once — without interrupting first-run planning — whether they want to turn on anonymous usage and crash reports, once the published privacy notice URL is live.

## Trigger & Frequency
- Show **at most once** per install, persisted under a dedicated `SharedPreferences` key (`lakbay_analytics_prompt_shown = true`).
- Do **not** show on cold launch or inside onboarding (protects time-to-first-result).
- Trigger on the **second app session** (or right after the traveler saves their first trip or receives their first AI answer with place cards), **only if**:
  1. `lakbay_analytics_prompt_shown` is not `true`, AND
  2. `lakbay_analytics_enabled` has not already been explicitly toggled in Settings (`prefs.containsKey(AnalyticsService.enabledKey) == false`).

## UI & Copy
- Present a non-blocking bottom sheet (`showModalBottomSheet`) with two equal-weight buttons (no dark patterns, dismissible by swipe/back):
  - **Title:** `Help improve Lakbay+?`
  - **Body:** `Share anonymous crash reports and simple counts (like how many trips are saved) so we can fix crashes and spot confusing steps. We never send your messages, name, email, or GPS location. You can change this anytime in Settings.`
  - **Optional link (required before shipping):** `Read privacy notice` → opens the published privacy policy URL.
  - **Actions:**
    - Secondary (`OutlinedButton`): `No thanks` → sets `lakbay_analytics_prompt_shown = true`, leaves `enabled = false`.
    - Primary (`FilledButton` / equal height & width): `Turn on` → sets `lakbay_analytics_prompt_shown = true`, calls `repo.setAnalyticsEnabled(true)`.
  - **Dismissing the sheet** (back button / scrim tap): sets `lakbay_analytics_prompt_shown = true` and leaves `enabled = false` (no nagging on future sessions).

## Prerequisites Before Implementing
1. Publish the Lakbay+ privacy notice URL and align it with the Google Play Data Safety form (H3).
2. Confirm Firebase Analytics & Crashlytics are enabled in the Firebase console (H3) and verified in a release/profile build (H2).
3. Keep `AndroidManifest.xml` startup flags (`firebase_analytics_collection_enabled` and `firebase_crashlytics_collection_enabled`) set to `false` so nothing fires before opt-in.

## Planned Files (When Approved)
- `apps/traveler_app/lib/services/analytics_service.dart` (`promptShownKey`, `shouldShowConsentPrompt`, `markConsentPromptShown`).
- `apps/traveler_app/lib/widgets/analytics_consent_sheet.dart` (reusable bottom sheet).
- `apps/traveler_app/lib/screens/main_shell.dart` (single trigger hook after first result / second session).
- `apps/traveler_app/test/analytics_service_test.dart` (unit + widget tests verifying once-only behavior, dismiss-stays-off, and skip when Settings already toggled).
