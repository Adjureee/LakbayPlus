"""POST /recommendations/top-places with the Nature attractions profile."""

from datetime import timedelta
from types import SimpleNamespace

import pytest

from app.features.ai.schemas import AIPlaceQuery
from app.features.recommendations.service import RecommendationService
from app.integrations.osrm.client import get_osrm_client
from tests.test_phase2_destination_data import admin_headers, user_headers
from tests.test_phase5_ai_itineraries import create_destination
from tests.test_top_places_scoring import NEAR_A, PATH, TableOSRM


@pytest.fixture
def osrm(client):
    fake = TableOSRM()
    client.app.dependency_overrides[get_osrm_client] = lambda: fake
    return fake


def place(client, admin, name: str, category: str, **overrides) -> dict:
    return create_destination(
        client, headers=admin, name=name, category=category,
        vibes=overrides.pop("vibes", "relaxed"), activities=overrides.pop("activities", "sightseeing"),
        **overrides,
    )


def rank(client, **body):
    # Register the traveler once per test: the same email cannot sign up twice.
    if not hasattr(client, "_traveler"):
        client._traveler = user_headers(client)
    response = client.post(PATH, headers=client._traveler, json={"origin": NEAR_A, **body})
    assert response.status_code == 201, response.text
    return response.json()


def by_name(body) -> dict:
    return {item["name"]: item for item in body["items"]}


def factor(item, criterion) -> dict:
    return next(f for f in item["factors"] if f["criterion"] == criterion)


def test_nature_group_returns_nature_places_and_skips_the_rest(client, osrm) -> None:
    admin = admin_headers(client)
    for name, category in [
        ("Falls", "Waterfall"), ("Peak", "Mountain"), ("Springs", "Hot Spring"),
        ("Plaza", "City Park"), ("Sandy", "Beach"), ("Splash", "Water Park"),
    ]:
        place(client, admin, name, category)

    body = rank(client, preference_groups=["nature_attractions"])

    assert set(by_name(body)) == {"Falls", "Peak", "Springs"}
    assert body["skipped"]["no_interest_match"] == 3
    assert body["profile"] == "nature_attractions"
    assert body["weights"]["physical_suitability"] == 0.15
    for item in body["items"]:
        assert item["breakdown"] is None  # the five-factor breakdown is for the default profile
        assert len(item["factors"]) == 8
        assert sum(f["points"] for f in item["factors"]) == pytest.approx(item["score"], abs=0.02)
        assert item["matched_interests"][0] == "Nature attractions"
        assert item["match_tier"] == 1


def test_the_word_nature_selects_the_group_but_beach_and_nature_use_the_default_model(client, osrm) -> None:
    admin = admin_headers(client)
    place(client, admin, "Falls", "Waterfall")
    place(client, admin, "Sandy", "Beach")

    nature_only = rank(client, interests=["nature"])
    assert nature_only["profile"] == "nature_attractions"
    assert set(by_name(nature_only)) == {"Falls"}

    # Nature criteria such as trail difficulty mean little for a beach, so a
    # mixed request uses the default model.
    mixed = rank(client, interests=["nature", "beach"])
    assert mixed["profile"] == "default"
    assert set(by_name(mixed)) == {"Falls", "Sandy"}


def test_a_chosen_sub_type_ranks_above_other_nature(client, osrm) -> None:
    admin = admin_headers(client)
    place(client, admin, "Falls", "Waterfall")
    place(client, admin, "Peak", "Mountain")

    body = rank(client, preference_groups=["nature_attractions"], sub_preferences=["waterfalls"])

    items = by_name(body)
    assert factor(items["Falls"], "nature_fit")["value"] == 1.0
    assert factor(items["Peak"], "nature_fit")["value"] == 0.5
    assert [item["name"] for item in body["items"]] == ["Falls", "Peak"]
    assert "Waterfalls" in items["Falls"]["matched_interests"]


def test_a_family_with_a_young_child_is_offered_the_easy_trail_first(client, osrm) -> None:
    admin = admin_headers(client)
    place(client, admin, "Easy Falls", "Waterfall", difficulty_level="Easy", is_kid_friendly=True)
    place(client, admin, "Hard Peak", "Mountain", difficulty_level="hard", is_kid_friendly=False)
    place(client, admin, "Unlisted Falls", "Waterfall", difficulty_level=None, is_kid_friendly=True)

    body = rank(
        client, preference_groups=["nature_attractions"], activity_level="easy",
        child_ages=[4], adult_count=2,
    )

    items = by_name(body)
    assert [item["name"] for item in body["items"]][0] == "Easy Falls"
    assert items["Hard Peak"]["rank"] > items["Easy Falls"]["rank"]
    assert factor(items["Easy Falls"], "physical_suitability")["value"] == 1.0
    assert factor(items["Hard Peak"], "physical_suitability")["value"] == 0.0
    assert "Harder than the easy pace you chose." in items["Hard Peak"]["reasons"]
    # No difficulty in the catalog: neutral, and the card says it is not listed.
    unlisted = factor(items["Unlisted Falls"], "physical_suitability")
    assert unlisted["value"] == 0.5 and unlisted["used_default"] is True
    assert "Trail difficulty not listed." in items["Unlisted Falls"]["reasons"]


