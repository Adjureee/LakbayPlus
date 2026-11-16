"""Commute directions: verified-only for travelers, admin CRUD, and the AI draft."""

import json

from app.features.commute.draft import parse_commute_draft
from app.integrations.groq.client import get_groq_client
from app.integrations.groq.schemas import GroqChatCompletion
from tests.test_phase5_ai_itineraries import configure_ai
from tests.test_phase6_routes import (
    DESTINATION_A,
    admin_headers,
    create_destination,
    user_headers,
)

STEPS = [
    {"vehicle": "jeepney", "from_place": "Davao City", "to_place": "Toril",
     "get_off_at": "Toril Terminal", "minutes": 25, "fare_php": "30.00",
     "charging_unit": "per_person"},
    {"vehicle": "tricycle", "from_place": "Toril Terminal", "to_place": "Park",
     "minutes": 15, "fare_php": "100.00", "charging_unit": "per_trip"},
    {"vehicle": "fee", "notes": "Pay the local community fee"},
]


def _make_place(client, admin, **extra) -> dict:
    return create_destination(client, admin, {**DESTINATION_A, **extra})


def _add(client, admin, destination_id: int, **overrides):
    body = {"start_area": "Davao City", "steps": STEPS, **overrides}
    return client.post(
        f"/api/v1/admin/destinations/{destination_id}/commute", headers=admin, json=body,
    )


def test_public_endpoint_hides_unverified_and_inactive_routes(client) -> None:
    admin = admin_headers(client)
    place = _make_place(client, admin)
    did = place["destination_id"]

    draft_route = _add(client, admin, did)
    assert draft_route.status_code == 201, draft_route.text
    assert draft_route.json()["is_verified"] is False

    public = client.get(f"/api/v1/destinations/{did}/commute")
    assert public.status_code == 200
    assert public.json()["routes"] == []

    verified = _add(client, admin, did, is_verified=True)
    body = verified.json()
    assert body["is_verified"] is True and body["verified_at"] is not None
    assert [r["commute_route_id"] for r in
            client.get(f"/api/v1/destinations/{did}/commute").json()["routes"]] == [
        body["commute_route_id"]]

    # Switching it off hides it again but keeps it for admins.
    off = client.delete(f"/api/v1/admin/commute/{body['commute_route_id']}", headers=admin)
    assert off.status_code == 200 and off.json()["is_active"] is False
    assert client.get(f"/api/v1/destinations/{did}/commute").json()["routes"] == []
    assert len(client.get(
        f"/api/v1/admin/destinations/{did}/commute", headers=admin).json()["routes"]) == 2


def test_totals_come_from_steps_and_flag_what_is_missing(client) -> None:
    admin = admin_headers(client)
    did = _make_place(client, admin)["destination_id"]
    route = _add(client, admin, did, is_verified=True).json()

    assert [s["step_order"] for s in route["steps"]] == [1, 2, 3]
    assert route["total_minutes"] == 40
    assert route["minutes_complete"] is True
    # Only the per-person fare is added; the per-trip tricycle fare and the
    # fee with no price make the total incomplete rather than guessed.
    assert float(route["total_fare_per_person_php"]) == 30.0
    assert route["fare_complete"] is False
    assert route["transfers"] == 1

    unknown = _add(client, admin, did, steps=[{"vehicle": "van"}]).json()
    assert unknown["total_minutes"] == 0
    assert unknown["minutes_complete"] is False
    assert unknown["fare_complete"] is False


