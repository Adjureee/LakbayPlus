import json

from tests.e2e.conftest import FakeGoogleRoutesClient, FakeGroqClient, FakeOSRMClient
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


def test_t4_journey1_five_day_davao_samal_multimodal_live_traffic_hub_revisit(
    client,
    e2e_fakes,
) -> None:
    """Journey 1: 5-day Davao-Samal multimodal itinerary + live traffic + hub revisit + trip/route save."""
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client, full_name="Davao Explorer")
    seed_davao_samal_network(client, admin_headers)

    davao_hub = seed_destination(
        client, admin_headers, name="Davao Poblacion Hub", lat=7.0644, lng=125.6078, island_group="mainland"
    )
    samal_falls = seed_destination(
        client, admin_headers, name="Hagimit Falls Samal", lat=7.0785, lng=125.7412, island_group="samal"
    )
    samal_bat = seed_destination(
        client, admin_headers, name="Monfort Bat Sanctuary", lat=7.1636, lng=125.6901, island_group="samal"
    )
    eden = seed_destination(
        client, admin_headers, name="Eden Nature Park", lat=7.0320, lng=125.4420, island_group="mainland"
    )
    eagle = seed_destination(
        client, admin_headers, name="Philippine Eagle Center", lat=7.1859, lng=125.4152, island_group="mainland"
    )

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True, delay_seconds_per_leg=300.0)

    # 1. Plan 5-day multimodal route
    plan_resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [
                davao_hub["destination_id"],
                samal_falls["destination_id"],
                samal_bat["destination_id"],
                eden["destination_id"],
                eagle["destination_id"],
            ],
            "days": 5,
            "pace": "relaxed",
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert plan_resp.status_code == 200, plan_resp.text
    plan_route = plan_resp.json()["route"]
    assert len(plan_route["sea_crossings"]) >= 1
    assert {"road", "sea"} <= {s["mode"] for s in plan_route["segments"]}

    # 2. Preview explicit hub revisit: Davao Hub -> Samal Falls -> Davao Hub
    revisit_resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [
                davao_hub["destination_id"],
                samal_falls["destination_id"],
                davao_hub["destination_id"],
            ],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert revisit_resp.status_code == 200, revisit_resp.text
    revisit = revisit_resp.json()
    assert [s["destination_id"] for s in revisit["stops"]] == [
        davao_hub["destination_id"],
        samal_falls["destination_id"],
        davao_hub["destination_id"],
    ]
    assert len(revisit["sea_crossings"]) >= 2
    traffic = revisit.get("traffic_info") or revisit.get("traffic")
    assert traffic is not None
    assert traffic["status"] in {"live", "limited_coverage"}

    # 3. Save trip and route
    trip = seed_trip(
        client,
        user_headers,
        [
            davao_hub["destination_id"],
            samal_falls["destination_id"],
            samal_bat["destination_id"],
            eden["destination_id"],
            eagle["destination_id"],
        ],
        title="5-Day Davao & Samal Island Loop",
        start_date="2026-12-01",
        end_date="2026-12-05",
    )
    save_route = client.post(
        f"/api/v1/trips/{trip['trip_id']}/route",
        headers=user_headers,
        json={
            "travel_mode": plan_route["travel_mode"],
            "route_provider": plan_route["route_provider"],
            "is_estimated": plan_route["is_estimated"],
            "total_distance_km": plan_route["total_distance_km"],
            "total_duration_minutes": plan_route["total_duration_minutes"],
            "stops": plan_route["stops"],
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
                    "steps": leg["steps"] if plan_route["arrival_points_verified"] else [],
                }
                for leg in plan_route["legs"]
            ],
            "warnings": plan_route["warnings"],
            "polyline": plan_route["polyline"],
            "polyline_encoding": plan_route["polyline_encoding"],
            "arrival_points_verified": plan_route["arrival_points_verified"],
        },
    )
    assert save_route.status_code == 200, save_route.text

    fetched = client.get(f"/api/v1/trips/{trip['trip_id']}", headers=user_headers)
    assert fetched.status_code == 200
    assert fetched.json()["route"] is not None


