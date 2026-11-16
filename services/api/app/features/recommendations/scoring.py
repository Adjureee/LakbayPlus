"""Weighted scoring model (Simple Additive Weighting) for the personalized Top 5.

Every factor is normalized to 0-1, multiplied by its weight, and added. The
functions here are pure so the formula can be tested and checked by hand.
"""

from decimal import Decimal
import math
import re

from app.features.recommendations.weight_profiles import Thresholds, load_config

# Weights and thresholds are data: see data/weight_profiles.json. The default
# profile is the approved Top 5 model (interest, travel and budget match the
# Phase 15B group weights in `geo_analytics/service.py`; group fit combines
# child and group needs). Other profiles, such as nature attractions, add
# criteria below.
_CONFIG = load_config()
WEIGHTS: dict[str, float] = dict(_CONFIG.default.weights)
THRESHOLDS: Thresholds = _CONFIG.thresholds
# Used when the traveler gave no value to compare against, so the factor
# neither helps nor hurts any place.
NEUTRAL = 0.5
DAY_TRIP_MAX_TRAVEL_MINUTES = THRESHOLDS.day_trip_max_travel_minutes
MULTI_DAY_MAX_TRAVEL_MINUTES = THRESHOLDS.multi_day_max_travel_minutes
LARGE_GROUP_SIZE = THRESHOLDS.large_group_size
# Interest fields searched for each traveler interest, in reporting order.
INTEREST_FIELDS = ("category", "vibes", "activities")


def max_travel_minutes(day_count: int | None) -> int:
    """One-way travel limit: tighter for a day trip than for a longer stay."""
    return MULTI_DAY_MAX_TRAVEL_MINUTES if day_count and day_count >= 2 else DAY_TRIP_MAX_TRAVEL_MINUTES


def interest_matches(
    interests: list[str], fields: dict[str, str | None]
) -> tuple[list[str], list[str]]:
    """Return the interests found in the place's text and the fields that matched."""
    matched: list[str] = []
    matched_fields: list[str] = []
    for interest in interests:
        wanted = interest.strip().lower()
        if not wanted:
            continue
        hits = [name for name in INTEREST_FIELDS if wanted in (fields.get(name) or "").lower()]
        if hits:
            matched.append(interest)
            matched_fields.extend(name for name in hits if name not in matched_fields)
    return matched, matched_fields


def interest_score(selected_count: int, matched_count: int) -> float:
    """Benefit: share of the traveler's interests the place matches."""
    if selected_count <= 0:
        return NEUTRAL
    return min(1.0, matched_count / selected_count)


def travel_score(minutes: float | None, max_minutes: int) -> float:
    """Cost: shorter travel scores higher, reaching 0 at the trip's limit."""
    if minutes is None:
        return NEUTRAL
    return max(0.0, min(1.0, 1 - minutes / max_minutes))


def budget_score(cost_per_person: Decimal | None, budget_per_person: Decimal | None) -> float:
    """Cost: full marks up to half the budget, then down to 0 at the full budget.

    The flat first half keeps the cheapest place from always winning when every
    option fits comfortably.
    """
    if cost_per_person is None or budget_per_person is None or budget_per_person <= 0:
        return NEUTRAL
    ratio = float(cost_per_person / budget_per_person)
    if ratio <= 0.5:
        return 1.0
    return max(0.0, (1 - ratio) / 0.5)


def group_fit_score(
    *,
    has_children: bool,
    traveler_count: int,
    is_kid_friendly: bool,
    group_friendly: bool,
) -> float:
    """Benefit: needs met divided by needs. A party with no needs scores 1."""
    needs: list[bool] = []
    if has_children:
        needs.append(bool(is_kid_friendly))
    if traveler_count >= LARGE_GROUP_SIZE:
        needs.append(bool(group_friendly))
    if not needs:
        return 1.0
    return sum(needs) / len(needs)


