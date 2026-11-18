"""Claims about a place that its records do not hold (no number needed).

The figure check in grounding.py removes prices, distances and times the records do not
hold. This module covers statements without a number: terrain ("uneven path"), seasons
("dry season, Nov-May"), parking ("street parking is usually available"), facilities
("restrooms", "card terminals"), accessibility details ("ramps"), rules ("meter fees",
"photography allowed") and named activities ("guided tours", "zipline").

A claim is flagged only when the sentence is about one place and the place's own records
do not contain the claim's word. Left alone: questions, honest absence statements
("Parking isn't listed"), advice to ask the operator ("ask about ramps"), general travel
tips, and plain "go early to avoid crowds" advice (docs/AI_CLAIMS_CHECK_PLAN.md).
A hedge ("likely", "usually", "many ... have") does not make a claim safe: the
absence-then-speculation pattern is the one seen most in live replies.

Modes (settings.claims_check_mode): "off", "log" (default: findings are logged, the reply
is unchanged) and "enforce" (flagged sentences are trimmed or removed).
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

from app.features.ai.grounding import (
    DASH,
    FIGURE_NOTE,
    NO_DATA_ANSWER,
    _SENTENCE_END,
    filter_sentences,
    mentioned_place_ids,
)

CLAIM_NOTE = "I left out some details about the place that Lakbay's records do not confirm."

_MONTHS = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*"


def _rx(pattern: str) -> re.Pattern[str]:
    return re.compile(pattern, re.IGNORECASE)


@dataclass(frozen=True)
class Rule:
    category: str
    name: str
    claim: re.Pattern[str]
    # The words that make the claim true; by default, the claim's own words.
    support: re.Pattern[str] | None = None


RULES: tuple[Rule, ...] = (
    # Terrain and ground conditions.
    Rule("accessibility", "terrain", _rx(
        r"\b(?:uneven|muddy|slippery|rocky|steep|bumpy|unpaved|rough (?:road|path|trail)s?|"
        r"flat (?:path|terrain|ground)s?|paved (?:path|road|walkway)s?)\b")),
    Rule("accessibility", "ramps and aids", _rx(
        r"\b(?:ramps?|handrails?|elevators?|lifts?|accessible (?:paths?|restrooms?|toilets?|"
        r"entrances?|parking))\b")),
    # Seasons stated as fact.
    Rule("conditions", "season", _rx(
        rf"\b(?:dry season|rainy season|wet season|typhoon season|{_MONTHS}\s*(?:-|to|–|"
        rf"‑)\s*{_MONTHS})\b")),
    Rule("conditions", "crowds", _rx(
        r"\b(?:(?:weekend|sunday|holiday)s?\b[^.]{0,40}\bcrowd\w*|crowd\w*\b[^.]{0,40}"
        r"\b(?:weekends?|sundays?|holidays?)|fill(?:s|ed)? up|gets? (?:very |quite |too )?"
        r"(?:crowded|busy|packed))\b"), _rx(r"\bcrowd")),
    # Parking and facilities.
    Rule("facilities", "parking", _rx(
        r"\b(?:(?:free|paid|ample|plenty of|limited|street|on-?site|dedicated|large|small|"
        r"public|nearby) (?:car )?parking|parking (?:is|are) (?:available|free|limited|ample)|"
        r"park (?:on|along) the street|parking lots?|(?:small|large) lots?)\b"),
         _rx(r"\bparking\b")),
    Rule("facilities", "facilities", _rx(
        r"\b(?:restrooms?|toilets?|comfort rooms?|lockers?|showers?|wi-?fi|atms?|"
        r"card terminals?|credit cards?|air-?condition\w*)\b")),
    # Rules and fees without a figure.
    Rule("rules", "rules", _rx(
        r"\b(?:(?:photography|photos?) (?:is |are )?(?:not )?(?:allowed|permitted|prohibited|"
        r"banned)|dress code|meter fees?|permits?|reservations?)\b")),
    # Named activities that are not in the record.
    Rule("activities", "activities", _rx(
        r"\b(?:guided tours?|workshops?|cultural performances?|zip-?lines?|kayak\w*|"
        r"snorkel\w*|boat rides?|horseback)\b")),
)

# Honest statements that something is not recorded: never a claim on their own.
_ABSENCE = _rx(
    r"\b(?:isn['’]t|aren['’]t|not|no|doesn['’]t|don['’]t|can['’]t|"
    r"cannot|without|never)\b[^.]{0,40}\b(?:listed|recorded|mentioned|confirm\w*|specif\w*|"
    r"available|have|know|details?)\b|\bnot (?:recorded|listed|mentioned)\b|"
    r"\bno (?:record|information|details?|data)\b")
# Advice to ask the operator is not a statement about the place.
_ASK = _rx(
    r"\b(?:ask|check|confirm|inquire|call|contact|verify)\b[^.]{0,50}"
    r"\b(?:about|whether|if|with|directly|first)\b")
# A hedge that still asserts something: absence followed by a guess.
_SPECULATION = _rx(
    r"\b(?:likely|probably|usually|typically|often|generally|most|many|some|may have|"
    r"might have|should be|can fill)\b")


# What an absence-then-guess sentence is guessing about.
_GUESS_TOPIC = _rx(
    r"\b(?:parking|park|lots?|restrooms?|toilets?|facilit\w+|ramps?|wheelchair|access\w*|"
    r"entrance fees?|fees?)\b")
_GUESS_RULE = Rule("facilities", "guess after absence", _rx(r"$^"))


@dataclass(frozen=True)
class Finding:
    sentence: str
    category: str
    rule: str
    destination_id: int | None


def _is_question(sentence: str) -> bool:
    return sentence.rstrip().endswith("?")


_DASHES = re.compile(DASH)


def _sentence_findings(sentence: str, support: str) -> list[tuple[Rule, str]]:
    # Models write non-breaking and typographic hyphens ("air‑conditioned").
    sentence = _DASHES.sub("-", sentence)
    support = _DASHES.sub("-", support)
    if _is_question(sentence):
        return []
    absence = bool(_ABSENCE.search(sentence))
    speculation = bool(_SPECULATION.search(sentence))
    # Advice to ask the operator, or a plain "not recorded", claims nothing; but a guess
    # in the same sentence ("... check with the parish, many churches have a lot") does.
    if (_ASK.search(sentence) or absence) and not speculation:
        return []
    found: list[tuple[Rule, str]] = []
    if absence and speculation:
        # "Parking isn't listed, so ... many churches have a small lot": the first half
        # is honest, the second guesses what similar places usually have.
        topic = _GUESS_TOPIC.search(sentence)
        if topic:
            found.append((_GUESS_RULE, topic.group(0)))
    for rule in RULES:
        match = rule.claim.search(sentence)
        if not match:
            continue
        # The same words in the place's own records make the claim supported.
        if (rule.support or rule.claim).search(support):
            continue
        found.append((rule, match.group(0)))
    return found


def _focus_places(
    reply: str, message: str, names: list[tuple[int, str]],
) -> set[int]:
    return mentioned_place_ids(reply, names) | mentioned_place_ids(message, names)


def find_unsupported_claims(
    reply: str,
    *,
    message: str,
    support_by_place: dict[int, str],
    names: list[tuple[int, str]],
    extra_support: str = "",
) -> list[Finding]:
    """Sentences that state something about one place that its records do not hold.

    A sentence that names exactly one place is checked against that place's records. A
    sentence that names none is checked against the one place the reply or the question
    is about, when there is exactly one; with several places it is left alone.
    """
    focus = _focus_places(reply, message, names)
    findings: list[Finding] = []
    for line in reply.split("\n"):
        for sentence in _SENTENCE_END.split(line):
            sentence = sentence.strip()
            if not sentence:
                continue
            named = mentioned_place_ids(sentence, names)
            if len(named) == 1:
                place_id: int | None = next(iter(named))
            elif not named and len(focus) == 1:
                place_id = next(iter(focus))
            else:
                continue
            support = f"{support_by_place.get(place_id, '')} {extra_support}"
            for rule, _ in _sentence_findings(sentence, support):
                findings.append(Finding(sentence, rule.category, rule.name, place_id))
    return findings


# "... , with ramps and accessible paths ..." : the part after these can be cut.
_TAIL = _rx(r",?\s+(?:with|featuring|including|offering|plus|which (?:has|have|features?))\s+")


def _trim(sentence: str, flagged: set[str]) -> str | None:
    """The sentence without a trailing clause that holds the claim, or None to drop it."""
    match = _TAIL.search(sentence)
    if not match:
        return None
    head, tail = sentence[:match.start()], sentence[match.end():]
    if len(head.split()) < 4:
        return None
    # Only cut when the claim is in the tail and the head makes no flagged claim itself.
    if not any(rule.claim.search(tail) for rule in RULES if rule.name in flagged):
        return None
    if any(rule.claim.search(head) for rule in RULES if rule.name in flagged):
        return None
    return head.rstrip(" ,;") + "."


def ground_claims(
    reply: str, findings: list[Finding],
) -> tuple[str, int]:
    """The reply with each flagged sentence trimmed or removed.

    Mirrors ground_figures: sentences that lean on a removed one go with it, and a note
    is added when something useful remains. Returns the new reply and how many sentences
    were changed or removed.
    """
    if not findings:
        return reply, 0
    by_sentence: dict[str, set[str]] = {}
    for finding in findings:
        by_sentence.setdefault(finding.sentence, set()).add(finding.rule)
    trimmed: dict[str, str] = {}

    def drop(sentence: str) -> bool:
        flagged = by_sentence.get(sentence.strip())
        if not flagged:
            return False
        shorter = _trim(sentence.strip(), flagged)
        if shorter is not None:
            trimmed[sentence.strip()] = shorter
            return False
        return True

    text, removed = filter_sentences(reply, drop)
    for original, shorter in trimmed.items():
        text = text.replace(original, shorter, 1)
    changed = removed + len(trimmed)
    if not changed:
        return reply, 0
    if NO_DATA_ANSWER in text or FIGURE_NOTE in text or CLAIM_NOTE in text:
        return text, changed
    sentences = [s for line in text.split("\n") for s in _SENTENCE_END.split(line) if s.strip()]
    if not sentences or all(s.rstrip().endswith("?") for s in sentences):
        text = f"{NO_DATA_ANSWER}\n\n{text}" if text else NO_DATA_ANSWER
    else:
        text = f"{text}\n\n{CLAIM_NOTE}"
    return text, changed


def check_claims(
    reply: str,
    *,
    mode: str,
    message: str,
    support_by_place: dict[int, str],
    names: list[tuple[int, str]],
    extra_support: str = "",
    log: Callable[[list[Finding]], None] | None = None,
) -> tuple[str, int]:
    """Run the check in the given mode: "off", "log" (reply unchanged) or "enforce"."""
    if mode == "off" or not reply:
        return reply, 0
    findings = find_unsupported_claims(
        reply, message=message, support_by_place=support_by_place, names=names,
        extra_support=extra_support,
    )
    if findings and log is not None:
        log(findings)
    if mode != "enforce":
        return reply, 0
    return ground_claims(reply, findings)