def test_replace_steps_and_unverify(client) -> None:
    admin = admin_headers(client)
    did = _make_place(client, admin)["destination_id"]
    route = _add(client, admin, did, is_verified=True).json()

    updated = client.put(
        f"/api/v1/admin/commute/{route['commute_route_id']}", headers=admin,
        json={"start_area": "Toril", "is_verified": False,
              "steps": [{"vehicle": "bus", "minutes": 60, "fare_php": "90",
                         "charging_unit": "per_person"}]},
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()
    assert [s["vehicle"] for s in data["steps"]] == ["bus"]
    assert data["is_verified"] is False and data["verified_at"] is None
    assert client.get(f"/api/v1/destinations/{did}/commute").json()["routes"] == []


def test_validation_and_permissions(client) -> None:
    admin = admin_headers(client)
    traveler = user_headers(client)
    did = _make_place(client, admin)["destination_id"]

    assert _add(client, traveler, did).status_code == 403
    assert client.get(f"/api/v1/admin/destinations/{did}/commute", headers=traveler).status_code == 403
    assert _add(client, admin, did, steps=[]).status_code == 422
    assert _add(client, admin, did, steps=[{"vehicle": "rocket"}]).status_code == 422
    assert _add(client, admin, did, steps=[{"vehicle": "bus", "minutes": -1}]).status_code == 422
    assert _add(client, admin, did, source_url="ftp://x").status_code == 422
    assert _add(client, admin, 99999).status_code == 404
    assert client.get("/api/v1/destinations/99999/commute").status_code == 404
    assert client.put("/api/v1/admin/commute/99999", headers=admin,
                      json={"steps": [{"vehicle": "bus"}]}).status_code == 404


class FakeDraftGroq:
    def __init__(self, content: str) -> None:
        self.content = content
        self.messages: list = []

    async def create_chat_completion(self, *, model, messages, response_format=None,
                                     provider="groq", temperature=None, max_tokens=None,
                                     max_rate_limit_wait_seconds=None):
        self.messages = messages
        return GroqChatCompletion(content=self.content, model=model,
                                  prompt_tokens=1, completion_tokens=1, total_tokens=2)


def test_draft_is_unverified_unsaved_and_reports_what_is_unclear(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    did = _make_place(
        client, admin, how_to_get_there="Ride a jeepney to Toril then a tricycle.",
    )["destination_id"]
    fake = FakeDraftGroq(json.dumps({
        "routes": [{"start_area": "Davao City", "is_verified": True, "steps": [
            {"vehicle": "Jeepney", "minutes": None, "fare_php": None, "charging_unit": None},
            {"vehicle": "habal-habal"},
            {"vehicle": "hovercraft"},
        ]}],
        "unclear": ["No fares were given."],
    }))
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = client.post(
        f"/api/v1/admin/destinations/{did}/commute/draft", headers=admin, json={})
    assert response.status_code == 200, response.text
    body = response.json()
    route = body["routes"][0]
    assert route["is_verified"] is False
    assert [s["vehicle"] for s in route["steps"]] == ["jeepney", "habal_habal"]
    assert any("hovercraft" in item for item in body["unclear"])
    assert "No fares were given." in body["unclear"]
    # Nothing was saved.
    assert client.get(f"/api/v1/admin/destinations/{did}/commute",
                      headers=admin).json()["routes"] == []


def test_draft_needs_notes_and_an_admin(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    traveler = user_headers(client)
    did = _make_place(client, admin)["destination_id"]
    client.app.dependency_overrides[get_groq_client] = lambda: FakeDraftGroq("{}")

    assert client.post(f"/api/v1/admin/destinations/{did}/commute/draft",
                       headers=traveler, json={}).status_code == 403
    assert client.post(f"/api/v1/admin/destinations/{did}/commute/draft",
                       headers=admin, json={}).status_code == 400


def test_draft_with_unreadable_answer_fails_cleanly(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    did = _make_place(client, admin, how_to_get_there="Take a van.")["destination_id"]
    client.app.dependency_overrides[get_groq_client] = lambda: FakeDraftGroq("not json")
    response = client.post(
        f"/api/v1/admin/destinations/{did}/commute/draft", headers=admin, json={})
    assert response.status_code == 502


def test_parse_commute_draft_rejects_non_routes() -> None:
    assert parse_commute_draft("[]") is None
    assert parse_commute_draft('{"routes": "x"}') is None
    routes, unclear = parse_commute_draft('```json\n{"routes": [{"steps": []}]}\n```')
    assert routes == [] and unclear
