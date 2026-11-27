import json

from app.integrations.google_routes.errors import GoogleRoutesClientError
from app.integrations.storage.uploads import MEDIA_MAX_IMAGE_BYTES, MEDIA_MAX_VIDEO_BYTES
from tests.e2e.conftest import FakeGoogleRoutesClient, FakeGroqClient, FakeOSRMClient, FakeStorageClient
from tests.e2e.helpers import (
    make_gif89a_bytes,
    make_jpeg_bytes,
    make_mp4_bytes,
    register_admin,
    register_user,
    seed_davao_samal_network,
    seed_destination,
    seed_trip,
)


# ---------------------------------------------------------------------------
# F1 Boundaries & Negative Cases (>=5)
# ---------------------------------------------------------------------------


def test_t2_f1_missing_google_key_unavailable_no_provider(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    s1 = seed_destination(client, admin_headers, name="Stop 1", lat=7.0644, lng=125.6078)
    s2 = seed_destination(client, admin_headers, name="Stop 2", lat=7.0994, lng=125.6197)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=False)
    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [s1["destination_id"], s2["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    traffic = body.get("traffic_info") or body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "unavailable_no_provider"


def test_t2_f1_sparse_region_limited_coverage(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    s1 = seed_destination(client, admin_headers, name="Baganga North", lat=7.5750, lng=126.5600)
    s2 = seed_destination(client, admin_headers, name="Cateel Falls", lat=7.7910, lng=126.4530)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(
        is_configured=True,
        error=GoogleRoutesClientError("Traffic telemetry sparse in Davao Oriental."),
    )
    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [s1["destination_id"], s2["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["polyline"]
    assert (body.get("traffic_info") or body.get("traffic"))["status"] == "limited_coverage"


def test_t2_f1_cycling_and_walking_with_live_traffic_true(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    s1 = seed_destination(client, admin_headers, name="Coastal Walk A", lat=7.0600, lng=125.6050)
    s2 = seed_destination(client, admin_headers, name="Coastal Walk B", lat=7.0700, lng=125.6150)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True)
    for mode in ("cycling", "walking"):
        resp = client.post(
            "/api/v1/routes/preview",
            headers=user_headers,
            json={
                "destination_ids": [s1["destination_id"], s2["destination_id"]],
                "travel_mode": mode,
                "use_live_traffic": True,
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        traffic = body.get("traffic_info") or body.get("traffic")
        assert traffic is not None
        assert traffic["status"] in {"disabled", "unavailable_no_provider"}
    assert len(e2e_fakes.google_routes.calls) == 0


def test_t2_f1_use_live_traffic_false_disabled(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    s1 = seed_destination(client, admin_headers, name="Bankerohan", lat=7.0680, lng=125.6010)
    s2 = seed_destination(client, admin_headers, name="Matina", lat=7.0540, lng=125.5900)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True)
    resp = client.post(
        "/api/v1/routes/optimize",
        headers=user_headers,
        json={
            "destination_ids": [s1["destination_id"], s2["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": False,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    traffic = body.get("traffic_info") or body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "disabled"
    assert len(e2e_fakes.google_routes.calls) == 0


def test_t2_f1_single_stop_route_traffic_handling(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    solo = seed_destination(client, admin_headers, name="Solo Park", lat=7.0644, lng=125.6078)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True)
    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [solo["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["legs"] == []
    traffic = body.get("traffic_info") or body.get("traffic")
    if traffic is not None:
        assert traffic["status"] != "live"
    assert len(e2e_fakes.google_routes.calls) == 0


# ---------------------------------------------------------------------------
# F2 Boundaries & Negative Cases (>=5)
# ---------------------------------------------------------------------------


def test_t2_f2_empty_and_invalid_single_stop_route_errors(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    solo = seed_destination(client, admin_headers, name="Solo Stop", lat=7.0644, lng=125.6078)

    empty_resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={"destination_ids": [], "travel_mode": "driving"},
    )
    assert empty_resp.status_code == 422

    rto_resp = client.post(
        "/api/v1/routes/optimize",
        headers=user_headers,
        json={
            "destination_ids": [solo["destination_id"]],
            "travel_mode": "driving",
            "return_to_origin": True,
        },
    )
    assert rto_resp.status_code == 422


def test_t2_f2_fourteen_day_chunked_routing_over_ten_stops(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)

    stops = [
        seed_destination(
            client,
            admin_headers,
            name=f"Davao Loop Stop {i + 1}",
            lat=6.80 + i * 0.05,
            lng=125.40 + i * 0.04,
            stay_duration_type="half_day",
        )
        for i in range(16)
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
    assert body["route"]["polyline"]
    assert not body["route"]["is_estimated"]


def test_t2_f2_inactive_or_nonexistent_destination_returns_404(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    active = seed_destination(client, admin_headers, name="Active Stop")
    inactive = seed_destination(client, admin_headers, name="Deactivated Stop")

    del_resp = client.delete(
        f"/api/v1/destinations/{inactive['destination_id']}",
        headers=admin_headers,
    )
    assert del_resp.status_code == 200

    resp_inactive = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={"destination_ids": [active["destination_id"], inactive["destination_id"]]},
    )
    assert resp_inactive.status_code == 404

    resp_missing = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={"destination_ids": [active["destination_id"], 999999]},
    )
    assert resp_missing.status_code == 404


def test_t2_f2_unconnected_island_group_partial_geometry(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    # No sea ports/links seeded for Talikud!
    mainland = seed_destination(
        client,
        admin_headers,
        name="Davao Mainland Stop",
        lat=7.0644,
        lng=125.6078,
        island_group="mainland",
    )
    talikud = seed_destination(
        client,
        admin_headers,
        name="Talikud Unconnected Cove",
        lat=6.9333,
        lng=125.7021,
        island_group="talikud",
    )

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={"destination_ids": [mainland["destination_id"], talikud["destination_id"]]},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["is_estimated"] is True
    assert "talikud" in body["unconnected_island_groups"]
    assert body["warnings"]


def test_t2_f2_off_road_snapping_fallback_preserves_partial_road_geometry(
    client,
    e2e_fakes,
) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    seed_davao_samal_network(client, admin_headers)

    mainland_a = seed_destination(
        client, admin_headers, name="Davao Port Gate", lat=7.0644, lng=125.6078, island_group="mainland"
    )
    mainland_b = seed_destination(
        client, admin_headers, name="Sasa Landing", lat=7.1100, lng=125.6500, island_group="mainland"
    )
    samal_offroad = seed_destination(
        client, admin_headers, name="Remote Samal Peak", lat=7.0411, lng=125.7511, island_group="samal"
    )

    # Mainland run succeeds; Samal off-road run fails snapping
    e2e_fakes.osrm = FakeOSRMClient(unreachable_lats={7.0411})

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [
                mainland_a["destination_id"],
                mainland_b["destination_id"],
                samal_offroad["destination_id"],
            ],
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["segments"]
    # Mainland road segment remains non-estimated while off-road segment is marked estimated
    assert any(seg["mode"] == "road" and not seg["is_estimated"] for seg in body["segments"])
    assert any(seg["is_estimated"] for seg in body["segments"])
    assert body["warnings"]


# ---------------------------------------------------------------------------
# F4 Boundaries & Negative Cases (>=5)
# ---------------------------------------------------------------------------


def test_t2_f4_caller_owned_selected_and_route_preferences_rejected(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "I switched your transport and route optimization.",
                    "state_updates": {
                        "selected_transport_option_ids": ["mode:walking"],
                        "route_preferences": {"optimize_order": True},
                    },
                    "intent": "modify_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Switch to walking and optimize route.",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "invalid_output"
    state = planning["preview"]["state"]
    assert state["selected_transport_option_ids"] == ["mode:personal_vehicle"]
    assert state["route_preferences"] is None


def test_t2_f4_night_count_gt_day_count_auto_reconciled(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Shortened to 2 days.",
                    "state_updates": {"day_count": 2},
                    "intent": "modify_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Actually make it 2 days instead.",
            "use_rag": False,
            "planning_state": {
                "interests": ["beach"],
                "day_count": 4,
                "night_count": 3,
                "traveler_count": 2,
                "total_budget": "7000.00",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    state = planning["preview"]["state"]
    assert state["day_count"] == 2
    assert state["night_count"] <= state["day_count"]


def test_t2_f4_adult_count_and_child_ages_reconciled_on_traveler_change(
    client,
    e2e_fakes,
) -> None:
    user_headers, _ = register_user(client)
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Updated total travelers to 4.",
                    "state_updates": {"traveler_count": 4},
                    "intent": "modify_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Make it 4 travelers total.",
            "use_rag": False,
            "planning_state": {
                "interests": ["beach"],
                "traveler_count": 3,
                "adult_count": 2,
                "child_ages": [7],
                "day_count": 2,
                "total_budget": "8000.00",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    state = planning["preview"]["state"]
    assert state["traveler_count"] == 4
    assert state["adult_count"] + len(state["child_ages"]) == 4


def test_t2_f4_long_out_of_order_short_answers_accepted(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Got all those details.",
                    "state_updates": {},
                    "intent": "plan_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": (
                "Actually for 4 days and 3 nights we are 2 adults and 1 child age 5 "
                "looking for easy trails and quiet beaches"
            ),
            "use_rag": False,
            "history": [
                {"role": "assistant", "content": "How many people are going?"},
            ],
            "planning_state": {
                "interests": ["nature"],
                "total_budget": "10000.00",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    state = planning["preview"]["state"]
    assert state["day_count"] == 4
    assert state["night_count"] == 3
    assert state["traveler_count"] == 3
    assert state["adult_count"] == 2
    assert state["child_ages"] == [5]


def test_t2_f4_malformed_json_repair_retry_and_recovery_prompt(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)

    # Case A: malformed JSON triggers 1 silent repair retry and succeeds on retry
    e2e_fakes.groq = FakeGroqClient(
        [
            "{broken-json-output",
            json.dumps(
                {
                    "chat_response": "Added food spots alongside your beach plan.",
                    "state_updates": {"interests": ["beach", "food"]},
                    "intent": "modify_trip",
                }
            ),
        ]
    )
    r_retry = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Also include food spots in the mix.",
            "use_rag": False,
            "planning_state": {"interests": ["beach"], "traveler_count": 2},
        },
    )
    assert r_retry.status_code == 200, r_retry.text
    assert len(e2e_fakes.groq.calls) == 2
    assert r_retry.json()["planning"]["update_status"] == "applied"
    assert r_retry.json()["planning"]["preview"]["state"]["interests"] == ["beach", "food"]

    # Case B: unrecoverable JSON after retry returns helpful recovery prompt (not raw crash)
    admin_headers, _ = register_admin(client)
    seed_destination(client, admin_headers, name="Samal Beach Cove", category="beach")
    e2e_fakes.groq = FakeGroqClient(["{still-invalid", "{unrecoverable-json"])
    r_recover = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Hmm not sure yet",
            "use_rag": False,
            "planning_state": {"interests": ["beach"], "traveler_count": 2},
        },
    )
    assert r_recover.status_code == 200, r_recover.text
    body = r_recover.json()
    assert body["planning"]["update_status"] == "invalid_output"
    assert "for example" in body["chat_response"].lower() or "how many days" in body["chat_response"].lower()


# ---------------------------------------------------------------------------
# F6 Boundaries & Negative Cases (>=5)
# ---------------------------------------------------------------------------


def test_t2_f6_archived_to_planned_blocked(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Archive Check Stop")
    trip = seed_trip(client, user_headers, [stop["destination_id"]])

    arch = client.post(f"/api/v1/trips/{trip['trip_id']}/archive", headers=user_headers)
    assert arch.status_code == 200
    assert arch.json()["status"] == "archived"

    reopen = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "planned"},
    )
    assert reopen.status_code in {400, 409, 422}


def test_t2_f6_non_owner_archive_blocked(client) -> None:
    admin_headers, _ = register_admin(client)
    owner_headers, _ = register_user(client, full_name="Trip Owner")
    org_headers, org_user = register_user(client, full_name="Trip Organizer")
    mem_headers, mem_user = register_user(client, full_name="Trip Member")
    stop = seed_destination(client, admin_headers, name="Shared Stop")
    trip = seed_trip(client, owner_headers, [stop["destination_id"]])

    for email, role, hdrs in (
        (org_user["email"], "organizer", org_headers),
        (mem_user["email"], "member", mem_headers),
    ):
        inv = client.post(
            f"/api/v1/trips/{trip['trip_id']}/members",
            headers=owner_headers,
            json={"email": email, "role": role},
        )
        assert inv.status_code == 201, inv.text
        acc = client.post(f"/api/v1/trips/{trip['trip_id']}/invitation/accept", headers=hdrs)
        assert acc.status_code == 200, acc.text

    org_arch_patch = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=org_headers,
        json={"status": "archived"},
    )
    assert org_arch_patch.status_code == 403

    org_arch_del = client.delete(f"/api/v1/trips/{trip['trip_id']}", headers=org_headers)
    assert org_arch_del.status_code == 403

    mem_patch = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=mem_headers,
        json={"status": "completed"},
    )
    assert mem_patch.status_code == 403


def test_t2_f6_empty_patch_returns_400(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Empty Patch Stop")
    trip = seed_trip(client, user_headers, [stop["destination_id"]])

    resp = client.patch(f"/api/v1/trips/{trip['trip_id']}", headers=user_headers, json={})
    assert resp.status_code == 400


def test_t2_f6_start_date_after_end_date_returns_400(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Date Guard Stop")
    trip = seed_trip(
        client,
        user_headers,
        [stop["destination_id"]],
        start_date="2026-10-10",
        end_date="2026-10-12",
    )

    resp = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"start_date": "2026-10-20"},
    )
    assert resp.status_code == 400


def test_t2_f6_non_member_access_returns_403(client) -> None:
    admin_headers, _ = register_admin(client)
    owner_headers, _ = register_user(client, full_name="Owner")
    stranger_headers, _ = register_user(client, full_name="Stranger")
    stop = seed_destination(client, admin_headers, name="Private Stop")
    trip = seed_trip(client, owner_headers, [stop["destination_id"]])

    r_get = client.get(f"/api/v1/trips/{trip['trip_id']}", headers=stranger_headers)
    assert r_get.status_code in {403, 404}

    r_patch = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=stranger_headers,
        json={"title": "Hijacked Title"},
    )
    assert r_patch.status_code in {403, 404}


# ---------------------------------------------------------------------------
# F7 Boundaries & Negative Cases (>=6)
# ---------------------------------------------------------------------------


def test_t2_f7_gif_over_10mb_rejected(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Oversized GIF Stop")
    oversized_gif = make_gif89a_bytes() + (b"\x00" * (MEDIA_MAX_IMAGE_BYTES + 1))

    resp = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("huge.gif", oversized_gif, "image/gif")},
    )
    assert resp.status_code in {400, 413}
    assert resp.json()["error"]["code"] == "upload_too_large"


def test_t2_f7_mp4_over_15mb_rejected(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Oversized MP4 Stop")
    oversized_mp4 = make_mp4_bytes(duration_seconds=5.0) + (b"\x00" * (MEDIA_MAX_VIDEO_BYTES + 1))

    resp = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("huge.mp4", oversized_mp4, "video/mp4")},
    )
    assert resp.status_code in {400, 413}
    assert resp.json()["error"]["code"] == "upload_too_large"


def test_t2_f7_video_over_15s_duration_rejected(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Long Clip Stop")

    # Pre-upload container mvhd check (>15s)
    r_container = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("long.mp4", make_mp4_bytes(duration_seconds=16.5), "video/mp4")},
    )
    assert r_container.status_code == 400
    assert r_container.json()["error"]["code"] == "media_duration_exceeded"

    # Post-upload provider duration check (when container has no moov/mvhd box)
    e2e_fakes.storage = FakeStorageClient(media_duration=18.2)
    r_provider = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("long_no_mvhd.mp4", make_mp4_bytes(duration_seconds=None), "video/mp4")},
    )
    assert r_provider.status_code == 400
    assert r_provider.json()["error"]["code"] == "media_duration_exceeded"
    assert len(e2e_fakes.storage.deleted_calls) == 1


def test_t2_f7_mime_vs_magic_byte_spoofing_rejected(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Spoof Check Stop")

    r_spoof_mp4 = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("fake.mp4", make_jpeg_bytes(), "video/mp4")},
    )
    assert r_spoof_mp4.status_code == 400
    assert r_spoof_mp4.json()["error"]["code"] == "media_type_mismatch"

    r_spoof_gif = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("fake.gif", make_mp4_bytes(duration_seconds=4.0), "image/gif")},
    )
    assert r_spoof_gif.status_code == 400
    assert r_spoof_gif.json()["error"]["code"] == "media_type_mismatch"


def test_t2_f7_empty_and_corrupt_upload_rejected(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Corrupt Upload Stop")

    r_empty = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("empty.mp4", b"", "video/mp4")},
    )
    assert r_empty.status_code == 400
    assert r_empty.json()["error"]["code"] == "empty_upload"

    r_corrupt = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=admin_headers,
        files={"file": ("junk.jpg", b"not-a-valid-image-payload", "image/jpeg")},
    )
    assert r_corrupt.status_code == 400
    assert r_corrupt.json()["error"]["code"] == "invalid_media_content"


def test_t2_f7_non_admin_upload_returns_403(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    dest = seed_destination(client, admin_headers, name="Admin Only Media Stop")

    r_media = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=user_headers,
        files={"file": ("clip.mp4", make_mp4_bytes(duration_seconds=5.0), "video/mp4")},
    )
    assert r_media.status_code == 403

    r_image = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/image",
        headers=user_headers,
        files={"file": ("photo.jpg", make_jpeg_bytes(), "image/jpeg")},
    )
    assert r_image.status_code == 403
