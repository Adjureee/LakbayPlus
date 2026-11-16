"""Review-queue candidates added from the admin map."""

from datetime import datetime, timezone

from tests.test_phase2_destination_data import admin_headers, create_destination, user_headers

BASE = "/api/v1/admin/destination-candidates"


def _pin(client, headers, **overrides) -> dict:
    body = {
        "name": "Hidden Spring",
        "lat": 7.21,
        "lng": 125.62,
        "suggested_category": "Hot Spring",
        "district": "Davao City",
        "review_notes": "Seen on satellite near the barangay road.",
        **overrides,
    }
    response = client.post(f"{BASE}/manual", headers=headers, json=body)
    assert response.status_code == 201, response.text
    return response.json()


def test_dropped_pin_is_queued_without_an_osm_identity(client) -> None:
    candidate = _pin(client, admin_headers(client))

    assert candidate["source"] == "manual"
    assert candidate["osm_type"] is None
    assert candidate["osm_id"] is None
    assert candidate["osm_url"] is None
    assert candidate["review_status"] == "staged"
    assert candidate["source_area"] == "Admin map"
    assert candidate["district"] == "Davao City"
    assert candidate["region_status"] == "inside"


def test_two_pins_without_osm_identity_can_coexist(client) -> None:
    headers = admin_headers(client)
    _pin(client, headers, name="Pin A")
    _pin(client, headers, name="Pin B", lat=7.3)
    listed = client.get(BASE, headers=headers).json()
    assert {item["name"] for item in listed} >= {"Pin A", "Pin B"}


def test_manual_pin_requires_admin_and_a_name(client) -> None:
    denied = client.post(
        f"{BASE}/manual",
        headers=user_headers(client),
        json={"name": "Spot", "lat": 7.2, "lng": 125.6},
    )
    assert denied.status_code == 403
    blank = client.post(
        f"{BASE}/manual",
        headers=admin_headers(client),
        json={"name": "  ", "lat": 7.2, "lng": 125.6},
    )
    assert blank.status_code == 422


def test_manual_candidate_has_no_osm_suggestions(client) -> None:
    headers = admin_headers(client)
    candidate = _pin(client, headers)
    response = client.get(
        f"{BASE}/{candidate['candidate_id']}/osm-suggestions", headers=headers
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "candidate_has_no_osm_source"


def test_manual_candidate_can_be_reviewed_and_published(client) -> None:
    headers = admin_headers(client)
    candidate = _pin(client, headers)
    base = f"{BASE}/{candidate['candidate_id']}"
    edited = client.patch(
        base,
        headers=headers,
        json={
            "category": "hot spring",
            "visitor_purpose": "Public bathing in natural hot springs",
            "access_policy": "public",
            "access_source_url": "https://example.org/hidden-spring",
            "access_verified_at": datetime.now(timezone.utc).isoformat(),
        },
    )
    assert edited.status_code == 200, edited.text
    published = client.post(f"{base}/publish", headers=headers)
    assert published.status_code == 200, published.text
    destination = client.get(
        f"/api/v1/destinations/{published.json()['destination_id']}"
    ).json()
    assert destination["name"] == "Hidden Spring"
    assert destination["lat"] == 7.21


def test_nearby_lists_destinations_and_staged_candidates_nearest_first(client) -> None:
    headers = admin_headers(client)
    destination = create_destination(client, headers)  # Test Beach, 6.9487, 126.2542
    _pin(client, headers, name="Beach Kiosk", lat=6.9490, lng=126.2545)
    _pin(client, headers, name="Far Away", lat=7.5, lng=125.5)

    response = client.get(
        f"{BASE}/nearby",
        headers=headers,
        params={"lat": 6.9488, "lng": 126.2543, "radius_m": 500},
    )
    assert response.status_code == 200
    places = response.json()["places"]
    assert [(p["kind"], p["name"]) for p in places] == [
        ("destination", "Test Beach"),
        ("candidate", "Beach Kiosk"),
    ]
    assert places[0]["id"] == destination["destination_id"]
    assert places[0]["distance_m"] < places[1]["distance_m"] < 500
    assert places[1]["review_status"] == "staged"


def test_nearby_is_admin_only(client) -> None:
    response = client.get(
        f"{BASE}/nearby",
        headers=user_headers(client),
        params={"lat": 7.0, "lng": 125.6},
    )
    assert response.status_code == 403


def test_osm_search_accepts_a_map_wide_radius(client) -> None:
    response = client.get(
        f"{BASE}/osm/search",
        headers=admin_headers(client),
        params={"name": "x", "lat": 7.0, "lng": 125.6, "radius_m": 60000},
    )
    # 60 km is over the 50 km limit; 50 km itself passes validation.
    assert response.status_code == 422
