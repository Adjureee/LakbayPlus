import json

import pytest

from app.features.recommendations.preference_groups import (
    load_groups,
    normalize_category,
)
from app.integrations.groq.client import get_groq_client
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)

LIVE_24_CATEGORIES = [
    "beach resort",
    "museum",
    "waterfall",
    "beach",
    "resort",
    "church",
    "mountain resort",
    "nature park",
    "nature reserve",
    "farm",
    "flower farm",
    "hot spring",
    "island",
    "lake park",
    "mountain",
    "nature resort",
    "religious landmark",
    "scenic cape",
    "sea of clouds viewpoint",
    "water park",
    "wildlife",
    "park",
    "city park",
    "Park / Public Plaza",
]


@pytest.mark.parametrize("raw_category", LIVE_24_CATEGORIES)
def test_all_24_live_categories_resolve_to_a_named_group(raw_category: str) -> None:
    groups = load_groups()
    resolved = groups.resolve_groups_for_category(raw_category)
    assert resolved
    assert resolved != ["other"], f"{raw_category!r} landed in Other unexpectedly"


def test_category_normalization_synonyms_and_fuzzy_fallback() -> None:
    groups = load_groups()
    assert normalize_category("  Beach Resort ") == "beach resort"
    assert normalize_category("Waterfalls") == "waterfall"
    assert normalize_category("talon") == "waterfall"
    assert normalize_category("busay") == "waterfall"
    assert normalize_category("museo") == "museum"
    assert normalize_category("Park / Public Plaza") == "public plaza"

    # Fuzzy shared-word fallback when not explicitly listed in preference_groups.json.
    assert "resorts_leisure" in groups.resolve_groups_for_category("Eco Staycation Lodge")
    # Unclaimed completely novel category goes cleanly into "other", never orphaned.
    assert groups.resolve_groups_for_category("Observatory Dome") == ["other"]


def test_brand_new_category_appears_in_facets_and_browse_works_without_ai(client) -> None:
    admin = admin_headers(client)
    create_destination(
        client,
        headers=admin,
        name="Punta Dumalag Reserve",
        category="  Beach Resort  ",
        district="Davao City",
        location="Matina Aplaya",
        lat=7.033,
        lng=125.568,
    )
    create_destination(
        client,
        headers=admin,
        name="Samal Sunset Beach Resort",
        category="beach resort",
        district="Davao del Norte",
        location="Samal Island",
        lat=7.081,
        lng=125.702,
    )
    create_destination(
        client,
        headers=admin,
        name="People's Park Plaza",
        category="Park / Public Plaza",
        district="Davao City",
        location="Downtown Davao",
        lat=7.071,
        lng=125.609,
    )

    first_facets = client.get("/api/v1/destinations/facets").json()
    by_key = {item["key"]: item for item in first_facets["categories"]}
    assert by_key["beach resort"]["count"] == 2
    assert by_key["public plaza"]["group"] == "parks_recreation"

    # Adding a brand-new category invalidates the 60s cache immediately.
    create_destination(
        client,
        headers=admin,
        name="Davao Space Dome",
        category="Observatory Dome",
        district="Davao City",
        location="Catalunan Pequeno",
        lat=7.058,
        lng=125.524,
    )
    refreshed_facets = client.get("/api/v1/destinations/facets").json()
    refreshed_keys = {item["key"]: item for item in refreshed_facets["categories"]}
    assert "observatory dome" in refreshed_keys
    assert refreshed_keys["observatory dome"]["group"] == "other"
    groups_map = {g["key"]: g for g in refreshed_facets["groups"]}
    assert groups_map["parks_recreation"]["count"] == 1
    assert groups_map["other"]["count"] == 1

    # No-AI browse endpoint supports normalized categories, aliases, and novel ones.
    plaza_browse = client.get(
        "/api/v1/destinations/browse",
        params={"category": "public plaza", "limit": 5},
    )
    assert plaza_browse.status_code == 200
    assert [p["name"] for p in plaza_browse.json()] == ["People's Park Plaza"]

    dome_browse = client.get(
        "/api/v1/destinations/browse",
        params={"category": "Observatory Domes", "limit": 5},
    )
    assert dome_browse.status_code == 200
    assert [p["name"] for p in dome_browse.json()] == ["Davao Space Dome"]


def test_ai_chat_receives_live_available_categories(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    create_destination(
        client,
        headers=admin,
        name="Buda Cloud Peak",
        category="Sea of Clouds Viewpoint",
        district="Davao City",
        location="Marilog",
        lat=7.462,
        lng=125.249,
    )
    fake = FakeGroqClient([
        json.dumps({
            "chat_response": "Here is a viewpoint for clouds.",
            "state_updates": {},
            "intent": "show_places",
            "place_query": {"categories": ["sea of clouds viewpoint"], "limit": 5},
            "suggested_replies": ["Show more viewpoints"],
        })
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    res = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Show sea of clouds spots",
            "planning_state": {"destination_ids": []},
        },
    )
    assert res.status_code == 200, res.text
    prompt_payload = json.loads(fake.calls[0]["messages"][-1]["content"])
    cats = {c["key"]: c for c in prompt_payload["available_categories"]}
    assert "sea of clouds viewpoint" in cats
    assert cats["sea of clouds viewpoint"]["examples"] == ["Buda Cloud Peak"]
    assert res.json()["planning"]["recommendations"][0]["name"] == "Buda Cloud Peak"
