"""Nature attractions: preference groups, weight profiles and the SAW criteria."""

import copy
import json

import pytest

from app.features.recommendations import preference_groups as pg
from app.features.recommendations import scoring
from app.features.recommendations import weight_profiles as wp
from app.features.recommendations.preference_groups import load_groups
from app.features.recommendations.weight_profiles import get_profile, load_config


# Weight profiles ---------------------------------------------------------------

def test_the_shipped_profiles_are_valid_and_sum_to_one() -> None:
    config = load_config()
    assert set(config.profiles) >= {"default", "nature_attractions"}
    for profile in config.profiles.values():
        assert sum(profile.weights.values()) == pytest.approx(1.0)
    # The default profile is still the approved Top 5 model.
    assert config.default.weights == {
        "interest": 0.35, "travel": 0.25, "budget": 0.20, "group_fit": 0.10, "popularity": 0.10,
    }
    assert get_profile("nature_attractions").weights == {
        "nature_fit": 0.25, "travel": 0.20, "budget": 0.15, "physical_suitability": 0.15,
        "weather_season": 0.10, "access": 0.05, "group_fit": 0.05, "quiet_popular": 0.05,
    }


def _raw() -> dict:
    return json.loads(wp.DATA_PATH.read_text(encoding="utf-8"))


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda r: r["profiles"]["nature_attractions"]["weights"].update(access=0.5), "add up to"),
        (lambda r: r["profiles"]["nature_attractions"]["weights"].update(mystery=0.0), "unknown criteria"),
        (lambda r: r["profiles"]["default"]["weights"].update(interest=-0.1), "positive"),
        (lambda r: r["profiles"].pop("default"), "'default'"),
        (lambda r: r["thresholds"].update(rain_low_below_percent=90), "below"),
        (lambda r: r["profiles"]["nature_attractions"]["priority_criteria"].update(scenery="popularity"),
         "not one of its criteria"),
        (lambda r: r["thresholds"].pop("priority_blend"), "priority_blend"),
    ],
)
def test_an_invalid_weight_file_is_refused(mutate, message) -> None:
    raw = copy.deepcopy(_raw())
    mutate(raw)
    with pytest.raises(wp.WeightProfileError, match=message):
        wp.parse(raw)


# Preference groups -----------------------------------------------------------------

@pytest.mark.parametrize(
    ("category", "subtype"),
    [
        ("Waterfall", "waterfalls"),
        ("Mountain Resort", "mountains_viewpoints"),
        ("Mountain", "mountains_viewpoints"),
        ("Sea Of Clouds Viewpoint", "mountains_viewpoints"),
        ("Scenic Cape", "mountains_viewpoints"),
        ("Nature Park", "parks_wildlife"),
        ("Nature Reserve", "parks_wildlife"),
        ("Nature Resort", "parks_wildlife"),
        ("Wildlife", "parks_wildlife"),
        ("Hot Spring", "springs_lakes"),
        ("Island", "islands"),
        ("Flower Farm", "gardens_farms"),
        ("Farm", "gardens_farms"),
    ],
)
def test_nature_attractions_covers_the_nature_categories(category, subtype) -> None:
    membership = load_groups().membership("nature_attractions", category)
    assert membership is not None
    assert subtype in membership.subtypes


@pytest.mark.parametrize(
    "category",
    ["Park", "City Park", "Water Park", "Beach", "Beach Resort", "Museum", "Church", "Resort", None, ""],
)
def test_nature_attractions_does_not_pull_in_other_places(category) -> None:
    assert load_groups().membership("nature_attractions", category) is None


def test_a_lake_park_belongs_to_two_nature_subtypes() -> None:
    membership = load_groups().membership("nature_attractions", "Lake Park")
    assert membership.subtypes == {"parks_wildlife", "springs_lakes"}


def test_place_overrides_include_and_exclude() -> None:
    raw = json.loads(pg.DATA_PATH.read_text(encoding="utf-8"))
    nature = raw["groups"]["nature_attractions"]
    nature["include_destination_ids"] = [7]
    nature["exclude_destination_ids"] = [8]
    groups = pg.parse(raw, profile_names=load_config().profiles)
    # Included by id even though "Resort" is not a nature category.
    included = groups.membership("nature_attractions", "Resort", 7)
    assert included is not None and included.subtypes == frozenset()
    # Excluded by id even though a waterfall is nature.
    assert groups.membership("nature_attractions", "Waterfall", 8) is None
    assert groups.membership("nature_attractions", "Waterfall", 9) is not None


