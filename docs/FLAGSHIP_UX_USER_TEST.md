# User test kit, round 1 (F0)

Part of `docs/FLAGSHIP_UX_PLAN.md`. Purpose: watch real travelers try the app so the plan is adjusted to what they actually hit, not to what we imagine. It tests the app, not the person.

## 1. Setup
- **Who:** 5 to 8 people who might visit the Davao Region. Mix first-time tourists and locals; include at least one person over 45 and one who rarely uses travel apps. Five people find most major problems; more than eight repeats them.
- **Device:** a mid-range Android phone, as your users have, on normal mobile data. Install the same build for everyone and sign out first so each person starts as a new user.
- **Time:** about 25 minutes each.
- **You need:** a second person or phone to take notes, and a stopwatch.

## 2. What to say (read aloud)
"Thanks for helping. We are testing the app, not you, so nothing you do is wrong. Please think out loud: tell me what you expect and what confuses you. I will not be able to help during the tasks. You can stop at any time." Ask for permission before recording the screen or taking photos; record nothing that shows personal information.

## 3. Rules for the facilitator
- Do not explain the app before or during the tasks. If they ask "what does this do?", say "what do you think it does?".
- Stay silent for at least 10 seconds before any prompt. Note the moment they hesitate.
- Do not lead ("did you see the button on the left?").
- Stop a task after 5 minutes and mark it "not finished".
- Do not use the live AI chat more than the tasks need; it spends shared Groq quota. If the chat says it is busy, note it and move on.

## 4. Tasks

Start each task from the home screen. Read the task, nothing more.

| # | Task | Finished when |
|---|---|---|
| 0 | "Open the app and tell me what you think it is for." (first launch, count taps and seconds until the first result cards or a clear first step) | They name the purpose; note taps and seconds to the first useful result |
| 1 | "Find a beach near where you are staying and add it to a trip." | A beach is in a trip |
| 2 | "Plan a 2-day trip for 2 people with a budget of 5,000 pesos." | They have a saved trip with 2 days |
| 3 | "Find out how to get to one of those places from your hotel." | They name a route or transport and roughly how long it takes |
| 4 | "Delete a trip you do not want, then get it back." | They delete and recover it, or say they cannot |

## 5. Observation sheet (one per person)

Tester ID: ____  Age band: ____  Used travel apps before? ____  Date: ____

| Task | Finished (Y / N / with help) | Taps | Seconds | Where they hesitated or said "huh?" | Wording they did not understand | What they expected instead |
|---|---|---|---|---|---|---|
| 0 | | | | | | |
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |

After the tasks, ask:
1. "What was the most confusing moment?"
2. "Was anything missing you expected?"
3. "Would you use this for a real trip? Why or why not?"
4. "Which words in the app did you not understand?"

## 6. Summarizing

Add one row per tester to `docs/FLAGSHIP_UX_BASELINE.md` section 4 and record:

| Result | How to compute | Plan target |
|---|---|---|
| Task success | Testers who finished unaided / testers | At least 4 of 5 for task 2 by G2 |
| Median taps and seconds per task | Median across testers | No worse than round 1 after F2 |
| Top 5 problems | Issues seen by two or more testers, by severity | Each maps to a phase in the plan or is added |
| Wording problems | Words more than one tester misread | Feed the F1 word list |

Count what happened; do not turn five people into a percentage. A problem that two testers hit independently is worth fixing. Run round 2 after F2 (gate G2) with at least three of the same tasks and new people.