def popularity_score(score: Decimal | float | None) -> float:
    """Benefit: the stored popularity score on the same 0-100 scale as Phase 15B."""
    if score is None or score <= 0:
        return 0.0
    return min(100.0, float(score)) / 100


def weighted_points(
    values: dict[str, float], weights: dict[str, float] | None = None
) -> dict[str, float]:
    """Each factor's contribution to the 0-100 score, rounded to two decimals."""
    weights = WEIGHTS if weights is None else weights
    return {name: round(100 * weights[name] * values[name], 2) for name in weights}


def total_score(points: dict[str, float]) -> float:
    """The 0-100 score: the sum of the rounded points, so the breakdown always adds up."""
    return round(sum(points.values()), 2)


def topsis_scores(
    items_values: list[dict[str, float]],
    weights: dict[str, float] | None = None,
) -> list[float]:
    """Rank alternatives on a 0-100 scale using TOPSIS closeness to the ideal."""
    if not items_values:
        return []
    weight_map = weights or WEIGHTS
    criteria = list(weight_map.keys())
    if len(items_values) == 1:
        item = items_values[0]
        return [round(100.0 * sum(weight_map[key] * item.get(key, 0.0) for key in criteria), 2)]

    norms = {
        key: math.sqrt(sum((item.get(key, 0.0) ** 2) for item in items_values))
        for key in criteria
    }
    weighted_matrix: list[dict[str, float]] = [
        {
            key: (weight_map[key] * (item.get(key, 0.0) / norms[key])) if norms[key] > 0 else 0.0
            for key in criteria
        }
        for item in items_values
    ]
    ideal_best = {
        key: max(row[key] for row in weighted_matrix)
        for key in criteria
    }
    ideal_worst = {
        key: min(row[key] for row in weighted_matrix)
        for key in criteria
    }

    scores: list[float] = []
    for item, row in zip(items_values, weighted_matrix, strict=True):
        dist_best = math.sqrt(sum((row[key] - ideal_best[key]) ** 2 for key in criteria))
        dist_worst = math.sqrt(sum((row[key] - ideal_worst[key]) ** 2 for key in criteria))
        denom = dist_best + dist_worst
        if denom == 0:
            scores.append(
                round(100.0 * sum(weight_map[key] * item.get(key, 0.0) for key in criteria), 2)
            )
        else:
            scores.append(round(100.0 * (dist_worst / denom), 2))
    return scores


# Nature attraction criteria -------------------------------------------------

ACTIVITY_LEVELS = {"easy": 0, "moderate": 1, "challenging": 2}
_DIFFICULTY_WORDS = {
    "easy": 0, "moderate": 1, "medium": 1,
    "hard": 2, "difficult": 2, "challenging": 2, "strenuous": 2,
}
_CROWD_WORDS = {
    "low": "low", "quiet": "low",
    "moderate": "moderate", "medium": "moderate",
    "high": "high", "busy": "high", "crowded": "high",
}
_CROWD_ORDER = {"low": 0, "moderate": 1, "high": 2}


def normalize_difficulty(text: str | None) -> int | None:
    """0 easy, 1 moderate, 2 hard from messy catalog text; None if unreadable.

    "Easy" and "easy" are the same; free text such as "Moderate (steep
    section)" is read by its words. When several levels appear, the hardest wins
    so a trail is never described as easier than the catalog says.
    """
    found = [
        level for word, level in _DIFFICULTY_WORDS.items()
        if re.search(rf"\b{word}\b", (text or "").lower())
    ]
    return max(found) if found else None


def normalize_crowd(text: str | None) -> str | None:
    """low, moderate or high from catalog text; the busiest word wins."""
    found = [
        level for word, level in _CROWD_WORDS.items()
        if re.search(rf"\b{word}\b", (text or "").lower())
    ]
    return max(found, key=_CROWD_ORDER.__getitem__) if found else None


def nature_fit_score(place_subtypes: frozenset[str], selected_subtypes: frozenset[str]) -> float:
    """Benefit: 1 for a sub-type the traveler chose (or when none was chosen),
    0.5 for nature of another kind."""
    if not selected_subtypes:
        return 1.0
    return 1.0 if place_subtypes & selected_subtypes else 0.5


