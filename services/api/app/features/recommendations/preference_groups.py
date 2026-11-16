"""Preference groups travelers can pick (for example "Nature attractions").

A group is data in ``data/preference_groups.json``: a label, the catalog
categories it covers (optionally split into sub-types such as waterfalls),
aliases for words a traveler or the AI might use, and place-level corrections.
The same definition drives the preference chips (``GET /destinations/facets``),
the Top 5 ranking and the AI prompt, so they cannot disagree.

Only the standard library is imported so any feature can use this module.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
import re
from typing import Any, Iterable

DATA_PATH = Path(__file__).parent / "data" / "preference_groups.json"
ALIASES_PATH = Path(__file__).parent / "data" / "category_aliases.json"
SENSITIVITIES = ("low", "medium", "high")
_FUZZY_STOPWORDS = frozenset({"the", "and", "for", "spot", "area", "place", "center", "site"})


class PreferenceGroupError(ValueError):
    """The preference group file is not valid."""


@dataclass(frozen=True)
class Subtype:
    key: str
    label: str
    categories: tuple[str, ...]
    aliases: tuple[str, ...]
    rain_sensitivity: str


@dataclass(frozen=True)
class PreferenceGroup:
    key: str
    label: str
    description: str
    weight_profile: str
    aliases: tuple[str, ...]
    categories: tuple[str, ...]
    exclude_categories: tuple[str, ...]
    include_destination_ids: frozenset[int]
    exclude_destination_ids: frozenset[int]
    subtypes: dict[str, Subtype] = field(default_factory=dict)

    def keywords(self) -> tuple[str, ...]:
        return self.categories + tuple(
            keyword for subtype in self.subtypes.values() for keyword in subtype.categories
        )


@dataclass(frozen=True)
class Membership:
    """Where a place sits inside one group."""

    group: str
    subtypes: frozenset[str]
    rain_sensitivity: str


@dataclass(frozen=True)
class Resolved:
    """A word resolved to a group, and to a sub-type when the word names one."""

    group: str
    subtype: str | None


class PreferenceGroups:
    def __init__(self, groups: dict[str, PreferenceGroup]) -> None:
        self.groups = groups
        self._aliases: dict[str, Resolved] = {}
        for group in groups.values():
            self._add_alias(group.key, Resolved(group.key, None))
            self._add_alias(group.label, Resolved(group.key, None))
            for alias in group.aliases:
                self._add_alias(alias, Resolved(group.key, None))
            for subtype in group.subtypes.values():
                self._add_alias(subtype.key, Resolved(group.key, subtype.key))
                self._add_alias(subtype.label, Resolved(group.key, subtype.key))
                for alias in subtype.aliases:
                    self._add_alias(alias, Resolved(group.key, subtype.key))

    def _add_alias(self, word: str, target: Resolved) -> None:
        key = _norm(word)
        existing = self._aliases.get(key)
        if existing is not None and existing != target:
            raise PreferenceGroupError(
                f"'{word}' names both {existing.group}/{existing.subtype} and "
                f"{target.group}/{target.subtype}."
            )
        self._aliases[key] = target

    def resolve(self, term: str) -> Resolved | None:
        """The group (and sub-type) a word refers to, or None for free text."""
        return self._aliases.get(_norm(term))

    def membership(
        self, group_key: str, category: str | None, destination_id: int | None = None
    ) -> Membership | None:
        """How a place belongs to a group, or None when it does not."""
        group = self.groups[group_key]
        if destination_id is not None and destination_id in group.exclude_destination_ids:
            return None
        raw_norm = _norm(category or "")
        alias_norm = normalize_category(category)
        candidates = [c for c in {raw_norm, alias_norm} if c]

        def matches(text: str, kw: str) -> bool:
            return kw in text

        subtype_hits = frozenset(
            subtype.key
            for subtype in group.subtypes.values()
            if any(matches(c, keyword) for c in candidates for keyword in subtype.categories)
        )
        in_group = bool(subtype_hits) or any(
            matches(c, keyword) for c in candidates for keyword in group.categories
        )
        if in_group and any(excluded in raw_norm for excluded in group.exclude_categories):
            in_group = False
        if not in_group and destination_id is not None and destination_id in group.include_destination_ids:
            in_group = True
        if not in_group:
            return None
        sensitivities = [group.subtypes[key].rain_sensitivity for key in subtype_hits]
        # With several sub-types, plan for the one most affected by rain.
        rank = {name: index for index, name in enumerate(SENSITIVITIES)}
        sensitivity = max(sensitivities, key=rank.__getitem__) if sensitivities else "medium"
        return Membership(group=group_key, subtypes=subtype_hits, rain_sensitivity=sensitivity)

    def resolve_groups_for_category(
        self, category: str | None, destination_id: int | None = None
    ) -> list[str]:
        """Return claiming group keys for a category, falling back to fuzzy match or ['other']."""
        matched = [
            group.key
            for group in self.groups.values()
            if self.membership(group.key, category, destination_id) is not None
        ]
        if matched:
            return matched

        norm_cat = normalize_category(category)
        words = {
            tok
            for tok in re.split(r"[^a-z0-9]+", norm_cat)
            if len(tok) >= 3 and tok not in _FUZZY_STOPWORDS
        }
        raw_norm = _norm(category or "")
        if words:
            fuzzy: list[str] = []
            for group in self.groups.values():
                if any(excluded in raw_norm for excluded in group.exclude_categories):
                    continue
                group_words = {
                    tok
                    for term in (*group.keywords(), *group.aliases, group.label)
                    for tok in re.split(r"[^a-z0-9]+", _norm(term))
                    if len(tok) >= 3 and tok not in _FUZZY_STOPWORDS
                }
                if words & group_words:
                    fuzzy.append(group.key)
            if fuzzy:
                return fuzzy
        return ["other"]

    def categories(self, places: Iterable[Any]) -> list[dict[str, Any]]:
        """Distinct normalized catalog categories with counts, group assignment, and examples."""
        buckets: dict[str, dict[str, Any]] = {}
        for place in places:
            raw_cat = getattr(place, "category", None)
            dest_id = getattr(place, "destination_id", None)
            name = str(getattr(place, "name", "") or "").strip()
            key = normalize_category(raw_cat)
            if not key:
                continue
            groups = self.resolve_groups_for_category(raw_cat, dest_id)
            entry = buckets.get(key)
            if entry is None:
                entry = {
                    "key": key,
                    "label": format_category_label(key),
                    "count": 0,
                    "group": groups[0],
                    "groups": list(groups),
                    "examples": [],
                }
                buckets[key] = entry
            entry["count"] += 1
            for g in groups:
                if g not in entry["groups"]:
                    entry["groups"].append(g)
            if name and name not in entry["examples"] and len(entry["examples"]) < 2:
                entry["examples"].append(name)

        return sorted(
            buckets.values(),
            key=lambda item: (-item["count"], item["label"].lower()),
        )

    def facets(self, places: Iterable[Any]) -> list[dict[str, Any]]:
        """Groups with live counts from the catalog, for the preference chips."""
        places = list(places)
        result: list[dict[str, Any]] = []
        claimed_ids: set[int | None] = set()
        for group in self.groups.values():
            members = [
                (place, membership)
                for place in places
                if (membership := self.membership(
                    group.key, getattr(place, "category", None),
                    getattr(place, "destination_id", None),
                )) is not None
            ]
            claimed_ids.update(getattr(place, "destination_id", None) for place, _ in members)
            result.append({
                "key": group.key,
                "label": group.label,
                "description": group.description,
                "count": len(members),
                "subtypes": [
                    {
                        "key": subtype.key,
                        "label": subtype.label,
                        "count": sum(1 for _, m in members if subtype.key in m.subtypes),
                    }
                    for subtype in group.subtypes.values()
                ],
            })

        other_places = [
            place for place in places
            if getattr(place, "destination_id", None) not in claimed_ids
            and self.resolve_groups_for_category(
                getattr(place, "category", None),
                getattr(place, "destination_id", None),
            ) == ["other"]
        ]
        if other_places:
            result.append({
                "key": "other",
                "label": "Other",
                "description": "Additional catalog places outside fixed groups.",
                "count": len(other_places),
                "subtypes": [],
            })
        return result


def _norm(text: str) -> str:
    return " ".join(str(text).lower().split())


@lru_cache(maxsize=1)
def load_category_aliases() -> dict[str, str]:
    if not ALIASES_PATH.exists():
        return {}
    raw = json.loads(ALIASES_PATH.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        return {}
    return {_norm(k): _norm(v) for k, v in raw.items() if isinstance(k, str) and isinstance(v, str)}


def normalize_category(raw: str | None) -> str:
    """Normalize category spelling, plurals, and aliases into a canonical lowercase key."""
    if not raw:
        return ""
    cleaned = _norm(re.sub(r"\s*/\s*", " / ", str(raw)))
    if not cleaned:
        return ""
    aliases = load_category_aliases()
    if cleaned in aliases:
        return aliases[cleaned]
    if len(cleaned) > 4 and cleaned.endswith("ies"):
        candidate = cleaned[:-3] + "y"
        return aliases.get(candidate, candidate)
    if len(cleaned) > 4 and cleaned.endswith("s") and not cleaned.endswith(("ss", "us", "is")):
        candidate = cleaned[:-1]
        if candidate in aliases:
            return aliases[candidate]
        if "/" not in candidate:
            return candidate
    return cleaned


def format_category_label(key: str) -> str:
    """Readable title label from a canonical category key."""
    minor = {"of", "and", "the", "in"}
    words = key.split()
    return " ".join(
        w if (i > 0 and w in minor) else w.capitalize()
        for i, w in enumerate(words)
    )


def parse(raw: dict, *, profile_names: Iterable[str]) -> PreferenceGroups:
    """Validate a parsed preference group file."""
    profile_names = set(profile_names)
    groups_raw = raw.get("groups") if isinstance(raw, dict) else None
    if not isinstance(groups_raw, dict) or not groups_raw:
        raise PreferenceGroupError("The file needs a non-empty 'groups' object.")

    def words(body: dict, key: str, where: str, *, required: bool = False) -> tuple[str, ...]:
        value = body.get(key, [])
        if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
            raise PreferenceGroupError(f"{where}: '{key}' must be a list of non-empty words.")
        if required and not value:
            raise PreferenceGroupError(f"{where}: '{key}' cannot be empty.")
        return tuple(_norm(v) for v in value)

    def ids(body: dict, key: str, where: str) -> frozenset[int]:
        value = body.get(key, [])
        if not isinstance(value, list) or not all(
            isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in value
        ):
            raise PreferenceGroupError(f"{where}: '{key}' must be a list of destination ids.")
        return frozenset(value)

    groups: dict[str, PreferenceGroup] = {}
    for key, body in groups_raw.items():
        where = f"Group '{key}'"
        if not isinstance(body, dict) or not str(body.get("label") or "").strip():
            raise PreferenceGroupError(f"{where} needs a label.")
        profile = body.get("weight_profile", "default")
        if profile not in profile_names:
            raise PreferenceGroupError(f"{where}: unknown weight profile '{profile}'.")
        subtypes: dict[str, Subtype] = {}
        for subtype_key, sub in (body.get("subtypes") or {}).items():
            sub_where = f"{where}, sub-type '{subtype_key}'"
            sensitivity = sub.get("rain_sensitivity", "medium")
            if sensitivity not in SENSITIVITIES:
                raise PreferenceGroupError(f"{sub_where}: rain_sensitivity must be low, medium or high.")
            subtypes[subtype_key] = Subtype(
                key=subtype_key,
                label=str(sub.get("label") or subtype_key),
                categories=words(sub, "categories", sub_where, required=True),
                aliases=words(sub, "aliases", sub_where),
                rain_sensitivity=sensitivity,
            )
        categories = words(body, "categories", where, required=not subtypes)
        groups[key] = PreferenceGroup(
            key=key,
            label=str(body["label"]).strip(),
            description=str(body.get("description") or ""),
            weight_profile=profile,
            aliases=words(body, "aliases", where),
            categories=categories,
            exclude_categories=words(body, "exclude_categories", where),
            include_destination_ids=ids(body, "include_destination_ids", where),
            exclude_destination_ids=ids(body, "exclude_destination_ids", where),
            subtypes=subtypes,
        )
    return PreferenceGroups(groups)


@lru_cache(maxsize=1)
def load_groups() -> PreferenceGroups:
    from app.features.recommendations.weight_profiles import load_config

    raw = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    return parse(raw, profile_names=load_config().profiles)
