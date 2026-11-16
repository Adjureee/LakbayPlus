from tests.test_phase5_ai_itineraries import (
    admin_headers,
    create_destination,
    user_headers,
)


def test_planning_draft_works_without_ai_for_guests_and_signed_in(client):
    admin = admin_headers(client)
    first = create_destination(
        client,
        headers=admin,
        name="Aliwagwag Falls",
        district="Davao Oriental",
        location="Cateel",
        category="waterfall",
        lat=7.674,
        lng=126.351,
        estimated_cost="150.00",
        stay_duration_type="half_day",
    )
    second = create_destination(
        client,
        headers=admin,
        name="Dahican Shore",
        district="Davao Oriental",
        location="Mati City",
        category="beach",
        lat=6.948,
        lng=126.254,
        estimated_cost=None,
        stay_duration_type="full_day",
    )

    payload = {
        "state": {
            "destination_ids": [first["destination_id"], second["destination_id"]],
            "day_count": 2,
            "traveler_count": 2,
            "total_budget": "1000.00",
        },
        "option_count": 2,
    }
    # Guest call (no auth headers) must succeed cleanly.
    guest_res = client.post("/api/v1/planning/draft", json=payload)
    assert guest_res.status_code == 200, guest_res.text
    body = guest_res.json()
    assert body["source"] == "catalog_deterministic"
    assert body["source_label"] == "Built from Lakbay's catalog, without AI"
    assert len(body["options"]) == 2

    opt1 = body["options"][0]
    assert len(opt1["days"]) == 2
    assert opt1["estimated_total_cost"] == "150.00"
    assert opt1["is_over_budget"] is False
    # Unlisted destination keeps cost at 0.00 and explains so; nothing is invented.
    assert second["destination_id"] in body["unlisted_cost_destination_ids"]
    acts = [act for day in opt1["days"] for act in day["activities"]]
    unlisted_act = next(a for a in acts if a["destination_id"] == second["destination_id"])
    assert unlisted_act["cost_listed"] is False
    assert unlisted_act["estimated_cost"] == "0.00"
    assert "not listed" in unlisted_act["notes"].lower()

    # Signed-in user can call it too.
    user_res = client.post(
        "/api/v1/planning/draft",
        headers=user_headers(client),
        json={**payload, "state": {**payload["state"], "total_budget": "100.00"}},
    )
    assert user_res.status_code == 200
    assert user_res.json()["options"][0]["is_over_budget"] is True


def test_planning_draft_selects_and_ranks_city_places_when_no_ids_given(client):
    admin = admin_headers(client)
    samal_a = create_destination(
        client,
        headers=admin,
        name="Hagimit Falls",
        district="Davao del Norte",
        location="Samal Island",
        category="waterfall",
        vibes="nature, falls",
        lat=7.071,
        lng=125.735,
        estimated_cost="250.00",
        stay_duration_type="half_day",
    )
    samal_b = create_destination(
        client,
        headers=admin,
        name="Canibad Cove",
        district="Davao del Norte",
        location="Samal Island",
        category="beach",
        vibes="coastal, relaxed",
        lat=7.115,
        lng=125.769,
        estimated_cost="300.00",
        stay_duration_type="half_day",
    )
    create_destination(
        client,
        headers=admin,
        name="Mati Museum",
        district="Davao Oriental",
        location="Mati City",
        category="museum",
        lat=6.955,
        lng=126.216,
    )

    res = client.post(
        "/api/v1/planning/draft",
        json={
            "city": "Samal",
            "state": {"day_count": 1, "interests": ["waterfall"]},
        },
    )
    assert res.status_code == 200, res.text
    body = res.json()
    picked_ids = {
        act["destination_id"]
        for day in body["options"][0]["days"]
        for act in day["activities"]
        if act["destination_id"] is not None
    }
    assert {samal_a["destination_id"], samal_b["destination_id"]} == picked_ids
