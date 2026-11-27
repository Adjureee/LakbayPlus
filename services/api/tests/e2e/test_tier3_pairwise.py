import json

from tests.e2e.conftest import FakeGoogleRoutesClient, FakeGroqClient
from tests.e2e.helpers import (
    build_valid_itinerary_json,
    enrich_destination_d6,
    make_gif89a_bytes,
    make_mp4_bytes,
    register_admin,
    register_user,
    seed_davao_samal_network,
    seed_destination,
    seed_trip,
)


def test_t3_multiday_live_traffic_with_sea_crossings(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    seed_davao_samal_network(client, admin_headers)

    mainland_1 = seed_destination(
        client, admin_headers, name="Davao Crocodile Park", lat=7.0994, lng=125.6197, island_group="mainland"
    )
    mainland_2 = seed_destination(
        client, admin_headers, name="People's Park", lat=7.0644, lng=125.6078, island_group="mainland"
    )
    samal_1 = seed_destination(
        client, admin_headers, name="Hagimit Falls", lat=7.0785, lng=125.7412, island_group="samal"
    )
    samal_2 = seed_destination(
        client, admin_headers, name="Monfort Bat Sanctuary", lat=7.1636, lng=125.6901, island_group="samal"
    )

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True, delay_seconds_per_leg=240.0)

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [
                mainland_1["destination_id"],
                mainland_2["destination_id"],
                samal_1["destination_id"],
                samal_2["destination_id"],
            ],
            "days": 5,
            "pace": "relaxed",
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    route = resp.json()["route"]
    assert len(route["sea_crossings"]) >= 1
    modes = {seg["mode"] for seg in route["segments"]}
    assert {"road", "sea"} <= modes
    traffic = route.get("traffic_info") or route.get("traffic")
    assert traffic is not None
    assert traffic["status"] in {"live", "limited_coverage"}


def test_t3_ai_trip_draft_to_trip_route_and_completion(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    d1 = seed_destination(client, admin_headers, name="Eden Nature Park", lat=7.0320, lng=125.4420)
    d2 = seed_destination(client, admin_headers, name="Malagos Garden", lat=7.1892, lng=125.4241)

    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "reply": "Here is a 2-day Davao nature draft.",
                    "should_create_itinerary": True,
                    "title": "Davao Highlands Escape",
                    "destination": "Davao City",
                    "vibe": "relaxed",
                    "days_count": 2,
                    "days": [
                        {
                            "day": 1,
                            "title": "Highland Parks",
                            "summary": "Visit Eden and Malagos.",
                            "activities": [
                                {"time": "09:00", "title": "Eden Nature Park", "destination_id": d1["destination_id"]},
                                {"time": "14:00", "title": "Malagos Garden", "destination_id": d2["destination_id"]},
                            ],
                        }
                    ],
                }
            )
        ]
    )

    draft_resp = client.post(
        "/api/v1/ai/trip-draft",
        headers=user_headers,
        json={"message": "Plan a 2-day nature trip in Davao.", "default_days": 2},
    )
    assert draft_resp.status_code == 200, draft_resp.text
    draft = draft_resp.json()["draft"]
    assert draft["should_create_itinerary"] is True

    trip = seed_trip(
        client,
        user_headers,
        [d1["destination_id"], d2["destination_id"]],
        title=draft["title"],
    )

    preview_resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [d1["destination_id"], d2["destination_id"]],
            "travel_mode": "driving",
        },
    )
    assert preview_resp.status_code == 200, preview_resp.text
    preview = preview_resp.json()

    save_route = client.post(
        f"/api/v1/trips/{trip['trip_id']}/route",
        headers=user_headers,
        json={
            "travel_mode": preview["travel_mode"],
            "route_provider": preview["route_provider"],
            "is_estimated": preview["is_estimated"],
            "total_distance_km": preview["total_distance_km"],
            "total_duration_minutes": preview["total_duration_minutes"],
            "stops": preview["stops"],
            "legs": [
                {
                    "order": leg["order"],
                    "from_destination_id": leg["from_destination_id"],
                    "to_destination_id": leg["to_destination_id"],
                    "from_name": leg["from_name"],
                    "to_name": leg["to_name"],
                    "distance_km": leg["distance_km"],
                    "duration_minutes": leg["duration_minutes"],
                    "is_estimated": leg["is_estimated"],
                    "steps": leg["steps"],
                }
                for leg in preview["legs"]
            ],
            "warnings": preview["warnings"],
            "polyline": preview["polyline"],
            "polyline_encoding": preview["polyline_encoding"],
            "arrival_points_verified": preview["arrival_points_verified"],
        },
    )
    assert save_route.status_code == 200, save_route.text

    complete_resp = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "completed"},
    )
    assert complete_resp.status_code == 200, complete_resp.text
    assert complete_resp.json()["status"] == "completed"
    assert complete_resp.json()["completed_at"] is not None
    assert complete_resp.json()["route"] is not None


