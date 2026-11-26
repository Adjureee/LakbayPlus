"""UserPromptSubmit hook: tell Claude which Lakbay skill the user's request needs.

Skills activate from their descriptions only when the model chooses to read them. This hook
removes the guess for the three project skills: when the prompt matches, it prints a one-line
instruction that Claude Code adds to the turn's context. It makes no network or model call,
never blocks a prompt, and prints nothing when no skill matches.
"""

import json
import re
import sys

ROUTES = (
    (
        "lakbay-ai-accuracy",
        r"accura|stress[ -]?(test|check|run)|claims?[ -]?(check|baseline)|\bgroq\b|\bgemini\b"
        r"|live (call|check|run|model)|chat (answer|reply|replies|cards?|suggestions?)"
        r"|suggested repl|tests/accuracy|golden quer|guest chat|token quota",
    ),
    (
        "lakbay-routing-geo",
        r"\brout(e|es|ing)\b|\bosrm\b|\bmapbox\b|\bsnap|\bferry\b|\bpier\b|sea[ -]?links?"
        r"|dashed line|road route|polyline|waypoint|travel time|\bcycling\b|walking profile"
        r"|route geometry|day[ -]?planner|haversine|last stretch",
    ),
    (
        "lakbay-verify",
        r"\bpytest\b|flutter (test|analy[sz]e)|dart analy[sz]e|\bverify\b"
        r"|(run|rerun|check)\b.{0,30}\btests?\b|nothing (broke|is broken|breaks)"
        r"|(tests?|suite) (pass|fail)|before (i |we )?merge|response (field|schema)"
        r"|new field|added a field",
    ),
)


def main() -> None:
    try:
        prompt = str(json.load(sys.stdin).get("prompt", ""))
    except (ValueError, OSError):
        return
    matched = [name for name, pattern in ROUTES if re.search(pattern, prompt, re.IGNORECASE)]
    if not matched:
        return
    names = ", ".join(matched)
    print(
        f"Lakbay skill routing: this request matches {names}. Invoke it with the Skill tool "
        "before acting, without waiting to be asked; the project owner wants these to "
        "activate automatically. Skip only if the request clearly is not about that area."
    )


if __name__ == "__main__":
    main()
