"""Claims about a place that its records do not hold (no number needed).

The figure check in grounding.py removes prices, distances and times the records do not
hold. This module covers statements without a number: terrain ("uneven path"), seasons
("dry season, Nov-May"), parking ("street parking is usually available"), facilities
("restrooms", "card terminals"), accessibility details ("ramps"), rules ("meter fees",
"photography allowed") and named activities ("guided tours", "zipline"), and the conditions a tip gives as its reason ("to avoid crowds", "when the
weather's cooler", "sudden rain can hit", "when the eagles are most active"). For a tip the
reason is cut and the advice kept (docs/AI_TIPS_CLAIMS_PLAN.md).

A claim is flagged only when the sentence is about one place and the place's own records
do not contain the claim's word. Left alone: questions, honest absence statements
("Parking isn't listed"), advice to ask the operator ("ask about ramps"), what to bring
("bring sunscreen"), and the timing advice itself ("go early in the morning").
A hedge ("likely", "usually", "many ... have") does not make a claim safe: the
absence-then-speculation pattern is the one seen most in live replies.

Modes (settings.claims_check_mode): "enforce" (the default: flagged sentences are trimmed
or removed), "log" (findings are logged, the reply is unchanged) and "off".
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
        r"flat (?:path|terrain|ground)s?|paved (?:path|road|walkway)s?|"
        r"wide (?:paths?|walkways?|doors?|entrances?|aisles?))\b")),
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
    # The conditions a tip gives as its reason. The advice ("go early", "bring a hat") is
    # not checked; the reason is a statement about the place, supported only by a record
    # that says the same thing.
    Rule("conditions", "crowd reasons", _rx(
        r"\b(?:(?:avoid\w*|beat|skip|dodge|escape)\s+(?:the\s+)?(?:(?:weekend|worst|small|"
        r"big|large|usual|heavy|biggest|afternoon|midday)\s+)*(?:crowds?|rush(?: hour)?|"
        r"queues?|lines)|(?:fewer|less|smaller|thinner)\s+(?:crowds?|people|visitors|"
        r"tourists)|less crowded|(?:small|thin) crowds?|(?:busiest|peak)\s+"
        r"(?:time|hours?|days?|periods?))\b"),
         _rx(r"\bcrowd|\bbusy|\bpeak|\bquiet|\bqueue")),
    Rule("conditions", "heat and cool", _rx(
        r"\b(?:(?:cool(?:er)?|cold(?:er)?|warm(?:er)?)\s+(?:(?:city|evening|morning|park|"
        r"garden)\s+)?(?:walks?|strolls?|visits?|trips?|outings?)|"
        r"(?:cool(?:er)?|cold(?:er)?|warm(?:er)?|hot(?:ter)?|humid)\s+(?:\w+\s+){0,2}(?:weather|air|"
        r"breeze|temperatures?|morning|evening|hours?|conditions?)|(?:weather|air|"
        r"temperatures?|it|park|place|area|garden|spot)(?:['’]s| is| are| gets?| turns?)\s+(?:much |a bit |quite |"
        r"a little )?(?:cool(?:er)?|cold(?:er)?|warm(?:er)?|hot(?:ter)?|humid)|"
        # any short subject: "when the breeze is cooler", "the evening feels warmer"
        r"(?:\w+\s+){1,3}(?:is|are|gets?|turns?|feels?)\s+(?:much |a bit |quite |a little )?"
        r"(?:cooler|warmer)|avoid\w*\s+"
        r"(?:the\s+)?(?:(?:strongest|worst|harsh|midday|noon|afternoon|hot)\s+)*(?:sun|heat)|"
        r"can (?:get|be|become) (?:very |quite |too |a bit )?(?:warm|hot|humid|stuffy|cold)|"
        # "when the sun's heat eases", "beat the heat", "a milder sun"
        r"(?:sun['’]s\s+)?heat\s+(?:eases|fades|subsides|dies down|lets up|drops)|"
        r"beat the heat|(?:milder|gentler|softer)\s+(?:sun|heat|sunlight))"
        r"\b"),
         _rx(r"\bcool|\bcold|\bwarm|\bhot\b|\bheat|\bhumid|\bbreez|\bshade")),
    Rule("conditions", "rain", _rx(
        r"\b(?:(?:sudden|heavy|frequent|afternoon)\s+(?:rain|showers?|downpours?)|"
        r"rain\s+(?:can|may|often|usually|tends?)|(?:rain|showers?)\b[^.]{0,20}\b"
        r"(?:can|may)\s+(?:hit|fall|pour|come))\b"),
         _rx(r"\brain|\bwet\b|\bshower|\bdownpour|\bstorm")),
    Rule("conditions", "activity timing", _rx(
        r"\b(?:(?:most|more|very) active|when the (?:lights|lanterns)\b[^.]{0,15}\bare on|"
        r"feeding (?:time|hours?|sessions?))\b"),
         _rx(r"\bactive\b|\blights?\b|\bfeeding|\blanterns?")),
    # Parking and facilities.
    Rule("facilities", "parking", _rx(
        r"\b(?:(?:free|paid|ample|plenty of|limited|street|on-?site|dedicated|large|small|"
        r"public|nearby) (?:car )?parking|parking (?:is|are) (?:available|free|limited|ample)|"
        r"park (?:on|along) the street|parking lots?|(?:small|large) lots?)\b"),
         _rx(r"\bparking\b")),
    # Where people park, said as an action ("most visitors park near the entrance"). Only
    # a recorded parking note supports it: "park" alone would match every "Nature Park".
    Rule("facilities", "where to park", _rx(
        r"\b(?:visitors?|guests?|people|travell?ers|drivers|tourists?|you|they|most|many)\s+"
        r"(?:(?:can|could|may|will|usually|typically|often|generally|simply|just)\s+)*park\b"
        r"(?!\s+(?:entrance|gate|grounds|trail|area|visit|is|has|are)\b)|"
        r"\bpark (?:your|the|a) (?:car|vehicle|motorbike|motorcycle|van|bike)\b|"
        # "most visitors drive to the falls and park near the entrance"
        r"\b(?:and|then)\s+park\s+(?:near|at|along|beside|by|outside|inside|in|around|"
        r"close to)\b"),
         _rx(r"\bparking\b")),
    # A guess about places in general ("most farms in Davao City have open-space parking"):
    # no record of this place can support it, so it is never supported.
    Rule("facilities", "generalisation", _rx(
        r"\b(?:most|many)\s+(?:[\w'-]+\s+){1,5}?(?:have|has|offer|offers|provide|provides|"
        r"include|includes)\b[^.]{0,60}\b(?:parking|lots?|restrooms?|toilets?|facilit\w+|"
        r"ramps?|cottages?)\b"),
         _rx(r"$^")),
    Rule("facilities", "facilities", _rx(
        r"\b(?:restrooms?|toilets?|comfort rooms?|lockers?|showers?|wi-?fi|atms?|"
        r"card terminals?|credit cards?|air-?condition\w*)\b")),
    # Rules and fees without a figure.
    Rule("rules", "rules", _rx(
        r"\b(?:(?:photography|photos?) (?:is |are )?(?:not )?(?:allowed|permitted|prohibited|"
        r"banned)|dress code|meter fees?|permits?|reservations?)\b")),
    # Named activities that are not in the record.
    Rule("activities", "activities", _rx(
        r"\b(?:workshops?|cultural performances?|"
        r"zip-?lines?|kayak\w*|snorkel\w*|boat rides?|horseback)\b")),
    # What an entry fee covers ("charges P600, which includes a tour") needs a recorded
    # inclusion.
    Rule("rules", "what the fee includes", _rx(
        r"\b(?:entry|entrance|admission|tickets?|fees?|rates?|prices?)\b[^.]{0,50}?"
        r"\b(?:includes?|inclusive of|covers?)\b|\bwhich\s+(?:includes?|covers?)\b"),
         _rx(r"\binclu|\bcovers?\b")),
    # A "guided ... tour" is supported by a recorded guided visit, walk or tour.
    Rule("activities", "guided tour", _rx(r"\bguided(?:\s+[\w-]+){0,3}?\s+tours?\b"),
         _rx(r"\bguided\b|\btours?\b")),
    # How to get there by a named vehicle, when the place's records name none.
    Rule("access", "transport", _rx(
        r"\b(?:tricycles?|jeepneys?|habal-?habal|buses|bus|vans?|shuttles?|motorcycles?|"
        r"taxis?|ferry|ferries)\b")),
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
    r"\b(?:about|whether|if|with|directly|first)\b"
    # "you can call the staff", "call them", "to ask": plain advice to ask the operator.
    r"|\b(?:call|contact|ask|phone|visit)\s+(?:the|them|their|staff|us)\b|\bto ask\b")
# A hedge that still asserts something: absence followed by a guess.
_CONTRAST = _rx(r"\b(?:but|however|though|although|yet)\b")
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
    absent = _ABSENCE.search(sentence)
    absence = bool(absent)
    # "not recorded, but street parking is available": a "but" AFTER the absence turns an
    # honest "not recorded" into an assertion, unless the rest is only advice to ask the
    # operator. A "but" before it ("listed as family friendly, but accessibility is not
    # specified") is still honest.
    speculation = bool(_SPECULATION.search(sentence)) or (
        absent is not None
        and bool(_CONTRAST.search(sentence, absent.end()))
        and not _ASK.search(sentence)
    )
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
_TAIL = _rx(
    r",?\s+(?:with|featuring|including|offering|plus|which (?:has|have|features?|includes?)|"
    # "..., so you can enjoy its wide paths": the consequence clause, not the answer.
    r"so (?=you|visitors|guests|travell?ers\b))\s*")


# A sentence that opens with one of these is a dependent clause: cutting its end would
# leave a fragment ("Because it's a highland spot."), so it is dropped whole.
_SUBORDINATE = _rx(r"^\s*(?:because|since|as|although|though|if|when|while|given|due to)\b")
# Where an honest "not recorded" clause ends and the guess begins.
_CLAUSE_BREAK = _rx(r",|;|\s-\s|\s+so\s")


def _words(text: str) -> int:
    return len(text.split())


# The reasons a tip gives (see the rules above): cut, with the advice kept.
_REASON_RULES = {"crowd reasons", "heat and cool", "rain", "activity timing"}
# Where a reason clause starts: "to avoid ...", "for cooler weather", "when/as/since ...".
_REASON_START = _rx(
    r",?\s+(?:to (?:avoid|beat|skip|dodge|escape|enjoy)|for (?:a |the )?(?:cooler|cool|warmer|"
    r"fewer|less|smaller|clearer|best)|(?:when|as|since|because|while|so)\b)")
# Where the reason ends and the next piece of advice begins: ", and bring ...", ";", a dash.
_REASON_END = _rx(
    r",?\s+(?:and\s+)?(?:then\s+)?(?:bring|wear|pack|carry|take|check|use|dress|arrive|go|"
    r"visit|expect|stay|enjoy|try|book|reserve|remember)\b|,?\s+with\b|\s*[;—–]|\s-\s")
_SEPARATOR = _rx(r"\s*[;—–]\s*|\s-\s")


def _cut_reasons(
    sentence: str, norm: str, rules: list[Rule], *, connectors: bool = True,
) -> str | None:
    """The tip without the clauses that give an unsupported reason, or None if it cannot be
    cut cleanly ("Go early to avoid crowds and bring a hat" becomes "Go early and bring a
    hat"). Slices the original; the dash-normalised copy is the same length."""
    ending = sentence[-1] if sentence and sentence[-1] in ".!" else "."
    for _ in range(4):
        match = next((m for rule in rules if (m := rule.claim.search(norm))), None)
        if match is None:
            break
        starts = [m for m in _REASON_START.finditer(norm, 0, match.end())
                  if connectors and m.start() <= match.start()
                  and match.start() - m.start() <= 60]
        if starts:
            begin = starts[-1].start()
        else:
            seps = list(_SEPARATOR.finditer(sentence, 0, match.start()))
            if not seps:
                return None
            begin = seps[-1].start()
        stop = _REASON_END.search(sentence, match.end())
        end = stop.start() if stop else len(norm.rstrip(" .!"))
        head = sentence[:begin].rstrip(" ,;-—–.!")
        tail = sentence[end:]
        # Advice left without its "and" starts a sentence of its own ("... 6 PM. Bring a ID").
        lead = re.match(r",?\s+(?:then\s+)?(?=[a-z])", tail)
        if stop and lead and not re.match(r",?\s+(?:and|with)\b", tail, re.I):
            rest = tail[lead.end():]
            sentence = head + ". " + rest[:1].upper() + rest[1:]
        else:
            sentence = head + tail
        sentence = sentence.rstrip(" ,;-—–.!") + ending
        norm = _DASHES.sub("-", sentence)
    if any(rule.claim.search(norm) for rule in rules) or _words(sentence) < 3:
        return None
    return sentence


def _trim(sentence: str, flagged: set[str]) -> str | None:
    """A shorter sentence without the part that holds the claim, or None to drop it.

    In order: a guess after "not recorded" is cut back to the honest clause; a trailing
    "with ..." clause holding the claim is cut; items of a list that hold the claim are
    removed when others remain. A dependent clause is never cut (it would leave a
    fragment) and anything else is dropped whole.
    """
    # Matching uses the dash-normalised copy; slicing uses the original (same length).
    norm = _DASHES.sub("-", sentence)
    if _SUBORDINATE.match(norm):
        return None
    rules = [rule for rule in RULES if rule.name in flagged]

    reasons = [rule for rule in rules if rule.name in _REASON_RULES]
    if reasons:
        cut = _cut_reasons(sentence, norm, reasons)
        if cut is None:
            return None
        # What is left may still hold another flagged claim ("... to avoid crowds, and take
        # a tricycle"): trim that the usual way, or drop the sentence.
        left = {rule.name for rule in rules
                if rule.name not in _REASON_RULES
                and rule.claim.search(_DASHES.sub("-", cut))}
        if not left:
            return cut
        # Another claim after a dash or semicolon is cut with its clause; otherwise the usual
        # trim, or the sentence goes.
        rest = [rule for rule in rules if rule.name in left]
        return (_cut_reasons(cut, _DASHES.sub("-", cut), rest, connectors=False)
                or _trim(cut, left))

    if _GUESS_RULE.name in flagged:
        absence = _ABSENCE.search(norm)
        if absence:
            brk = _CLAUSE_BREAK.search(norm, absence.end())
            if brk and _words(sentence[:brk.start()]) >= 3:
                return sentence[:brk.start()].rstrip(" ,;-") + "."
        return None

    match = _TAIL.search(norm)
    if match:
        head, tail = norm[:match.start()], norm[match.end():]
        # Only cut when the claim is in the tail and the head makes no flagged claim itself.
        if (
            _words(head) >= 4
            and any(rule.claim.search(tail) for rule in rules)
            and not any(rule.claim.search(head) for rule in rules)
        ):
            return sentence[:match.start()].rstrip(" ,;") + "."

    items = sentence.rstrip(" .!").split(", ")
    if len(items) >= 4 and rules:
        norm_items = norm.rstrip(" .!").split(", ")
        keep = [
            item for item, plain in zip(items, norm_items, strict=True)
            if not any(rule.claim.search(plain) for rule in rules)
        ]
        # The first item holds the subject and verb: it must survive, and so must at
        # least one other item.
        if len(keep) < len(items) and keep[:1] == items[:1] and len(keep) >= 2:
            return ", ".join(keep) + "."
    return None


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