def test_words_travelers_use_resolve_to_the_group_or_sub_type() -> None:
    groups = load_groups()
    for word in ("nature", "Nature attractions", "outdoors", "scenic"):
        assert groups.resolve(word).group == "nature_attractions"
        assert groups.resolve(word).subtype is None
    assert groups.resolve("waterfalls").subtype == "waterfalls"
    assert groups.resolve("hiking").subtype == "mountains_viewpoints"
    assert groups.resolve("beach").group == "beaches"
    assert groups.resolve("coffee") is None


def test_a_word_cannot_name_two_groups() -> None:
    raw = json.loads(pg.DATA_PATH.read_text(encoding="utf-8"))
    raw["groups"]["beaches"]["aliases"].append("nature")
    with pytest.raises(pg.PreferenceGroupError, match="nature"):
        pg.parse(raw, profile_names=load_config().profiles)


def test_an_unknown_weight_profile_is_refused() -> None:
    raw = json.loads(pg.DATA_PATH.read_text(encoding="utf-8"))
    raw["groups"]["beaches"]["weight_profile"] = "made_up"
    with pytest.raises(pg.PreferenceGroupError, match="made_up"):
        pg.parse(raw, profile_names=load_config().profiles)


# Normalizers and criteria -------------------------------------------------------------

@pytest.mark.parametrize(
    ("text", "level"),
    [
        ("easy", 0), ("Easy", 0), ("Moderate", 1), ("Moderate (steep final section)", 1),
        ("medium", 1), ("hard", 2), ("Strenuous climb", 2), ("easy to moderate", 1),
        ("moderate to hard", 2), (None, None), ("", None), ("true", None),
    ],
)
def test_difficulty_is_read_from_messy_catalog_text(text, level) -> None:
    assert scoring.normalize_difficulty(text) == level


@pytest.mark.parametrize(
    ("text", "crowd"),
    [("low", "low"), ("Moderate (Peak during weekend evenings)", "moderate"),
     ("High", "high"), ("quiet", "low"), (None, None), ("unknown", None)],
)
def test_crowd_is_read_from_messy_catalog_text(text, crowd) -> None:
    assert scoring.normalize_crowd(text) == crowd


def test_physical_suitability_rewards_easier_and_punishes_harder() -> None:
    easy, moderate, hard = 0, 1, 2
    f = scoring.physical_suitability_score
    assert f(place_level=easy, wanted_level=moderate, lower_one_step=False) == 1.0
    assert f(place_level=moderate, wanted_level=moderate, lower_one_step=False) == 1.0
    assert f(place_level=hard, wanted_level=moderate, lower_one_step=False) == 0.5
    assert f(place_level=hard, wanted_level=easy, lower_one_step=False) == 0.0
    # A young child or elderly traveler is offered one level easier.
    assert f(place_level=moderate, wanted_level=moderate, lower_one_step=True) == 0.5
    assert f(place_level=easy, wanted_level=moderate, lower_one_step=True) == 1.0
    # Unknown on either side is neutral, never a guess in either direction.
    assert f(place_level=None, wanted_level=moderate, lower_one_step=False) == scoring.NEUTRAL
    assert f(place_level=hard, wanted_level=None, lower_one_step=False) == scoring.NEUTRAL


def test_weather_score_counts_dry_days_and_softens_for_rain_tolerant_places() -> None:
    dry, mixed, wet = [10, 20], [10, 50], [80, 90]
    assert scoring.weather_score(dry, sensitivity="high") == 1.0
    assert scoring.weather_score(wet, sensitivity="high") == 0.0
    assert scoring.weather_score(mixed, sensitivity="high") == pytest.approx(0.75)
    # The same wet forecast hurts a hot spring far less than a waterfall.
    assert scoring.weather_score(wet, sensitivity="low") == pytest.approx(0.75)
    assert scoring.weather_score(wet, sensitivity="medium") == pytest.approx(0.4)
    assert scoring.weather_score(wet, sensitivity="low") > scoring.weather_score(wet, sensitivity="medium")
    assert scoring.weather_score(wet, sensitivity="medium") > scoring.weather_score(wet, sensitivity="high")
    assert scoring.weather_score([], sensitivity="high") is None  # no forecast: caller stays neutral