def test_without_an_activity_level_physical_suitability_is_neutral(client, osrm) -> None:
    place(client, admin_headers(client), "Falls", "Waterfall", difficulty_level="hard")
    item = rank(client, preference_groups=["nature_attractions"])["items"][0]
    assert factor(item, "physical_suitability") == {
        "criterion": "physical_suitability", "label": "Physical suitability",
        "value": 0.5, "weight": 0.15, "points": 7.5, "used_default": True,
    }


def test_a_missing_popularity_record_is_neutral_not_zero(client, osrm) -> None:
    place(client, admin_headers(client), "Falls", "Waterfall")
    item = rank(client, preference_groups=["nature_attractions"])["items"][0]
    quiet = factor(item, "quiet_popular")
    assert quiet["value"] == 0.5 and quiet["used_default"] is True


def test_priorities_change_the_weights_and_still_sum_to_one(client, osrm) -> None:
    place(client, admin_headers(client), "Falls", "Waterfall")
    plain = rank(client, preference_groups=["nature_attractions"])
    prioritised = rank(
        client, preference_groups=["nature_attractions"], priority_order=["easy_trail", "good_weather"],
    )
    assert sum(prioritised["weights"].values()) == pytest.approx(1.0, abs=1e-3)
    assert prioritised["weights"]["physical_suitability"] > plain["weights"]["physical_suitability"]
    assert prioritised["weights"]["nature_fit"] < plain["weights"]["nature_fit"]


# Weather -----------------------------------------------------------------------------------------

def today():
    from app.features.recommendations.service import _today

    return _today()


def fake_forecast(monkeypatch, rain_percent: int, *, fail: bool = False):
    calls = []

    async def provider(self, lat, lng, days):
        calls.append((lat, lng, days))
        if fail:
            raise RuntimeError("weather provider is down")
        start = today()
        return SimpleNamespace(days=[
            SimpleNamespace(date=start + timedelta(days=offset), rain_chance_percent=rain_percent)
            for offset in range(days)
        ])

    monkeypatch.setattr(RecommendationService, "_default_forecast", provider)
    return calls


def test_rain_hurts_a_waterfall_more_than_a_hot_spring(client, osrm, monkeypatch) -> None:
    calls = fake_forecast(monkeypatch, rain_percent=85)
    admin = admin_headers(client)
    place(client, admin, "Falls", "Waterfall")
    place(client, admin, "Springs", "Hot Spring")

    body = rank(client, preference_groups=["nature_attractions"], travel_start_date=str(today()), day_count=1)

    items = by_name(body)
    assert factor(items["Falls"], "weather_season")["value"] == 0.0
    assert factor(items["Springs"], "weather_season")["value"] == pytest.approx(0.75)
    assert factor(items["Falls"], "weather_season")["used_default"] is False
    assert "Rain is likely on your dates (85%); wet trails and falls can be unsafe." in items["Falls"]["reasons"]
    assert items["Springs"]["rank"] < items["Falls"]["rank"]
    assert len(calls) == 1  # both places sit in one forecast cell


def test_without_a_date_weather_is_neutral_and_says_so(client, osrm, monkeypatch) -> None:
    calls = fake_forecast(monkeypatch, rain_percent=85)
    place(client, admin_headers(client), "Falls", "Waterfall")

    body = rank(client, preference_groups=["nature_attractions"])

    item = body["items"][0]
    assert factor(item, "weather_season")["value"] == 0.5
    assert factor(item, "weather_season")["used_default"] is True
    assert "No travel date was set, so weather is not scored." in body["warnings"]
    assert calls == []  # nothing is fetched without a date


def test_dates_beyond_the_forecast_window_are_neutral(client, osrm, monkeypatch) -> None:
    calls = fake_forecast(monkeypatch, rain_percent=85)
    place(client, admin_headers(client), "Falls", "Waterfall")

    body = rank(
        client, preference_groups=["nature_attractions"],
        travel_start_date=str(today() + timedelta(days=30)),
    )

    assert any("beyond the 5-day weather forecast" in w for w in body["warnings"])
    assert factor(body["items"][0], "weather_season")["used_default"] is True
    assert calls == []


def test_a_weather_outage_does_not_break_the_recommendations(client, osrm, monkeypatch) -> None:
    fake_forecast(monkeypatch, rain_percent=0, fail=True)
    place(client, admin_headers(client), "Falls", "Waterfall")

    body = rank(client, preference_groups=["nature_attractions"], travel_start_date=str(today()))

    assert [item["name"] for item in body["items"]] == ["Falls"]
    assert "The weather forecast is unavailable right now, so weather is not scored." in body["warnings"]


# Filling the list ------------------------------------------------------------------------------------

