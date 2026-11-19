# Claims-without-numbers check (plan)

Status: **plan for review. Nothing here is implemented.** Changing how replies are checked needs your approval (decisions in section 7).

Context: the figure check in `services/api/app/features/ai/grounding.py` already removes sentences whose prices, distances, times or counts the place's records do not hold. It cannot see a claim that has no number in it. This plan closes that gap.

## 1. The problem, with live examples

All from the deployed chat (17 to 18 Nov 2026), asking about places whose records say little:

| Question | Reply text | What the record holds |
|---|---|---|
| Is Huyong-huyong Nature Park wheelchair accessible? | "the park's paths are **mostly flat but can be a bit uneven near the lake**" | wheelchair accessible: true. Nothing about paths |
| Is Banana Beach ... wheelchair accessible? | "**with ramps and accessible paths** around the beach and pool area" | wheelchair accessible: true. Nothing about ramps or paths |
| Is Banana Beach ... wheelchair accessible? | "you'll find **free parking** at the resort" | No parking note |
| Is Aliwagwag Falls wheelchair accessible? | "a multi-tiered waterfall system **with a bridge walk and stairs, which may pose mobility challenges**" | Accessibility not recorded. The claim leans toward "not accessible" |
| "Just me" (earlier run) | "pack ... a copy of your ID **for the boat check-in**" | No boat or check-in for that place |
| What can I do at Huyong-huyong? | "a typical visit runs about ₱300 total" | A cost estimate, restated as a visit total (the figure check passed it because ₱300 is in the record) |

These are plausible, often true in the real world, and unverifiable from Lakbay's data. The rule in the specification (B5) is not to present unsupported destination-specific facts as fact. The prompt already says so; the fallback model (Gemini) does not follow it reliably, and Groq is not measured.

## 2. What counts as a claim without a number

Only statements **about a specific place** are in scope. General travel tips ("bring sunscreen", "arrive early") stay.

| Category | Examples of claims | Supported by |
|---|---|---|
| Accessibility detail | ramps, paved or flat paths, stairs, steps, elevator, handrails, uneven ground | those words (or listed synonyms) in the place's records or its `accessibility_note`. The flag `wheelchair_accessible: true` supports "wheelchair accessible" only, never ramps or paths |
| Facilities | parking (free or paid), restrooms, lockers, showers, Wi-Fi, mobile signal, ATM, food stalls | `parking_note` or the same words in the records |
| Rules and policies | photography allowed or not, pets allowed, permits, reservations, "booking required" | `booking_requirement`, `booking_note`, the pet flag, or the words in the records |
| Conditions | crowds, quiet, muddy, slippery, rough road, cooler, hot | `crowd_level`, `best_time_basis`, or the words in the records |
| Status and schedule words | "open daily", "closed Mondays", "seasonal" | structured hours, `operating_status`, activity availability, or the words in the records |
| How to get there | "by tricycle", "via the highway", "boat from the pier" | `how_to_get_there`, transport records, `travel_notes` |
| Activities | zipline, mini-zoo, fishing, kayaking | `activity_details`, the legacy `activities` text, `description` |

Out of scope for now: tone, general descriptions of scenery ("beautiful views"), and subjective opinions.

## 3. Options considered

| Option | Verdict |
|---|---|
| **A. Topic-term check on place-specific sentences** (deterministic). A sentence about a named place (or the one card in focus) that uses a term from a category must find that term, or a listed synonym, in that place's own records; otherwise it is flagged | **Recommended.** Same shape as the figure check, so it fits the pipeline; explainable; no extra model call; testable. Limits: only catches the terms in its lexicon; synonyms need maintenance |
| B. A second model call that lists unsupported claims | Not at runtime: adds seconds and quota (Groq already rate-limits), and a model can misjudge too. **Useful offline** as the judge that measures how well A works |
| C. Stricter prompt only | Keep the existing rule and add the examples above, but it cannot be the only defence (the fallback model ignored it) |
| D. Model returns each claim with the record field it used; the server verifies | Strongest, but a large change to the reply schema and to the prompt. Revisit if A's recall is too low |