def test_t4_journey2_mount_apo_eden_ai_chat_to_completed_trip_lifecycle(
    client,
    e2e_fakes,
) -> None:
    """Journey 2: Mount Apo & Eden AI chat multi-turn -> generate -> trip -> ongoing -> completed -> reopen."""
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client, full_name="Mount Apo Hiker")

    apo = seed_destination(
        client,
        admin_headers,
        name="Mount Apo Base Camp Sta. Cruz",
        district="Davao del Sur",
        location="Sta. Cruz",
        category="mountain",
        vibes="adventure",
        activities="hiking, trekking",
        lat=6.9874,
        lng=125.2710,
    )
    eden = seed_destination(
        client,
        admin_headers,
        name="Eden Nature Park",
        district="Davao City",
        location="Toril",
        category="mountain",
        vibes="relaxed",
        activities="zipline, nature walk",
        lat=7.0320,
        lng=125.4420,
    )
    dest_ids = [eden["destination_id"], apo["destination_id"]]

    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Great, mountain & nature attractions around Davao.",
                    "state_updates": {"interests": ["mountain"]},
                    "intent": "plan_trip",
                }
            ),
            json.dumps(
                {
                    "chat_response": "Got your group and schedule.",
                    "state_updates": {},
                    "intent": "plan_trip",
                }
            ),
            json.dumps(
                {
                    "chat_response": "Updated to 4 travelers and budget 15000.",
                    "state_updates": {"traveler_count": 4, "total_budget": "15000.00"},
                    "intent": "modify_trip",
                }
            ),
            build_valid_itinerary_json(destination_ids=dest_ids, day_count=3, option_count=2),
        ]
    )

    # Turn 1: interests
    t1 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={"message": "We want mountain trails near Mount Apo and Eden.", "use_rag": False, "planning_state": {}},
    )
    assert t1.status_code == 200, t1.text
    s1 = t1.json()["planning"]["preview"]["state"]

    # Turn 2: long out-of-order short answer with adult/child & day/night & activity_level
    t2 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "We are 2 adults and 1 child age 8 going for 3 days and 2 nights on moderate trails",
            "use_rag": False,
            "history": [{"role": "assistant", "content": "How many people are going?"}],
            "planning_state": s1,
        },
    )
    assert t2.status_code == 200, t2.text
    assert t2.json()["planning"]["update_status"] == "applied"
    s2 = t2.json()["planning"]["preview"]["state"]
    assert s2["adult_count"] == 2
    assert s2["child_ages"] == [8]
    assert s2["day_count"] == 3

    # Turn 3: cross-field traveler_count change + budget
    t3 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Actually 4 travelers total with a 15000 budget.",
            "use_rag": False,
            "planning_state": s2,
        },
    )
    assert t3.status_code == 200, t3.text
    assert t3.json()["planning"]["update_status"] == "applied"
    s3 = t3.json()["planning"]["preview"]["state"]
    assert s3["traveler_count"] == 4
    assert s3["adult_count"] + len(s3["child_ages"]) == 4

    # Generate itinerary
    s3["origin"] = s3.get("origin") or {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}
    s3["destination_ids"] = dest_ids
    s3["return_to_origin"] = True
    s3["selected_transport_option_ids"] = ["mode:personal_vehicle"]
    s3["cost_allowances"] = [
        *[{"category": "destination", "destination_id": d_id, "amount": "150.00"} for d_id in dest_ids],
        {"category": "transportation", "amount": "800.00"},
        {"category": "accommodation", "amount": "2000.00"},
        {"category": "food", "amount": "1200.00"},
    ]
    gen = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers,
        json={
            "total_budget": "15000.00",
            "traveler_count": 4,
            "day_count": 3,
            "destination_ids": dest_ids,
            "interests": ["mountain"],
            "planning_state": s3,
        },
    )
    assert gen.status_code == 200, gen.text
    run_id = gen.json()["selected_generation_run_id"]
    assert run_id is not None

    # Create trip -> ongoing -> completed -> reopen
    trip = client.post(
        "/api/v1/trips/from-ai-option",
        headers=user_headers,
        json={"generation_run_id": run_id, "option_number": 1},
    )
    assert trip.status_code == 201, trip.text
    trip_id = trip.json()["trip_id"]

    r_on = client.patch(f"/api/v1/trips/{trip_id}", headers=user_headers, json={"status": "ongoing"})
    assert r_on.status_code == 200
    assert r_on.json()["status"] == "ongoing"

    r_done = client.patch(f"/api/v1/trips/{trip_id}", headers=user_headers, json={"status": "completed"})
    assert r_done.status_code == 200
    assert r_done.json()["status"] == "completed"
    assert r_done.json()["completed_at"] is not None

    r_reopen = client.patch(f"/api/v1/trips/{trip_id}", headers=user_headers, json={"status": "planned"})
    assert r_reopen.status_code == 200
    assert r_reopen.json()["status"] == "planned"
    assert r_reopen.json()["completed_at"] is None


