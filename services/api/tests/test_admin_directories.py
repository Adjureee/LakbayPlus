def _register(client, *, name: str, email: str, admin: bool = False) -> dict:
    path = "/api/v1/auth/register/admin" if admin else "/api/v1/auth/register"
    payload = {
        "full_name": name,
        "email": email,
        "password": "password123",
        "confirm_password": "password123",
    }
    if admin:
        payload["admin_registration_code"] = "admin-test-code"
    res = client.post(path, json=payload)
    assert res.status_code == 201
    return res.json()


def test_admin_trips_and_reviews_directories_and_moderation(client) -> None:
    admin = _register(client, name="Admin One", email="admin-dir@example.com", admin=True)
    traveler = _register(client, name="Maya Traveler", email="maya@example.com")
    admin_headers = {"Authorization": f"Bearer {admin['tokens']['access_token']}"}
    traveler_headers = {"Authorization": f"Bearer {traveler['tokens']['access_token']}"}

    # Traveler cannot access admin trips or reviews directories.
    assert client.get("/api/v1/admin/trips").status_code == 401
    assert client.get("/api/v1/admin/trips", headers=traveler_headers).status_code == 403
    assert client.get("/api/v1/admin/reviews", headers=traveler_headers).status_code == 403

    # Admin creates a destination, traveler creates & completes a trip, then reviews it.
    dest_res = client.post(
        "/api/v1/destinations",
        headers=admin_headers,
        json={
            "name": "Eden Ridge",
            "district": "Davao City",
            "category": "Nature",
            "lat": 7.01,
            "lng": 125.49,
            "estimated_cost": "250.00",
        },
    )
    assert dest_res.status_code == 201
    dest_id = dest_res.json()["destination_id"]

    trip_res = client.post(
        "/api/v1/trips",
        headers=traveler_headers,
        json={
            "title": "Davao Highland Retreat",
            "traveler_count": 2,
            "total_budget": "5000.00",
            "estimated_total_cost": "3200.00",
            "destination_ids": [dest_id],
        },
    )
    assert trip_res.status_code == 201
    trip_id = trip_res.json()["trip_id"]

    assert (
        client.patch(
            f"/api/v1/trips/{trip_id}",
            headers=traveler_headers,
            json={"status": "completed"},
        ).status_code
        == 200
    )

    review_res = client.post(
        f"/api/v1/trips/{trip_id}/reviews",
        headers=traveler_headers,
        json={
            "destination_id": dest_id,
            "post_trip_rating": 5,
            "accuracy_rating": 5,
            "route_efficiency_rating": 4,
            "budget_adherence_rating": 5,
            "overall_experience_rating": 5,
            "comments": "Cool mountain breeze and accurate fees.",
        },
    )
    assert review_res.status_code == 201
    review_id = review_res.json()["trip_review_id"]

    # Admin lists trips & filters by query/status.
    trips_list = client.get("/api/v1/admin/trips?search=Highland", headers=admin_headers)
    assert trips_list.status_code == 200
    trips_body = trips_list.json()
    assert trips_body["total_trips"] == 1
    assert trips_body["matching_trips"] == 1
    assert trips_body["items"][0]["owner_email"] == "maya@example.com"
    assert trips_body["items"][0]["destination_names"] == ["Eden Ridge"]

    # Admin lists active reviews and moderates (soft-deletes) one review.
    reviews_list = client.get("/api/v1/admin/reviews?search=breeze", headers=admin_headers)
    assert reviews_list.status_code == 200
    reviews_body = reviews_list.json()
    assert reviews_body["total_reviews"] == 1
    assert reviews_body["items"][0]["destination_name"] == "Eden Ridge"

    archived = client.delete(f"/api/v1/admin/reviews/{review_id}", headers=admin_headers)
    assert archived.status_code == 200
    assert archived.json()["status"] == "deleted"

    active_after = client.get("/api/v1/admin/reviews?status=active", headers=admin_headers)
    assert active_after.status_code == 200
    assert active_after.json()["matching_reviews"] == 0