def test_t3_destination_media_d6_enrichment_browse_and_trip_creation(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)

    beach = seed_destination(
        client,
        admin_headers,
        name="Dahican Surf Sanctuary",
        district="Davao Oriental",
        location="Mati City",
        category="beach",
        lat=6.9242,
        lng=126.2788,
    )
    dest_id = beach["destination_id"]
    enrich_destination_d6(client, admin_headers, dest_id)

    gif_resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("dahican.gif", make_gif89a_bytes(), "image/gif")},
    )
    assert gif_resp.status_code == 200, gif_resp.text

    mp4_resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("dahican.mp4", make_mp4_bytes(duration_seconds=7.0), "video/mp4")},
    )
    assert mp4_resp.status_code == 200, mp4_resp.text

    browse_resp = client.get("/api/v1/destinations/browse", params={"category": "beach"})
    assert browse_resp.status_code == 200, browse_resp.text
    assert any(item["destination_id"] == dest_id for item in browse_resp.json())

    detail_resp = client.get(f"/api/v1/destinations/{dest_id}")
    assert detail_resp.status_code == 200
    assert detail_resp.json()["media_type"] == "video"
    assert detail_resp.json()["media_duration_seconds"] == 7.0
    assert detail_resp.json()["image_url"]

    trip = seed_trip(client, user_headers, [dest_id], title="Mati Surf Weekend")
    assert trip["destinations"][0]["destination_id"] == dest_id


def test_t3_guest_chat_and_route_to_registered_itinerary_and_trip(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    s1 = seed_destination(client, admin_headers, name="Guest Stop A", category="beach", lat=7.0644, lng=125.6078)
    s2 = seed_destination(client, admin_headers, name="Guest Stop B", category="beach", lat=7.0994, lng=125.6197)
    dest_ids = [s1["destination_id"], s2["destination_id"]]

    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Beach trip for 2 travelers over 2 days.",
                    "state_updates": {"interests": ["beach"], "traveler_count": 2, "day_count": 2},
                    "intent": "plan_trip",
                }
            ),
            build_valid_itinerary_json(destination_ids=dest_ids, day_count=2, option_count=2),
        ]
    )

    guest_chat = client.post(
        "/api/v1/ai/chat/guest",
        json={"message": "2 people, 2 days at the beach.", "use_rag": False, "planning_state": {}},
    )
    assert guest_chat.status_code == 200, guest_chat.text
    assert guest_chat.json()["planning"]["update_status"] == "applied"

    guest_route = client.post(
        "/api/v1/routes/plan/guest",
        json={"destination_ids": dest_ids, "days": 2, "travel_mode": "driving"},
    )
    assert guest_route.status_code == 200, guest_route.text

    user_headers, _ = register_user(client)
    gen_resp = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers,
        json={
            "total_budget": "8000.00",
            "traveler_count": 2,
            "day_count": 2,
            "destination_ids": dest_ids,
            "interests": ["beach"],
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": dest_ids,
                "total_budget": "8000.00",
                "traveler_count": 2,
                "day_count": 2,
                "night_count": 1,
                "return_to_origin": True,
                "selected_transport_option_ids": ["mode:personal_vehicle"],
                "cost_allowances": [
                    *[
                        {"category": "destination", "destination_id": d_id, "amount": "150.00"}
                        for d_id in dest_ids
                    ],
                    {"category": "transportation", "amount": "500.00"},
                    {"category": "accommodation", "amount": "1500.00"},
                    {"category": "food", "amount": "1000.00"},
                ],
                "interests": ["beach"],
            },
        },
    )
    assert gen_resp.status_code == 200, gen_resp.text
    run_id = gen_resp.json()["selected_generation_run_id"]
    assert run_id is not None

    saved = client.post(
        "/api/v1/trips/from-ai-option",
        headers=user_headers,
        json={
            "generation_run_id": run_id,
            "option_number": 1,
            "start_date": "2026-11-10",
            "end_date": "2026-11-11",
        },
    )
    assert saved.status_code == 201, saved.text
    assert saved.json()["status"] == "planned"


def test_t3_shared_trip_organizer_edit_owner_complete_reopen_admin_audit(client) -> None:
    admin_headers, _ = register_admin(client)
    owner_headers, _ = register_user(client, full_name="Owner User")
    org_headers, org_user = register_user(client, full_name="Organizer User")
    stop = seed_destination(client, admin_headers, name="Shared Audit Stop")

    trip = seed_trip(client, owner_headers, [stop["destination_id"]], title="Shared Davao Trip")

    inv = client.post(
        f"/api/v1/trips/{trip['trip_id']}/members",
        headers=owner_headers,
        json={"email": org_user["email"], "role": "organizer"},
    )
    assert inv.status_code == 201, inv.text

    acc = client.post(f"/api/v1/trips/{trip['trip_id']}/invitation/accept", headers=org_headers)
    assert acc.status_code == 200, acc.text

    org_edit = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=org_headers,
        json={"notes": "Organizer updated departure notes."},
    )
    assert org_edit.status_code == 200, org_edit.text

    done1 = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=owner_headers,
        json={"status": "completed"},
    )
    assert done1.status_code == 200
    assert done1.json()["completed_at"] is not None

    reopen = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=owner_headers,
        json={"status": "planned"},
    )
    assert reopen.status_code == 200
    assert reopen.json()["completed_at"] is None

    done2 = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=owner_headers,
        json={"status": "completed"},
    )
    assert done2.status_code == 200
    assert done2.json()["completed_at"] is not None

    admin_list = client.get(
        "/api/v1/admin/trips",
        headers=admin_headers,
        params={"status": "completed"},
    )
    assert admin_list.status_code == 200
    matched = [item for item in admin_list.json()["items"] if item["trip_id"] == trip["trip_id"]]
    assert len(matched) == 1
    assert matched[0]["completed_at"] is not None