def test_t4_journey3_admin_davao_curation_media_browse_and_trip_creation(client) -> None:
    """Journey 3: Admin Davao curation (verified coords, D6, MP4/GIF) -> browse -> traveler trip."""
    admin_headers, _ = register_admin(client, full_name="Davao Curator")
    user_headers, _ = register_user(client, full_name="Catalog Traveler")

    malagos = seed_destination(
        client,
        admin_headers,
        name="Malagos Garden Resort",
        district="Davao City",
        location="Calinan, Davao City",
        category="park",
        lat=7.1892,
        lng=125.4241,
        arrival_lat=7.1895,
        arrival_lng=125.4244,
        arrival_source_url="https://osm.org/node/9901",
        arrival_verified_at="2026-11-01T08:00:00Z",
        route_ready=True,
    )
    dahican = seed_destination(
        client,
        admin_headers,
        name="Dahican Beach Mati",
        district="Davao Oriental",
        location="Mati City",
        category="beach",
        lat=6.9242,
        lng=126.2788,
        arrival_lat=6.9245,
        arrival_lng=126.2785,
        arrival_source_url="https://osm.org/node/9902",
        arrival_verified_at="2026-11-01T08:00:00Z",
        route_ready=True,
    )

    enrich_destination_d6(client, admin_headers, malagos["destination_id"])
    enrich_destination_d6(client, admin_headers, dahican["destination_id"])

    r_mp4 = client.post(
        f"/api/v1/destinations/{malagos['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("malagos.mp4", make_mp4_bytes(duration_seconds=9.0), "video/mp4")},
    )
    assert r_mp4.status_code == 200, r_mp4.text

    r_gif = client.post(
        f"/api/v1/destinations/{dahican['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("dahican.gif", make_gif89a_bytes(), "image/gif")},
    )
    assert r_gif.status_code == 200, r_gif.text

    browse_parks = client.get("/api/v1/destinations/browse", params={"category": "park"})
    assert browse_parks.status_code == 200
    assert any(d["destination_id"] == malagos["destination_id"] for d in browse_parks.json())

    browse_beaches = client.get("/api/v1/destinations/browse", params={"category": "beach"})
    assert browse_beaches.status_code == 200
    assert any(d["destination_id"] == dahican["destination_id"] for d in browse_beaches.json())

    detail_malagos = client.get(f"/api/v1/destinations/{malagos['destination_id']}").json()
    assert detail_malagos["media_type"] == "video"
    assert detail_malagos["media_duration_seconds"] == 9.0
    assert detail_malagos["route_ready"] is True

    trip = seed_trip(
        client,
        user_headers,
        [malagos["destination_id"], dahican["destination_id"]],
        title="Curated Davao & Mati Tour",
    )
    assert len(trip["destinations"]) == 2


def test_t4_journey4_fourteen_day_davao_region_grand_loop(client, e2e_fakes) -> None:
    """Journey 4: 14-day Davao Region grand loop (16 stops across mainland + Samal + off-road fallback)."""
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    seed_davao_samal_network(client, admin_headers)

    grand_loop_specs = [
        ("People's Park Davao", 7.0644, 125.6078, "mainland"),
        ("Jack's Ridge", 7.0609, 125.5801, "mainland"),
        ("Crocodile Park", 7.0994, 125.6197, "mainland"),
        ("Eden Nature Park", 7.0320, 125.4420, "mainland"),
        ("Philippine Eagle Center", 7.1859, 125.4152, "mainland"),
        ("Malagos Garden Resort", 7.1892, 125.4241, "mainland"),
        ("Hagimit Falls Samal", 7.0785, 125.7412, "samal"),
        ("Monfort Bat Sanctuary", 7.1636, 125.6901, "samal"),
        ("Kaputian Beach Park", 6.9701, 125.7354, "samal"),
        ("Tagum Energy Park", 7.4201, 125.8140, "mainland"),
        ("Christ the King Tagum", 7.4480, 125.8090, "mainland"),
        ("New Corella Falls", 7.5890, 125.8250, "mainland"),
        ("Sleeping Dinosaur Mati", 6.9600, 126.1912, "mainland"),
        ("Dahican Beach Mati", 6.9242, 126.2788, "mainland"),
        ("Digos Coastal Park", 6.7496, 125.3572, "mainland"),
        ("Sta. Cruz Highland Ridge", 6.8350, 125.4100, "mainland"),
    ]
    stops = [
        seed_destination(
            client,
            admin_headers,
            name=name,
            lat=lat,
            lng=lng,
            island_group=island,
            stay_duration_type="half_day",
        )
        for name, lat, lng, island in grand_loop_specs
    ]

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [s["destination_id"] for s in stops],
            "days": 14,
            "pace": "balanced",
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body["route"]["stops"]) == 16
    assert len(body["route"]["sea_crossings"]) >= 1
    assert {"road", "sea"} <= {seg["mode"] for seg in body["route"]["segments"]}
    assert body["route"]["polyline"]

    # Also verify partial-routing fallback if one Samal stop fails road snapping
    e2e_fakes.osrm = FakeOSRMClient(unreachable_lats={6.9701})
    fallback_resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [
                stops[0]["destination_id"],
                stops[1]["destination_id"],
                stops[8]["destination_id"],
            ],
            "travel_mode": "driving",
        },
    )
    assert fallback_resp.status_code == 200, fallback_resp.text
    fb_route = fallback_resp.json()
    assert fb_route["segments"]
    assert any(seg["mode"] == "road" and not seg["is_estimated"] for seg in fb_route["segments"])
    assert any(seg["mode"] == "sea" for seg in fb_route["segments"])
    assert any(seg["is_estimated"] for seg in fb_route["segments"])
