import itertools
import json
import struct
from typing import Any

from app.features.routes.polyline import encode_polyline5

_EMAIL_SEQ = itertools.count(1)
_NAME_SEQ = itertools.count(1)


def unique_email(prefix: str = "user") -> str:
    return f"{prefix}-{next(_EMAIL_SEQ)}@example.com"


def unique_name(prefix: str = "Item") -> str:
    return f"{prefix} {next(_NAME_SEQ)}"


def register_user(
    client,
    *,
    full_name: str = "Davao Traveler",
    email: str | None = None,
    password: str = "password123",
) -> tuple[dict[str, str], dict[str, Any]]:
    addr = email or unique_email("traveler")
    response = client.post(
        "/api/v1/auth/register",
        json={
            "full_name": full_name,
            "email": addr,
            "password": password,
            "confirm_password": password,
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    headers = {"Authorization": f"Bearer {body['tokens']['access_token']}"}
    return headers, body["user"]


def register_admin(
    client,
    *,
    full_name: str = "Davao Admin",
    email: str | None = None,
    password: str = "password123",
    admin_code: str = "admin-test-code",
) -> tuple[dict[str, str], dict[str, Any]]:
    addr = email or unique_email("admin")
    response = client.post(
        "/api/v1/auth/register/admin",
        json={
            "full_name": full_name,
            "email": addr,
            "password": password,
            "confirm_password": password,
            "admin_registration_code": admin_code,
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    headers = {"Authorization": f"Bearer {body['tokens']['access_token']}"}
    return headers, body["user"]


def seed_destination(
    client,
    admin_headers: dict[str, str],
    *,
    name: str | None = None,
    lat: float = 7.0644,
    lng: float = 125.6078,
    district: str = "Davao City",
    location: str = "Davao City",
    category: str = "park",
    vibes: str = "relaxed",
    activities: str = "sightseeing, walking",
    estimated_cost: str = "150.00",
    budget_class: str = "budget",
    difficulty_level: str = "easy",
    stay_duration_type: str = "short",
    island_group: str | None = None,
    **overrides: Any,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": name or unique_name("Davao Stop"),
        "description": "Curated Davao Region destination for E2E verification.",
        "district": district,
        "location": location,
        "category": category,
        "vibes": vibes,
        "activities": activities,
        "lat": lat,
        "lng": lng,
        "estimated_cost": estimated_cost,
        "budget_class": budget_class,
        "difficulty_level": difficulty_level,
        "stay_duration_type": stay_duration_type,
    }
    if island_group is not None:
        payload["island_group"] = island_group
    payload.update(overrides)
    response = client.post("/api/v1/destinations", headers=admin_headers, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def enrich_destination_d6(
    client,
    admin_headers: dict[str, str],
    destination_id: int,
    *,
    image_credit: str = "Davao Tourism Archive",
    image_license: str = "CC-BY-4.0",
    image_source_url: str = "https://commons.wikimedia.org/wiki/File:Davao_Example.jpg",
) -> dict[str, Any]:
    patch_resp = client.patch(
        f"/api/v1/destinations/{destination_id}",
        headers=admin_headers,
        json={
            "image_credit": image_credit,
            "image_license": image_license,
            "image_source_url": image_source_url,
            "operating_status": "open",
        },
    )
    assert patch_resp.status_code == 200, patch_resp.text

    hours_resp = client.put(
        f"/api/v1/destinations/{destination_id}/hours",
        headers=admin_headers,
        json={
            "open_24_hours": False,
            "hours_source_url": "https://davaotourism.example.org/hours",
            "hours_verified_at": "2026-11-01T08:00:00Z",
            "weekly": [
                {"weekday": day, "is_closed": False, "opens_at": "08:00:00", "closes_at": "17:00:00"}
                for day in range(7)
            ],
            "exceptions": [],
        },
    )
    assert hours_resp.status_code == 200, hours_resp.text

    prices_resp = client.put(
        f"/api/v1/destinations/{destination_id}/prices",
        headers=admin_headers,
        json={
            "fees_source_url": "https://davaotourism.example.org/rates",
            "fees_verified_at": "2026-11-01T08:00:00Z",
            "prices": [
                {"item": "entrance", "audience": "adult", "amount": "150.00", "unit": "per_person"},
                {"item": "parking", "audience": "everyone", "amount": "50.00", "unit": "per_vehicle"},
            ],
        },
    )
    assert prices_resp.status_code == 200, prices_resp.text

    act_resp = client.put(
        f"/api/v1/destinations/{destination_id}/activities",
        headers=admin_headers,
        json={
            "activities": [
                {
                    "name": "Guided Canopy Walk",
                    "description": "Guided nature trail walk.",
                    "availability": "always",
                    "duration_min_minutes": 45,
                    "duration_max_minutes": 90,
                    "extra_fee": "0.00",
                    "fee_included_in_admission": True,
                    "effort_level": "easy",
                    "source_url": "https://davaotourism.example.org/activities",
                    "verified_at": "2026-11-01T08:00:00Z",
                }
            ]
        },
    )
    assert act_resp.status_code == 200, act_resp.text

    return {
        "destination": patch_resp.json(),
        "hours": hours_resp.json(),
        "prices": prices_resp.json(),
        "activities": act_resp.json(),
    }


def seed_sea_port(
    client,
    admin_headers: dict[str, str],
    *,
    name: str | None = None,
    lat: float,
    lng: float,
    island_group: str,
    province: str = "Davao City",
) -> dict[str, Any]:
    response = client.post(
        "/api/v1/admin/sea-ports",
        headers=admin_headers,
        json={
            "name": name or unique_name("Pier"),
            "lat": lat,
            "lng": lng,
            "island_group": island_group,
            "province": province,
            "source_url": "https://osm.org/node/1001",
            "verified": True,
            "is_active": True,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def seed_sea_link(
    client,
    admin_headers: dict[str, str],
    *,
    from_port: dict[str, Any],
    to_port: dict[str, Any],
    vessel_type: str = "roro_barge",
    allows_private_vehicle: bool = True,
    crossing_minutes: int = 18,
    typical_wait_minutes: int = 10,
) -> dict[str, Any]:
    polyline = encode_polyline5(
        [(from_port["lat"], from_port["lng"]), (to_port["lat"], to_port["lng"])]
    )
    response = client.post(
        "/api/v1/admin/sea-links",
        headers=admin_headers,
        json={
            "from_port_id": from_port["port_id"],
            "to_port_id": to_port["port_id"],
            "bidirectional": True,
            "vessel_type": vessel_type,
            "allows_private_vehicle": allows_private_vehicle,
            "crossing_minutes": crossing_minutes,
            "typical_wait_minutes": typical_wait_minutes,
            "fare_passenger": "35.00",
            "fare_vehicle": "250.00" if allows_private_vehicle else None,
            "geometry_polyline": polyline,
            "source_url": "https://osm.org/way/2001",
            "verified": True,
            "is_active": True,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def seed_davao_samal_network(client, admin_headers: dict[str, str]) -> dict[str, Any]:
    sasa_wharf = seed_sea_port(
        client,
        admin_headers,
        name=unique_name("Davao Sasa Wharf"),
        lat=7.1140,
        lng=125.6610,
        island_group="mainland",
        province="Davao City",
    )
    babak_pier = seed_sea_port(
        client,
        admin_headers,
        name=unique_name("Samal Babak Pier"),
        lat=7.1180,
        lng=125.6940,
        island_group="samal",
        province="Davao del Norte",
    )
    link = seed_sea_link(
        client,
        admin_headers,
        from_port=sasa_wharf,
        to_port=babak_pier,
    )
    return {"mainland_port": sasa_wharf, "samal_port": babak_pier, "link": link}


def seed_trip(
    client,
    user_headers: dict[str, str],
    destination_ids: list[int],
    *,
    title: str = "Davao Weekend Trip",
    start_date: str = "2026-10-10",
    end_date: str = "2026-10-11",
    traveler_count: int = 2,
    total_budget: str = "10000.00",
    estimated_total_cost: str = "3500.00",
    notes: str = "Keep the pace relaxed.",
) -> dict[str, Any]:
    response = client.post(
        "/api/v1/trips",
        headers=user_headers,
        json={
            "title": title,
            "description": "E2E trip itinerary.",
            "start_date": start_date,
            "end_date": end_date,
            "traveler_count": traveler_count,
            "total_budget": total_budget,
            "estimated_total_cost": estimated_total_cost,
            "destination_ids": destination_ids,
            "notes": notes,
            "itinerary_days": [
                {
                    "day_number": 1,
                    "title": "Day 1",
                    "summary": "Explore Davao stop.",
                    "activities": [
                        {
                            "activity_order": 1,
                            "time": "09:00",
                            "title": "Visit stop",
                            "description": "Explore the selected destination.",
                            "destination_id": destination_ids[0],
                            "estimated_cost": "500.00",
                            "notes": "Bring water.",
                        }
                    ],
                }
            ],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def build_valid_itinerary_json(
    *,
    destination_ids: list[int],
    day_count: int = 2,
    option_count: int = 2,
) -> str:
    options = []
    for option_number in range(1, option_count + 1):
        day_groups: list[list[int]] = [[] for _ in range(day_count)]
        if len(destination_ids) <= day_count:
            for day_idx in range(day_count):
                stop_idx = min(
                    len(destination_ids) - 1,
                    (day_idx * len(destination_ids)) // day_count,
                )
                day_groups[day_idx].append(destination_ids[stop_idx])
        else:
            for stop_idx, dest_id in enumerate(destination_ids):
                day_idx = min(
                    day_count - 1,
                    (stop_idx * day_count) // len(destination_ids),
                )
                day_groups[day_idx].append(dest_id)

        days = []
        total_activities = 0
        for day, day_dests in enumerate(day_groups, start=1):
            activities = []
            for act_idx, dest_id in enumerate(day_dests):
                total_activities += 1
                hour = 8 + (act_idx * 3)
                activities.append(
                    {
                        "time": f"{hour:02d}:30",
                        "title": f"Visit stop {dest_id}",
                        "description": "Guided visit at catalog stop.",
                        "destination_id": dest_id,
                        "estimated_cost": "500.00",
                        "notes": "Arrive early.",
                    }
                )
            days.append(
                {
                    "day": day,
                    "title": f"Day {day}",
                    "summary": f"Explore destination {day_dests[0]}.",
                    "activities": activities,
                }
            )
        options.append(
            {
                "option_number": option_number,
                "title": f"Davao Plan Option {option_number}",
                "summary": "Balanced catalog-grounded Davao Region itinerary.",
                "estimated_total_cost": f"{500 * total_activities:.2f}",
                "is_over_budget": False,
                "days": days,
            }
        )
    return json.dumps({"options": options})


# ---------------------------------------------------------------------------
# Binary Media Fixture Generators
# ---------------------------------------------------------------------------

def make_jpeg_bytes(extra: bytes = b"destination-photo") -> bytes:
    return b"\xff\xd8\xff\xe0" + extra


def make_png_bytes(extra: bytes = b"\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00") -> bytes:
    return b"\x89PNG\r\n\x1a\n" + extra


def make_webp_bytes(extra: bytes = b"VP8 ") -> bytes:
    return b"RIFF\x00\x00\x00\x00WEBP" + extra


def make_gif89a_bytes() -> bytes:
    return (
        b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff"
        b"!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
    )


def make_mp4_bytes(duration_seconds: float | None = 5.0, timescale: int = 1000) -> bytes:
    ftyp = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom"
    if duration_seconds is None:
        return ftyp
    duration_units = int(round(duration_seconds * timescale))
    mvhd_payload = (
        struct.pack(">IIII", 0, 0, 0, timescale)
        + struct.pack(">I", duration_units)
        + (b"\x00" * 80)
    )
    mvhd_box = struct.pack(">I4s", 8 + len(mvhd_payload), b"mvhd") + mvhd_payload
    moov_box = struct.pack(">I4s", 8 + len(mvhd_box), b"moov") + mvhd_box
    return ftyp + moov_box


def _ebml_vint_size(length: int) -> bytes:
    if length < 127:
        return bytes([0x80 | length])
    if length < 16383:
        val = 0x4000 | length
        return val.to_bytes(2, "big")
    val = 0x200000 | length
    return val.to_bytes(3, "big")


def make_webm_bytes(duration_ms: float | None = 5000.0) -> bytes:
    if duration_ms is None:
        return b"\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01"
    header = b"\x1a\x45\xdf\xa3\x84\x42\x86\x81\x01"
    ts_payload = (1_000_000).to_bytes(3, "big")
    ts_elem = b"\x2a\xd7\xb1" + _ebml_vint_size(len(ts_payload)) + ts_payload
    dur_payload = struct.pack(">d", duration_ms)
    dur_elem = b"\x44\x89" + _ebml_vint_size(len(dur_payload)) + dur_payload
    info_payload = ts_elem + dur_elem
    info_elem = b"\x15\x49\xa9\x66" + _ebml_vint_size(len(info_payload)) + info_payload
    # Segment VINT size MUST cover len(info_elem) (full Info element including tag+size).
    seg_elem = b"\x18\x53\x80\x67" + _ebml_vint_size(len(info_elem)) + info_elem
    return header + seg_elem