def physical_suitability_score(
    *,
    place_level: int | None,
    wanted_level: int | None,
    lower_one_step: bool,
) -> float:
    """Benefit: an easier-than-wanted place scores 1; each step harder loses half.

    `lower_one_step` is true when the party includes a young child or an
    elderly traveler, who should be offered one level easier than they asked for.
    """
    if place_level is None or wanted_level is None:
        return NEUTRAL
    effective = max(0, wanted_level - 1) if lower_one_step else wanted_level
    gap = place_level - effective
    return 1.0 if gap <= 0 else max(0.0, 1.0 - 0.5 * gap)


def weather_score(
    rain_chances: list[int], *, sensitivity: str, thresholds: Thresholds = THRESHOLDS
) -> float | None:
    """Benefit: how dry the trip days look, softened for rain-tolerant places.

    Each day scores 1 below the low rain cut-off, 0 from the high cut-off, 0.5
    between. A place that rain barely affects (a hot spring) is pulled toward 1.
    Returns None when there is no forecast, so the caller can stay neutral and
    say so instead of assuming a season.
    """
    if not rain_chances:
        return None
    days = [
        1.0 if chance < thresholds.rain_low_below_percent
        else 0.0 if chance >= thresholds.rain_high_from_percent
        else 0.5
        for chance in rain_chances
    ]
    dryness = sum(days) / len(days)
    return 1 - (1 - dryness) * thresholds.rain_sensitivity_factors[sensitivity]


def access_score(*, verified: bool, has_access_trail: bool, basis: str) -> float:
    """Benefit: how surely a traveler can reach the entrance."""
    if verified:
        return 1.0
    if has_access_trail:
        return 0.8
    if basis == "approximate_location":
        return 0.4
    return NEUTRAL


def quiet_popular_score(
    *, prefers_quiet: bool, crowd: str | None, popularity: float | None
) -> float:
    """Benefit: a quiet place for a traveler who wants quiet, otherwise a popular one.

    A missing value is neutral (0.5). It is not 0, so places with no visit
    history yet are not pushed down.
    """
    if prefers_quiet:
        return NEUTRAL if crowd is None else {"low": 1.0, "moderate": 0.5, "high": 0.0}[crowd]
    if popularity is None or popularity <= 0:
        return NEUTRAL
    return min(100.0, float(popularity)) / 100


def roc_weights(count: int) -> list[float]:
    """Rank-order-centroid weights: 0.611, 0.278, 0.111 for three ranks."""
    return [sum(1 / j for j in range(rank, count + 1)) / count for rank in range(1, count + 1)]


def blend_priority_weights(
    profile_weights: dict[str, float],
    priority_order: list[str],
    priority_criteria: dict[str, str],
    *,
    share: float = THRESHOLDS.priority_blend,
) -> dict[str, float]:
    """Blend the traveler's ranked priorities into a profile: still sums to 1.

    `weight = (1 - share) x profile + share x priority weight`, where the
    priority weights are rank-order-centroid weights on the ranked criteria.
    """
    criteria = [
        priority_criteria[name] for name in priority_order
        if name in priority_criteria and priority_criteria[name] in profile_weights
    ]
    criteria = list(dict.fromkeys(criteria))
    if not criteria or share <= 0:
        return dict(profile_weights)
    ranked = dict(zip(criteria, roc_weights(len(criteria)), strict=True))
    return {
        name: (1 - share) * weight + share * ranked.get(name, 0.0)
        for name, weight in profile_weights.items()
    }


CRITERION_LABELS = {
    "interest": "Interest match",
    "travel": "Travel time",
    "budget": "Budget",
    "group_fit": "Group fit",
    "popularity": "Popularity",
    "nature_fit": "Nature fit",
    "physical_suitability": "Physical suitability",
    "weather_season": "Weather",
    "access": "Access",
    "quiet_popular": "Quiet or popular",
}