def test_cut_off_percentages_come_from_the_profile_file() -> None:
    t = scoring.THRESHOLDS
    assert scoring.weather_score([t.rain_low_below_percent - 1], sensitivity="high") == 1.0
    assert scoring.weather_score([t.rain_low_below_percent], sensitivity="high") == 0.5
    assert scoring.weather_score([t.rain_high_from_percent], sensitivity="high") == 0.0


def test_access_score_orders_verified_trail_approximate() -> None:
    f = scoring.access_score
    assert f(verified=True, has_access_trail=False, basis="road_route") == 1.0
    assert f(verified=False, has_access_trail=True, basis="approximate_location") == 0.8
    assert f(verified=False, has_access_trail=False, basis="approximate_location") == 0.4
    assert f(verified=False, has_access_trail=False, basis="unknown") == scoring.NEUTRAL


def test_quiet_or_popular_and_the_missing_popularity_fix() -> None:
    f = scoring.quiet_popular_score
    assert f(prefers_quiet=True, crowd="low", popularity=90) == 1.0
    assert f(prefers_quiet=True, crowd="high", popularity=90) == 0.0
    assert f(prefers_quiet=True, crowd=None, popularity=90) == scoring.NEUTRAL
    assert f(prefers_quiet=False, crowd="high", popularity=80) == pytest.approx(0.8)
    # No visit history is neutral, not 0: new places are not pushed down.
    assert f(prefers_quiet=False, crowd=None, popularity=None) == scoring.NEUTRAL
    assert f(prefers_quiet=False, crowd=None, popularity=0) == scoring.NEUTRAL


def test_nature_fit_prefers_the_chosen_sub_type() -> None:
    f = scoring.nature_fit_score
    waterfall, mountain = frozenset({"waterfalls"}), frozenset({"mountains_viewpoints"})
    assert f(waterfall, frozenset()) == 1.0  # no sub-chip chosen: all nature counts
    assert f(waterfall, frozenset({"waterfalls"})) == 1.0
    assert f(mountain, frozenset({"waterfalls"})) == 0.5
    assert f(frozenset(), frozenset({"waterfalls"})) == 0.5


# The worked example in docs/AI_CHAT_ITINERARY_PLAN.md ---------------------------------------------

NATURE = get_profile("nature_attractions").weights


@pytest.mark.parametrize(
    ("values", "expected"),
    [
        # A: easy waterfall, 60 min, 200 pesos per person
        ({"nature_fit": 1.0, "travel": 1 - 60 / 180, "budget": 1.0, "physical_suitability": 1.0,
          "weather_season": 0.8, "access": 1.0, "group_fit": 1.0, "quiet_popular": 0.6}, 89.33),
        # C: nature resort, 20 min, 700 pesos per person
        ({"nature_fit": 0.5, "travel": 1 - 20 / 180, "budget": 0.6, "physical_suitability": 1.0,
          "weather_season": 0.8, "access": 1.0, "group_fit": 1.0, "quiet_popular": 0.9}, 76.78),
        # B: hard mountain trail, 100 min, not kid-friendly, for a family with a young child
        ({"nature_fit": 1.0, "travel": 1 - 100 / 180, "budget": 1.0, "physical_suitability": 0.0,
          "weather_season": 0.5, "access": 0.5, "group_fit": 0.0, "quiet_popular": 0.3}, 57.89),
    ],
)
def test_worked_example_is_reproduced_exactly(values, expected) -> None:
    points = scoring.weighted_points(values, NATURE)
    assert scoring.total_score(points) == pytest.approx(expected, abs=0.005)
    assert scoring.total_score(points) == pytest.approx(sum(points.values()))


