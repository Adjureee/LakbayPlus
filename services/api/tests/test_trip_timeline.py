"""Saved itinerary timelines: server-built revisions, history and permissions."""

from app.features.trips import timeline_service
from tests.invites import join_trip
from tests.test_phase7_trips import (
    DESTINATION_A,
    DESTINATION_B,
    admin_headers,
    create_destination,
    create_trip,
    user_headers,
)

ORIGIN = {"label": "Davao City", "lat": 7.07, "lng": 125.6}


def _setup(client):
    admin = admin_headers(client)
    a = create_destination(client, admin, DESTINATION_A)["destination_id"]
    b = create_destination(client, admin, DESTINATION_B)["destination_id"]
    owner = user_headers(client, email="timeline-owner@example.com")
    trip = create_trip(client, owner, [a, b])
    return owner, trip["trip_id"], a, b


def _state(a, b, **extra):
    return {"destination_ids": [a, b], "day_count": 2, "traveler_count": 2,
            "departure_time": "08:00:00", "origin": ORIGIN, **extra}


def _save(client, headers, trip_id, state, **extra):
    return client.post(f"/api/v1/trips/{trip_id}/timeline", headers=headers,
                       json={"state": state, **extra})


# --- saving and reading -----------------------------------------------------------------


def test_the_server_builds_and_stores_the_first_revision(client) -> None:
    owner, trip_id, a, b = _setup(client)
    response = _save(client, owner, trip_id, _state(a, b))
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["revision"] == 1 and body["changes"] == []
    visits = [i for d in body["timeline"]["days"] for i in d["items"] if i["kind"] == "visit"]
    assert [v["destination_id"] for v in visits] == [a, b]  # built from the picks, in order
    assert body["state"]["day_count"] == 2

    history = client.get(f"/api/v1/trips/{trip_id}/timeline", headers=owner).json()
    assert history["latest"]["revision"] == 1
    assert [r["revision"] for r in history["revisions"]] == [1]


def test_a_second_save_is_the_next_revision_and_says_what_moved(client) -> None:
    owner, trip_id, a, b = _setup(client)
    _save(client, owner, trip_id, _state(a, b))
    second = _save(client, owner, trip_id, _state(a, b, departure_time="10:00:00")).json()
    assert second["revision"] == 2
    assert any("now starts at" in c for c in second["changes"])

    history = client.get(f"/api/v1/trips/{trip_id}/timeline", headers=owner).json()
    assert [r["revision"] for r in history["revisions"]] == [2, 1]  # newest first
    assert history["latest"]["revision"] == 2
    first = client.get(f"/api/v1/trips/{trip_id}/timeline/revisions/1", headers=owner)
    assert first.status_code == 200 and first.json()["changes"] == []
    # An old revision is kept as it was: it still holds the earlier start.
    assert first.json()["state"]["departure_time"] == "08:00:00"


def test_a_trip_with_no_saved_timeline_has_an_empty_history(client) -> None:
    owner, trip_id, _, _ = _setup(client)
    history = client.get(f"/api/v1/trips/{trip_id}/timeline", headers=owner).json()
    assert history == {"latest": None, "revisions": []}
    assert client.get(f"/api/v1/trips/{trip_id}/timeline/revisions/1",
                      headers=owner).status_code == 404


def test_bad_input_is_refused_and_a_client_cannot_send_a_finished_timeline(client) -> None:
    owner, trip_id, a, b = _setup(client)
    assert _save(client, owner, trip_id, {"day_count": 0}).status_code == 422
    # A timeline in the body is ignored: the server always rebuilds from the state.
    forged = _save(client, owner, trip_id, _state(a, b),
                   timeline={"days": [], "feasible": True}).json()
    assert forged["timeline"]["days"], "the stored timeline was built by the server"


# --- permissions ------------------------------------------------------------------------


def test_only_signed_in_members_can_read_and_only_managers_can_save(client) -> None:
    owner, trip_id, a, b = _setup(client)
    _save(client, owner, trip_id, _state(a, b))
    url = f"/api/v1/trips/{trip_id}/timeline"

    assert client.get(url).status_code in {401, 403}
    assert client.post(url, json={"state": {}}).status_code in {401, 403}

    outsider = user_headers(client, email="timeline-outsider@example.com")
    assert client.get(url, headers=outsider).status_code == 404  # not their trip
    assert _save(client, outsider, trip_id, _state(a, b)).status_code == 404

    user_headers(client, email="timeline-member@example.com")
    join_trip(client, headers=owner, trip_id=trip_id, email="timeline-member@example.com")
    from tests.invites import login_headers
    member = login_headers(client, "timeline-member@example.com")
    assert client.get(url, headers=member).status_code == 200  # a member may read
    denied = _save(client, member, trip_id, _state(a, b))
    assert denied.status_code == 403 and denied.json()["error"]["code"] == "trip_permission_denied"

    user_headers(client, email="timeline-organizer@example.com")
    join_trip(client, headers=owner, trip_id=trip_id,
              email="timeline-organizer@example.com", role="organizer")
    organizer = login_headers(client, "timeline-organizer@example.com")
    saved = _save(client, organizer, trip_id, _state(a, b, day_count=3))
    assert saved.status_code == 201
    assert saved.json()["created_by_user_id"] is not None


def test_an_archived_trip_keeps_its_history_but_takes_no_new_revisions(client) -> None:
    owner, trip_id, a, b = _setup(client)
    _save(client, owner, trip_id, _state(a, b))
    assert client.delete(f"/api/v1/trips/{trip_id}", headers=owner).status_code == 200  # archives
    history = client.get(f"/api/v1/trips/{trip_id}/timeline", headers=owner)
    assert history.status_code == 200 and history.json()["latest"]["revision"] == 1
    refused = _save(client, owner, trip_id, _state(a, b))
    assert refused.status_code == 400
    assert refused.json()["error"]["code"] == "trip_archived_read_only"


# --- the cap ----------------------------------------------------------------------------


def test_only_the_newest_revisions_are_kept(client, monkeypatch) -> None:
    monkeypatch.setattr(timeline_service, "MAX_REVISIONS", 3)
    owner, trip_id, a, b = _setup(client)
    for hour in range(8, 13):
        _save(client, owner, trip_id, _state(a, b, departure_time=f"{hour:02d}:00:00"))
    history = client.get(f"/api/v1/trips/{trip_id}/timeline", headers=owner).json()
    assert [r["revision"] for r in history["revisions"]] == [5, 4, 3]
    assert client.get(f"/api/v1/trips/{trip_id}/timeline/revisions/1",
                      headers=owner).status_code == 404