Decision: **A at runtime, C as a small addition, B as the offline measuring tool.**

## 4. Design of option A

1. **A lexicon** in one data module (`app/features/ai/claim_terms.py`): per category, the words that make a claim and, for each term, the words that count as support. Small and reviewed. Start narrow, with the categories that actually failed: accessibility detail, facilities (parking above all), rules, conditions. Others are added when a live sample shows a miss.
2. **What a place's support is:** the same per-place facts the figure check uses (`facts_by_destination`), now including the structured lines (activity details, hours and price summaries, booking and parking notes, accessibility note) and a **flag-to-term table** (for example `kid_friendly: true` supports "kid friendly" and "family friendly", not "playground").
3. **Which sentences are checked:** those that name one place (the existing `mentioned_place_ids`), or that follow the single card in a one-card reply. A sentence naming no place is left alone.
4. **What happens to a flagged sentence:** in order of preference, (a) cut a trailing "with ... / featuring ... / including ..." clause that holds the unsupported term and keep the rest ("Yes, ... is wheelchair accessible."); (b) otherwise drop the sentence, using the same cascade rule that removes sentences leaning on it. The reply then carries a short note, the way the figure check adds its note, only when something useful was removed.
5. **Where:** the two call sites that already run `ground_figures` in `service.py` (chat path and the planning chat result), as one added step, so the figure check and the claims check cannot disagree.
6. **Prompt (C):** add the failing examples as "do not add detail about ramps, paths, stairs, parking, facilities or rules unless it is in the record".

## 5. How we will know it works

1. **Offline measurement before any enforcement.** Build a labeled set of about 200 sentences about places from the stress script and the live samples above, each labeled supported or unsupported (a model judge proposes, I spot-check 50 by hand). Targets: catches at least 80% of the unsupported claims; wrongly flags no more than 3% of supported sentences.
2. **Log-only first.** Ship the check in log-only mode: it records the category, term and place for each flagged sentence in the existing AI timing log, but changes nothing the traveler sees. After a few days of real traffic we read the counts and the false flags, tune the lexicon, then switch to enforcing.
3. **Tests:** per category, one flagged and one supported case; clause cutting; the cascade; a sentence naming no place is untouched; support from the structured fields and from the flag table; "unknown flag" never supports a detail. Plus the stress script gains a check, "descriptive claims that are in the record", scored by the judge.
4. **Live check** with the six examples in section 1 after deploy.

## 6. Interaction with the place data work

Entering real data makes more claims supportable: an `accessibility_note` of "ramp at the main gate; paved path to the beach" lets the reply say exactly that. The check and the data work reinforce each other: the less a place's record says, the thinner its answers, and that is correct. The admin completeness meter (design doc, section 6) shows which places are thin.

## 7. Decisions for you

1. **Log-only first, then enforce** (recommended), or enforce from the start?
2. **Cut the trailing clause** when possible (recommended), or always drop the whole sentence? Cutting keeps useful answers ("Yes, it is wheelchair accessible") but is a little more complex.
3. **Starting categories:** accessibility detail, facilities, rules, conditions (recommended), or fewer, or all seven?
4. **Use a model as the offline judge** for the labeled set? It costs a few dozen calls from the Groq and Gemini quotas, and I would never use it at runtime.
5. **Thresholds** (80% caught, 3% wrongly flagged), or stricter or looser?

## 8. Steps and size

| Step | Contents | Size |
|---|---|---|
| 1 | Labeled set and judge script; measure how many of today's replies hold unsupported claims (the baseline for this check) | Small, no product change |
| 2 | Lexicon, check, tests, log-only mode, prompt addition | Medium |
| 3 | Read the logs, tune, enable enforcement, live check | Small |

Nothing changes in the database. Steps 2 and 3 each need your go-ahead before I change how replies are checked.
