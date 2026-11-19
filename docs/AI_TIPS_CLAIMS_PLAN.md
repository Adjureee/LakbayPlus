# Claims inside tips: plan

Status: **plan for review. Nothing here is implemented.** Changing how replies are checked needs your approval (decisions in section 6).

Follows `docs/AI_CLAIMS_CHECK_PLAN.md` and `docs/AI_CLAIMS_BASELINE.md`. Data: the same 58 live replies (156 sentences) the claims check was measured on, with the judge's labels.

## 1. What the data shows

The check catches 16 of the 33 sentences the judge called unsupported (48%) and wrongly flags 0 of 123 others. Scenery wording is not the gap (8 of 156 sentences, 6 supported, the 2 unsupported already caught). The gap is **advice that carries a claim inside it**.

| | Count |
|---|---|
| Sentences that read as tips ("Tip:", "best to go", "bring", "avoid", "arrive") | 40 of 156 |
| of those, judged unsupported | 20 (50%) |
| of those, supported by the record | 15 |
| of those, generic (honest "not recorded, ask them") | 5 |
| Misses (of 17) that are tips | about 12 |

A tip is useful and often true, so the aim is not to remove tips. It is to stop a tip from asserting a fact about the place that Lakbay's records do not hold.

## 2. What the unsupported tips actually claim

Counted from the 20 unsupported tips (a tip can hold more than one):

| Kind of claim inside the tip | Examples | Today |
|---|---|---|
| **Crowds** | "go early to avoid crowds", "less crowd", "the small crowd" | missed: the crowds rule only knows "crowded", "busy", "fills up" and weekend crowds |
| **Heat, cool air, sun** | "when the weather's cooler", "avoid the strongest sun", "the indoor space can get warm", "it's cooler" | missed |
| **Rain and conditions** | "sudden rain can hit the rooftop" | missed |
| **What happens when** | "when the eagles are most active", "when the lights are on" | missed |
| **Season** | "during the dry season (Nov-May)" | already caught |
| **Items to bring** | "bring sunscreen, a hat, water", "wear comfortable shoes" | judged unsupported 5 times, supported 8 times (when the record mentions it) |
| **Terrain** | "sturdy shoes for the uneven path" | already caught |

## 3. What should and should not be flagged

1. **Conditions of the place stated as fact: flag.** Crowds, heat or cool air, rain, "most active at", "when the lights are on". They are claims about the place. Supported only when the record says the same thing (a record that mentions "cool" supports "cooler weather"; the Energy Park and Banana Beach tips were supported that way).
2. **What to bring: do not flag.** "Bring water and sunscreen" is general advice, true almost everywhere and harmless if it is not backed. The judge is stricter than we should be here. Exception: an item that answers a claimed condition stays covered by that condition's rule ("sturdy shoes for the uneven path" is the terrain rule).
3. **The time advice itself ("go early in the morning"): do not flag.** It is a recommendation, not a fact about the place. What is checked is the **reason** attached to it.
4. **Advice to ask the operator** stays allowed (the existing guard). The judge marked "call the resort to ask about ramps" as unsupported; that is judge noise, not a gap.

## 4. How it would work

All inside the existing claims check (`app/features/ai/claims.py`); no new service.

- **New rules in the lexicon**, category `conditions`, each with the words that count as support in the place's records:
  - crowds as a reason or fact: avoid crowds, less crowd, small crowd, fewer people, the busiest time (support: "crowd", "busy", "peak");
  - heat and cool: cooler, cool air, avoid the heat or strongest sun, get warm (support: "cool", "warm", "hot", "heat", "shade");
  - rain: sudden rain, rain can (support: "rain", "wet");
  - activity timing: most active, when the lights are on, feeding time (support: the same words in the record).
- **Trimming keeps the advice and cuts the reason.** Today a flagged sentence is trimmed or dropped. Tips would be trimmed at the reason clause (`to avoid ...`, `for cooler weather`, `when the weather's cooler`, `as the ... can get warm`, `when the eagles are most active`), keeping the recommendation:

  | Before | After |
  |---|---|
  | Best to go early in the morning to avoid crowds and bring a sun hat. | Best to go early in the morning and bring a sun hat. |
  | Tip: Visit in the morning when the eagles are most active; bring a hat and water. | Tip: Visit in the morning; bring a hat and water. |
  | Tip: check the weather forecast and bring a raincoat; sudden rain can hit the rooftop. | Tip: check the weather forecast and bring a raincoat. |

  A tip that cannot be cut cleanly is dropped whole, as today.
- **The existing claim note** ("I left out some details about the place that Lakbay's records do not confirm") still appears when anything is cut.

## 5. How it is measured and kept safe

- **Recall:** replay the labelled sample (`tests/claims_baseline.py replay`, no model calls). Target: catch at least 70% of the judge's unsupported sentences, from 48% now. About 12 of the 17 misses are in scope; the rest (a recorded price in a longer sentence, "water park area", "photo-ops") are separate small fixes.
- **Precision (the hard limit):** 0 of the 123 other sentences wrongly flagged must stay 0. The 15 supported tips must come out unchanged.
- **Must-not-touch tests:** "Bring sunscreen and water.", "Go early in the morning.", "Wear comfortable shoes.", "Call the park to ask about crowds." never change.
- **Unit tests** for each pattern, with a supported and an unsupported case; the before and after sentences above become tests.
- **Enforcement preview** on all 58 replies before it ships, as for the first check, to read what actually changes.
- **Live check** through the public guest chat after deploy.

## 6. Decisions for you

1. **Items to bring stay unflagged** (recommended), or flag them when the record says nothing? Flagging makes almost every tip lose its list, for little honesty gain.
2. **Trim the reason and keep the advice** (recommended), or drop the whole tip when its reason is unsupported? Dropping is simpler and safer but loses useful advice ("go early" is usually good advice even when the reason is a guess).
3. **Is a 70% recall target right,** or do you want to push higher at the cost of more removed sentences?
4. **Also fix the other misses in the same pass** ("water park area", "photo-ops", a price inside a longer sentence), or keep this pass to tips only (recommended)?

## 7. Not in this plan

- Scenery wording (left unflagged, with the data above).
- Tone and opinions.
- Changing the judge model or prompt.
- A database change: none. The deploy is a Render deploy only.

## 8. Steps

1. Add the rules and the reason-clause trim, with unit tests (no deploy).
2. Replay the labelled sample and the enforcement preview; show the numbers before merging.
3. Full backend suite, then merge and deploy.
4. Live check on the guest chat with questions that invite tips.