def test_the_hard_trail_ranks_last_for_a_family_with_a_young_child() -> None:
    physical = scoring.physical_suitability_score
    hard_for_family = physical(place_level=2, wanted_level=0, lower_one_step=True)
    easy_for_family = physical(place_level=0, wanted_level=0, lower_one_step=True)
    assert easy_for_family > hard_for_family


# Traveler priorities -------------------------------------------------------------------------

def test_rank_order_centroid_weights() -> None:
    assert scoring.roc_weights(1) == [1.0]
    assert scoring.roc_weights(3) == pytest.approx([0.6111, 0.2778, 0.1111], abs=1e-4)
    for count in (1, 2, 3):
        assert sum(scoring.roc_weights(count)) == pytest.approx(1.0)


def test_priorities_blend_into_the_profile_and_still_sum_to_one() -> None:
    profile = get_profile("nature_attractions")
    blended = scoring.blend_priority_weights(
        profile.weights, ["easy_trail", "good_weather", "quiet"], profile.priority_criteria,
    )
    assert sum(blended.values()) == pytest.approx(1.0)
    assert blended["physical_suitability"] == pytest.approx(0.7 * 0.15 + 0.3 * 0.6111, abs=1e-4)
    assert blended["weather_season"] == pytest.approx(0.7 * 0.10 + 0.3 * 0.2778, abs=1e-4)
    assert blended["quiet_popular"] == pytest.approx(0.7 * 0.05 + 0.3 * 0.1111, abs=1e-4)
    # A criterion the traveler did not rank only shrinks a little.
    assert blended["nature_fit"] == pytest.approx(0.7 * 0.25)
    # Ranking nothing, or something unknown, changes nothing.
    assert scoring.blend_priority_weights(profile.weights, [], profile.priority_criteria) == profile.weights
    assert scoring.blend_priority_weights(profile.weights, ["money"], profile.priority_criteria) == profile.weights


# Properties of the model -----------------------------------------------------------------------------

BASE = {"nature_fit": 1.0, "travel": 0.5, "budget": 0.5, "physical_suitability": 0.5,
        "weather_season": 0.5, "access": 0.5, "group_fit": 1.0, "quiet_popular": 0.5}


def _score(**changes) -> float:
    return scoring.total_score(scoring.weighted_points({**BASE, **changes}, NATURE))


def test_a_cheaper_closer_better_place_never_scores_lower() -> None:
    for criterion in NATURE:
        assert _score(**{criterion: 0.9}) >= _score(**{criterion: 0.4})


def test_a_neutral_missing_value_never_beats_a_known_good_one() -> None:
    for criterion in ("physical_suitability", "weather_season", "quiet_popular", "budget", "travel"):
        assert _score(**{criterion: 1.0}) > _score(**{criterion: scoring.NEUTRAL})


def test_ranking_is_stable_when_each_weight_changes_by_twenty_percent() -> None:
    """Moving any weight by 20% (renormalized) must not change which place wins."""
    places = {
        "A": {**BASE, "nature_fit": 1.0, "travel": 0.67, "budget": 1.0, "physical_suitability": 1.0,
              "weather_season": 0.8, "access": 1.0, "quiet_popular": 0.6},
        "C": {**BASE, "nature_fit": 0.5, "travel": 0.89, "budget": 0.6, "physical_suitability": 1.0,
              "weather_season": 0.8, "access": 1.0, "quiet_popular": 0.9},
        "B": {**BASE, "nature_fit": 1.0, "travel": 0.44, "budget": 1.0, "physical_suitability": 0.0,
              "weather_season": 0.5, "access": 0.5, "group_fit": 0.0, "quiet_popular": 0.3},
    }

    def order(weights: dict[str, float]) -> list[str]:
        scores = {
            name: scoring.total_score(scoring.weighted_points(values, weights))
            for name, values in places.items()
        }
        return sorted(scores, key=scores.__getitem__, reverse=True)

    baseline = order(NATURE)
    assert baseline == ["A", "C", "B"]
    for criterion in NATURE:
        for factor in (0.8, 1.2):
            changed = {**NATURE, criterion: NATURE[criterion] * factor}
            total = sum(changed.values())
            assert order({k: v / total for k, v in changed.items()})[0] == baseline[0]
