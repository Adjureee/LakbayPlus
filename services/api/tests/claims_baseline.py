"""Opt-in measurement of claims-without-numbers in live chat replies.

Step 1 of docs/AI_CLAIMS_CHECK_PLAN.md. It changes no product behaviour. It

1. `collect`: asks the deployed guest chat place-specific questions (default 12 places
   x 4 questions; the guest endpoint allows 6 calls a minute per IP, so this is slow)
   and saves each reply with the public record of the place it is about;
2. `judge`: asks a model to label every sentence of each reply as supported,
   unsupported or generic against that record, one judge call per reply;
4. `replay`: runs the runtime claims check (app/features/ai/claims.py) over the judged
   replies and compares it with the judge: caught, missed and wrongly flagged.
3. `report`: prints how many replies hold an unsupported claim, by category, and writes a
   labeled sample for a human spot-check.

    python tests/claims_baseline.py collect --out claims_replies.json
    python tests/claims_baseline.py judge --replies claims_replies.json --out claims_labels.json
    python tests/claims_baseline.py report --labels claims_labels.json

The judge uses the fallback provider (FALLBACK_LLM_* in the local .env) by default, a
different model family from the Groq chat model; pass --provider groq to use Groq. The
judge is a measuring tool only and is never used at runtime. The file name has no
test_ prefix, so the normal test suite does not run it.
"""

import argparse
import asyncio
import json
import random
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

BASE = "https://lakbay-api-rioi.onrender.com/api/v1"
DAVAO = {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}
QUESTIONS = (
    "Is {name} wheelchair accessible?",
    "What can I do at {name}?",
    "Tell me about {name}.",
    "Is there parking at {name}?",
)
# Fields of the public record that the chat could have used as facts.
RECORD_FIELDS = (
    "name", "description", "district", "location", "category", "vibes", "activities",
    "entrance_fee", "overnight_fee", "estimated_cost", "operating_hours",
    "best_time_to_visit", "best_time_basis", "how_to_get_there", "estimated_travel_time",
    "travel_notes", "what_to_bring", "budget_class", "crowd_level", "difficulty_level",
    "stay_duration_type", "transport_accessibility", "booking_requirement",
    "booking_note", "parking_note", "operating_status", "is_kid_friendly",
    "is_wheelchair_accessible", "is_pet_friendly", "is_elderly_friendly",
    "family_friendly", "couple_friendly", "group_friendly",
)
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")

JUDGE_SYSTEM = (
    "You check sentences from a travel assistant's reply against the record of ONE place. "
    "For each numbered sentence, return a label: "
    "'supported' (every place-specific fact in it is stated in the record or clearly "
    "implied by it), 'unsupported' (it states a place-specific fact the record does not "
    "hold: facilities such as parking or restrooms, accessibility details such as ramps, "
    "paths or stairs, rules, crowd or weather conditions, how to get there, activities, "
    "opening status, or any number), or 'generic' (a general travel tip, a question, or "
    "no place-specific fact). A sentence that says the information is not recorded, not "
    "listed or cannot be confirmed is 'generic': it claims nothing about the place. The "
    "record may also list room and transport rates (prices, fares, durations): a figure "
    "found there is supported. A flag such as is_wheelchair_accessible true supports "
    "'wheelchair accessible' but not ramps or paths. A missing or null field is unknown, "
    "never 'no'. Reply with JSON only: "
    '{"results":[{"n":1,"label":"supported|unsupported|generic",'
    '"claim":"the unsupported claim in a few words, or null",'
    '"category":"accessibility|facilities|rules|conditions|status|access|activities|numbers|other|null"}]}'
)


def _get(path: str):
    with urllib.request.urlopen(BASE + path, timeout=90) as response:
        return json.load(response)


