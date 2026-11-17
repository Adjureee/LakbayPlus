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
from typing import Any, Iterable

DATA_PATH = Path(__file__).parent / "data" / "preference_groups.json"
SENSITIVITIES = ("low", "medium", "high")


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
        text = _norm(category or "")
        subtype_hits = frozenset(
            subtype.key
            for subtype in group.subtypes.values()
            if any(keyword in text for keyword in subtype.categories)
        )
        in_group = bool(subtype_hits) or any(keyword in text for keyword in group.categories)
        if in_group and any(excluded in text for excluded in group.exclude_categories):
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

    def facets(self, places: Iterable[Any]) -> list[dict[str, Any]]:
        """Groups with live counts from the catalog, for the preference chips."""
        places = list(places)
        result: list[dict[str, Any]] = []
        for group in self.groups.values():
            members = [
                (place, membership)
                for place in places
                if (membership := self.membership(
                    group.key, getattr(place, "category", None),
                    getattr(place, "destination_id", None),
                )) is not None
            ]
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
        return result


def _norm(text: str) -> str:
    return " ".join(str(text).lower().split())


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