def test_fill_to_limit_adds_labelled_near_matches_after_the_exact_ones(client) -> None:
    fake = TableOSRM(minutes_by_lat={7.2: 240, 7.3: 400})
    client.app.dependency_overrides[get_osrm_client] = lambda: fake
    admin = admin_headers(client)
    cheap = {"estimated_cost": "500.00"}  # 1000 pesos per person is the budget
    place(client, admin, "Exact One", "Waterfall", lat=7.105, **cheap)
    place(client, admin, "Exact Two", "Mountain", lat=7.106, **cheap)
    place(client, admin, "Slightly Pricey", "Hot Spring", lat=7.107, estimated_cost="1200.00")
    place(client, admin, "Far Falls", "Waterfall", lat=7.2, **cheap)
    place(client, admin, "Too Far", "Waterfall", lat=7.3, **cheap)
    place(client, admin, "Way Too Pricey", "Waterfall", lat=7.108, estimated_cost="5000.00")
    request = {
        "preference_groups": ["nature_attractions"], "total_budget": "3000.00",
        "adult_count": 3, "day_count": 1,
    }

    strict = rank(client, **request)
    assert {item["name"] for item in strict["items"]} == {"Exact One", "Exact Two"}
    assert strict["relaxed_count"] == 0

    filled = rank(client, **request, fill_to_limit=True)
    names = [item["name"] for item in filled["items"]]
    assert names[:2] == ["Exact One", "Exact Two"] or set(names[:2]) == {"Exact One", "Exact Two"}
    assert set(names) == {"Exact One", "Exact Two", "Slightly Pricey", "Far Falls"}
    assert "Too Far" not in names and "Way Too Pricey" not in names  # beyond even the relaxed limits
    items = by_name(filled)
    assert items["Exact One"]["match_tier"] == 1 and items["Exact One"]["relaxations"] == []
    assert items["Slightly Pricey"]["match_tier"] == 2
    assert items["Slightly Pricey"]["relaxations"] == ["About ₱200 over your per-person budget."]
    assert items["Far Falls"]["match_tier"] == 2
    assert items["Far Falls"]["relaxations"] == ["4 h away, beyond your usual 3 h limit."]
    assert items["Far Falls"]["reasons"][0] == items["Far Falls"]["relaxations"][0]
    assert filled["relaxed_count"] == 2
    assert any("relax a limit you set" in w for w in filled["warnings"])
    # Exact matches always come before relaxed ones, whatever their score.
    assert [item["match_tier"] for item in filled["items"]] == sorted(
        item["match_tier"] for item in filled["items"]
    )


def test_the_list_never_exceeds_five(client, osrm) -> None:
    admin = admin_headers(client)
    for index in range(8):
        place(client, admin, f"Falls {index}", "Waterfall", lat=7.1 + index / 1000)
    body = rank(client, preference_groups=["nature_attractions"], fill_to_limit=True)
    assert len(body["items"]) == 5
    assert [item["rank"] for item in body["items"]] == [1, 2, 3, 4, 5]


def test_a_request_for_more_than_five_is_refused_and_the_ai_clamps_it(client, osrm) -> None:
    response = client.post(PATH, headers=user_headers(client), json={"limit": 6})
    assert response.status_code == 422
    assert [AIPlaceQuery(limit=value).limit for value in (8, 10, 3, 0, "7", "x")] == [5, 5, 3, 1, 5, 5]


@pytest.mark.parametrize(
    "body",
    [
        {"preference_groups": ["made_up_group"]},
        {"sub_preferences": ["made_up_kind"]},
        {"sub_preferences": ["beach"]},  # names a group, not a sub-type
        {"priority_order": ["money"]},
        {"priority_order": ["scenery", "scenery"]},
        {"activity_level": "extreme"},
    ],
)
def test_invalid_preferences_are_refused(client, osrm, body) -> None:
    response = client.post(PATH, headers=user_headers(client), json=body)
    assert response.status_code == 422


# Facets -------------------------------------------------------------------------------------------------

def test_facets_list_the_groups_with_live_counts_without_signing_in(client) -> None:
    admin = admin_headers(client)
    for name, category in [
        ("Falls", "Waterfall"), ("Peak", "Mountain"), ("Springs", "Hot Spring"),
        ("Sandy", "Beach"), ("Plaza", "City Park"), ("Museum One", "Museum"),
    ]:
        place(client, admin, name, category)

    response = client.get("/api/v1/destinations/facets")

    assert response.status_code == 200
    body = response.json()
    assert body["total_places"] == 6
    groups = {group["key"]: group for group in body["groups"]}
    nature = groups["nature_attractions"]
    assert nature["label"] == "Nature attractions"
    assert nature["count"] == 3
    assert {sub["key"]: sub["count"] for sub in nature["subtypes"]} == {
        "waterfalls": 1, "mountains_viewpoints": 1, "parks_wildlife": 0,
        "springs_lakes": 1, "islands": 0, "gardens_farms": 0,
    }
    assert groups["beaches"]["count"] == 1
    assert groups["culture_heritage"]["count"] == 1
    assert groups["beaches"]["subtypes"] == []