def _chat(message: str) -> dict:
    body = {"message": message, "use_rag": True, "input_revision": 1, "history": [],
            "planning_state": {"origin": DAVAO, "destination_ids": [], "interests": []}}
    request = urllib.request.Request(
        BASE + "/ai/chat/guest", data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        return {"error": error.code}


def _richness(place: dict) -> int:
    return sum(1 for key in RECORD_FIELDS if place.get(key) not in (None, "", []))


def pick_places(count: int, seed: int) -> list[dict]:
    """A spread of rich and sparse records, so thin records are well represented."""
    places = sorted(_get("/destinations?limit=100"), key=_richness)
    rng = random.Random(seed)
    third = max(1, len(places) // 3)
    groups = (places[:third], places[third:2 * third], places[2 * third:])
    chosen: list[dict] = []
    for index in range(count):
        # Without replacement, so the number of places asked for is the number returned.
        pool = [p for p in groups[index % 3] if p not in chosen] or [
            p for p in places if p not in chosen
        ]
        if pool:
            chosen.append(rng.choice(pool))
    return chosen


def collect(args) -> None:
    out = Path(args.out)
    done = json.loads(out.read_text(encoding="utf-8")) if out.exists() else []
    seen = {(row["destination_id"], row["question"]) for row in done}
    places = pick_places(args.places, args.seed)
    print(f"{len(places)} places; {len(done)} replies already saved")
    for place in places:
        record = {key: place.get(key) for key in RECORD_FIELDS if place.get(key) not in (None, "")}
        for template in QUESTIONS:
            question = template.format(name=place["name"])
            if (place["destination_id"], question) in seen:
                continue
            reply = _chat(question)
            if "error" in reply:
                print("  error", reply["error"], "for:", question)
                time.sleep(20)
                continue
            done.append({
                "destination_id": place["destination_id"], "name": place["name"],
                "question": question, "reply": reply["chat_response"], "record": record,
                "model": reply.get("model_id"),
            })
            out.write_text(json.dumps(done, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"  {len(done):3d}  {question}")
            time.sleep(args.delay)  # the guest endpoint allows 6 calls a minute per IP


def _sentences(reply: str) -> list[str]:
    return [s.strip() for line in reply.split("\n") for s in SENTENCE_END.split(line) if s.strip()]


_RATES: dict[int, dict] = {}
RATE_FIELDS = ("name", "room_type", "price", "charging_unit", "capacity", "description",
               "transport_type", "mode", "origin", "route", "fare", "duration_minutes",
               "distance_km", "notes", "currency")


def _rates(destination_id: int) -> dict:
    """The place's room and transport records: the chat is given these as facts too."""
    if destination_id not in _RATES:
        found = {}
        for kind in ("accommodations", "transportations"):
            try:
                rows = _get(f"/destinations/{destination_id}/{kind}")
            except Exception:
                rows = []
            found[kind] = [
                {k: v for k, v in row.items() if k in RATE_FIELDS and v not in (None, "")}
                for row in rows
            ]
        _RATES[destination_id] = found
    return _RATES[destination_id]


async def _judge_one(client, settings, args, row: dict) -> dict | None:
    sentences = _sentences(row["reply"])
    if not sentences:
        return None
    numbered = "\n".join(f"{i}. {s}" for i, s in enumerate(sentences, 1))
    record = {**row["record"], **_rates(row["destination_id"])}
    user = (
        f"Record of {row['name']}:\n{json.dumps(record, ensure_ascii=False)}\n\n"
        f"Sentences:\n{numbered}"
    )
    model = (settings.fallback_llm_model if args.provider == "fallback_llm"
             else args.model or settings.groq_model)
    completion = await client.create_chat_completion(
        model=model, provider=args.provider, temperature=0, max_tokens=1500,
        response_format={"type": "json_object"},
        messages=[{"role": "system", "content": JUDGE_SYSTEM},
                  {"role": "user", "content": user}],
        max_rate_limit_wait_seconds=10,
    )
    text = completion.content.strip()
    text = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.MULTILINE).strip()
    results = json.loads(text).get("results", [])
    by_n = {r.get("n"): r for r in results if isinstance(r, dict)}
    labeled = []
    for i, sentence in enumerate(sentences, 1):
        r = by_n.get(i, {})
        labeled.append({
            "sentence": sentence, "label": r.get("label", "missing"),
            "claim": r.get("claim"), "category": r.get("category"),
        })
    return {**{k: row[k] for k in ("destination_id", "name", "question", "reply")},
            "sentences": labeled, "judge_model": model}


async def judge(args) -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from app.core.config import get_settings
    from app.integrations.groq.client import GroqClient

    settings = get_settings()
    client = GroqClient(settings)
    rows = json.loads(Path(args.replies).read_text(encoding="utf-8"))
    out = Path(args.out)
    done = json.loads(out.read_text(encoding="utf-8")) if out.exists() else []
    seen = {(r["destination_id"], r["question"]) for r in done}
    for row in rows:
        if (row["destination_id"], row["question"]) in seen:
            continue
        try:
            result = await _judge_one(client, settings, args, row)
        except Exception as error:  # a failed judge call is skipped, never guessed
            print("  judge failed:", type(error).__name__, row["question"])
            await asyncio.sleep(10)
            continue
        if result:
            done.append(result)
            out.write_text(json.dumps(done, ensure_ascii=False, indent=1), encoding="utf-8")
            print(f"  {len(done):3d}  {row['question']}")
        await asyncio.sleep(args.delay)


def report(args) -> None:
    rows = json.loads(Path(args.labels).read_text(encoding="utf-8"))
    labels = Counter()
    categories = Counter()
    replies_with_unsupported = 0
    by_question = Counter()
    for row in rows:
        flagged = [s for s in row["sentences"] if s["label"] == "unsupported"]
        labels.update(s["label"] for s in row["sentences"])
        categories.update(s["category"] or "other" for s in flagged)
        if flagged:
            replies_with_unsupported += 1
            by_question[row["question"].split(" ")[0] + " ..."] += 1
    total = sum(labels.values())
    print(f"{len(rows)} replies, {total} sentences")
    print("labels:", dict(labels))
    print(f"replies with at least one unsupported sentence: "
          f"{replies_with_unsupported}/{len(rows)} "
          f"({100 * replies_with_unsupported / max(1, len(rows)):.0f}%)")
    print("unsupported sentences by category:", dict(categories.most_common()))
    sample = [
        {"destination": r["name"], "question": r["question"], "sentence": s["sentence"],
         "judge_label": s["label"], "claim": s["claim"], "category": s["category"]}
        for r in rows for s in r["sentences"] if s["label"] in {"supported", "unsupported"}
    ]
    random.Random(args.seed).shuffle(sample)
    Path(args.sample_out).write_text(
        json.dumps(sample[:args.sample], ensure_ascii=False, indent=1), encoding="utf-8",
    )
    print(f"wrote {min(args.sample, len(sample))} sentences for a human spot-check to "
          f"{args.sample_out}")


def replay(args) -> None:
    """The runtime check against the judge's labels (no model calls, no network)."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from app.features.ai.claims import find_unsupported_claims
    from app.features.ai.grounding import _fact_values

    labeled = json.loads(Path(args.labels).read_text(encoding="utf-8"))
    records = {
        (r["destination_id"], r["question"]): r
        for r in json.loads(Path(args.replies).read_text(encoding="utf-8"))
    }
    names = sorted({(r["destination_id"], r["name"]) for r in labeled})
    caught = missed = wrong = right = 0
    lines = []
    for row in labeled:
        record = records[(row["destination_id"], row["question"])]["record"]
        support = {row["destination_id"]: " ".join(
            [_fact_values(record), json.dumps(_rates(row["destination_id"]))])}
        findings = find_unsupported_claims(
            row["reply"], message=row["question"], support_by_place=support, names=names,
        )
        flagged = {f.sentence: f for f in findings}
        for item in row["sentences"]:
            sentence, label = item["sentence"], item["label"]
            hit = sentence in flagged
            if label == "unsupported" and hit:
                caught += 1
            elif label == "unsupported":
                missed += 1
                lines.append(("MISSED ", row["name"], sentence, item["claim"]))
            elif hit:
                wrong += 1
                lines.append(("FALSE  ", row["name"], sentence, flagged[sentence].rule))
            else:
                right += 1
    total_unsupported = caught + missed
    others = wrong + right
    print(f"judge-unsupported sentences: {total_unsupported}; caught {caught}, missed {missed}")
    print(f"other sentences: {others}; wrongly flagged {wrong}")
    print(f"recall {100 * caught / max(1, total_unsupported):.0f}%  "
          f"false-flag rate {100 * wrong / max(1, others):.1f}%")
    for kind, name, sentence, note in lines:
        print(f"  {kind} {name[:18]:18} | {sentence[:130]}  [{note}]")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--out", default="claims_replies.json")
    c.add_argument("--places", type=int, default=12)
    c.add_argument("--seed", type=int, default=7)
    c.add_argument("--delay", type=float, default=11.5)
    j = sub.add_parser("judge")
    j.add_argument("--replies", default="claims_replies.json")
    j.add_argument("--out", default="claims_labels.json")
    j.add_argument("--provider", default="fallback_llm", choices=["fallback_llm", "groq"])
    j.add_argument("--model", default=None)
    j.add_argument("--delay", type=float, default=7.0)
    r = sub.add_parser("report")
    r.add_argument("--labels", default="claims_labels.json")
    r.add_argument("--sample", type=int, default=50)
    r.add_argument("--sample-out", default="claims_sample.json")
    r.add_argument("--seed", type=int, default=7)
    p = sub.add_parser("replay")
    p.add_argument("--labels", default="claims_labels.json")
    p.add_argument("--replies", default="claims_replies.json")
    args = parser.parse_args()
    if args.command == "replay":
        replay(args)
        return
    if args.command == "collect":
        collect(args)
    elif args.command == "judge":
        asyncio.run(judge(args))
    else:
        report(args)


if __name__ == "__main__":
    main()
