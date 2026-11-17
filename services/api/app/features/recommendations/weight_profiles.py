"""Weight profiles for the weighted scoring (SAW) model, loaded from JSON.

The weights and thresholds are data, not code: they live in
``data/weight_profiles.json`` so they can be reviewed and changed without
touching the scoring formulas. The file is validated on first use; an invalid
file raises :class:`WeightProfileError` and the server should not start with it.

Only the standard library is imported so that ``scoring`` can use this module.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

DATA_PATH = Path(__file__).parent / "data" / "weight_profiles.json"

# Every criterion the scoring module knows how to compute.
KNOWN_CRITERIA = frozenset({
    "interest", "travel", "budget", "group_fit", "popularity",
    "nature_fit", "physical_suitability", "weather_season", "access", "quiet_popular",
})
SENSITIVITIES = ("low", "medium", "high")
WEIGHT_SUM_TOLERANCE = 1e-6


class WeightProfileError(ValueError):
    """The weight profile file is not valid."""


@dataclass(frozen=True)
class Thresholds:
    day_trip_max_travel_minutes: int
    multi_day_max_travel_minutes: int
    large_group_size: int
    young_child_max_age: int
    rain_low_below_percent: int
    rain_high_from_percent: int
    rain_sensitivity_factors: dict[str, float]
    relax_travel_factor: float
    relax_budget_factor: float
    priority_blend: float
    max_priorities: int


@dataclass(frozen=True)
class WeightProfile:
    name: str
    rationale: str
    weights: dict[str, float]
    # Traveler priority name -> criterion it raises (empty for the default profile).
    priority_criteria: dict[str, str]


@dataclass(frozen=True)
class WeightConfig:
    profiles: dict[str, WeightProfile]
    thresholds: Thresholds

    @property
    def default(self) -> WeightProfile:
        return self.profiles["default"]


def parse(raw: dict) -> WeightConfig:
    """Validate a parsed weight file and build the config."""
    try:
        profiles_raw = raw["profiles"]
        thresholds_raw = raw["thresholds"]
    except (KeyError, TypeError) as exc:
        raise WeightProfileError("The file needs 'profiles' and 'thresholds'.") from exc
    if not isinstance(profiles_raw, dict) or "default" not in profiles_raw:
        raise WeightProfileError("A 'default' profile is required.")

    profiles: dict[str, WeightProfile] = {}
    for name, body in profiles_raw.items():
        weights = body.get("weights") if isinstance(body, dict) else None
        if not isinstance(weights, dict) or not weights:
            raise WeightProfileError(f"Profile '{name}' needs weights.")
        unknown = sorted(set(weights) - KNOWN_CRITERIA)
        if unknown:
            raise WeightProfileError(f"Profile '{name}' has unknown criteria: {unknown}.")
        for criterion, weight in weights.items():
            if not isinstance(weight, (int, float)) or isinstance(weight, bool) or weight <= 0:
                raise WeightProfileError(
                    f"Profile '{name}': weight for '{criterion}' must be a positive number."
                )
        total = sum(weights.values())
        if abs(total - 1.0) > WEIGHT_SUM_TOLERANCE:
            raise WeightProfileError(
                f"Profile '{name}': weights add up to {total:.6f}, not 1."
            )
        priority_criteria = dict(body.get("priority_criteria") or {})
        for priority, criterion in priority_criteria.items():
            if criterion not in weights:
                raise WeightProfileError(
                    f"Profile '{name}': priority '{priority}' points to '{criterion}', "
                    "which is not one of its criteria."
                )
        profiles[name] = WeightProfile(
            name=name,
            rationale=str(body.get("rationale") or ""),
            weights={key: float(value) for key, value in weights.items()},
            priority_criteria=priority_criteria,
        )

    return WeightConfig(profiles=profiles, thresholds=_parse_thresholds(thresholds_raw))


def _parse_thresholds(raw: dict) -> Thresholds:
    def whole(key: str, *, minimum: int = 1) -> int:
        value = raw.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
            raise WeightProfileError(f"Threshold '{key}' must be a whole number >= {minimum}.")
        return value

    def factor(key: str, *, minimum: float, maximum: float) -> float:
        value = raw.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not (
            minimum <= value <= maximum
        ):
            raise WeightProfileError(
                f"Threshold '{key}' must be a number from {minimum} to {maximum}."
            )
        return float(value)

    sensitivities = raw.get("rain_sensitivity_factors")
    if not isinstance(sensitivities, dict) or set(sensitivities) != set(SENSITIVITIES):
        raise WeightProfileError(
            f"'rain_sensitivity_factors' needs exactly: {', '.join(SENSITIVITIES)}."
        )
    for key, value in sensitivities.items():
        if not isinstance(value, (int, float)) or not 0 <= value <= 1:
            raise WeightProfileError(f"Rain sensitivity '{key}' must be from 0 to 1.")

    thresholds = Thresholds(
        day_trip_max_travel_minutes=whole("day_trip_max_travel_minutes"),
        multi_day_max_travel_minutes=whole("multi_day_max_travel_minutes"),
        large_group_size=whole("large_group_size", minimum=2),
        young_child_max_age=whole("young_child_max_age", minimum=0),
        rain_low_below_percent=whole("rain_low_below_percent", minimum=0),
        rain_high_from_percent=whole("rain_high_from_percent", minimum=1),
        rain_sensitivity_factors={key: float(value) for key, value in sensitivities.items()},
        relax_travel_factor=factor("relax_travel_factor", minimum=1.0, maximum=3.0),
        relax_budget_factor=factor("relax_budget_factor", minimum=1.0, maximum=3.0),
        priority_blend=factor("priority_blend", minimum=0.0, maximum=1.0),
        max_priorities=whole("max_priorities"),
    )
    if thresholds.rain_low_below_percent >= thresholds.rain_high_from_percent:
        raise WeightProfileError("'rain_low_below_percent' must be below 'rain_high_from_percent'.")
    return thresholds


@lru_cache(maxsize=1)
def load_config() -> WeightConfig:
    return parse(json.loads(DATA_PATH.read_text(encoding="utf-8")))


def get_profile(name: str) -> WeightProfile:
    config = load_config()
    if name not in config.profiles:
        raise WeightProfileError(f"There is no weight profile named '{name}'.")
    return config.profiles[name]
