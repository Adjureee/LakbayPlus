from tests.invites import login_headers
from tests.test_phase8_group_collaboration import create_trip, register_user


def _me(client, headers) -> dict:
    response = client.get("/api/v1/users/me", headers=headers)
    assert response.status_code == 200
    return response.json()


def _events(client, headers) -> list[str]:
    return [n["event_type"] for n in client.get("/api/v1/notifications", headers=headers).json()]


def _invite(client, headers, trip_id, **who):
    return client.post(
        f"/api/v1/trips/{trip_id}/members", headers=headers, json={**who, "role": "member"},
    )


def test_new_accounts_get_a_username(client) -> None:
    headers = register_user(client, email="maria.santos@example.com")
    username = _me(client, headers)["username"]
    assert username and 3 <= len(username) <= 30
    assert username == username.lower()


def test_username_can_be_changed_but_not_taken_or_invalid(client) -> None:
    first = register_user(client, email="first-user@example.com")
    second = register_user(client, email="second-user@example.com")

    changed = client.patch("/api/v1/users/me", headers=first, json={"username": "@Trail_Walker"})
    assert changed.status_code == 200
    assert changed.json()["username"] == "trail_walker"

    taken = client.patch("/api/v1/users/me", headers=second, json={"username": "TRAIL_WALKER"})
    assert taken.status_code == 409
    assert taken.json()["error"]["code"] == "username_taken"

    for bad in ("ab", "has space", "x" * 31, "emoji😀name"):
        assert client.patch(
            "/api/v1/users/me", headers=second, json={"username": bad},
        ).status_code == 422


def test_search_finds_by_username_or_name_and_never_shows_emails(client) -> None:
    searcher = register_user(client, email="searcher@example.com")
    target = register_user(client, email="private.email@example.com")
    client.patch("/api/v1/users/me", headers=target, json={"username": "trailfriend"})

    by_username = client.get("/api/v1/users/search", headers=searcher, params={"q": "@trailf"})
    assert by_username.status_code == 200
    assert [item["username"] for item in by_username.json()] == ["trailfriend"]
    assert "email" not in by_username.json()[0]
    assert "private.email" not in by_username.text

    # Searching an email finds nothing: emails cannot be looked up.
    assert client.get(
        "/api/v1/users/search", headers=searcher, params={"q": "private.email@example.com"},
    ).json() == []
    # Too short, and the caller is never listed.
    assert client.get("/api/v1/users/search", headers=searcher, params={"q": "t"}).json() == []
    own = _me(client, searcher)["username"]
    assert all(
        item["username"] != own
        for item in client.get(
            "/api/v1/users/search", headers=searcher, params={"q": own[:3]},
        ).json()
    )
    assert client.get("/api/v1/users/search").status_code == 401


def test_invite_by_username_notifies_and_does_not_add_until_accepted(client) -> None:
    owner = register_user(client, email="invite-owner@example.com")
    invitee = register_user(client, email="invite-friend@example.com")
    client.patch("/api/v1/users/me", headers=invitee, json={"username": "inviteefriend"})
    trip = create_trip(client, owner)
    trip_id = trip["trip_id"]

    invited = _invite(client, owner, trip_id, username="InviteeFriend")
    assert invited.status_code == 201
    body = invited.json()
    assert body["status"] == "invited"
    assert body["email"] is None  # not revealed by inviting through a username
    assert body["username"] == "inviteefriend"

    # Not a member yet: no access to the trip, but the invitation and a notification exist.
    assert client.get(f"/api/v1/trips/{trip_id}", headers=invitee).status_code == 404
    pending = client.get("/api/v1/trips/invitations", headers=invitee)
    assert [(i["trip_id"], i["trip_title"]) for i in pending.json()] == [
        (trip_id, trip["title"])
    ]
    assert _events(client, invitee) == ["trip_invitation"]
    assert _events(client, owner) == []

    # The owner sees the pending invitation; the invitee is not in the member list yet.
    listed = client.get(f"/api/v1/trips/{trip_id}/members", headers=owner).json()
    assert {(m["role"], m["status"]) for m in listed} == {("owner", "active"), ("member", "invited")}

    accepted = client.post(f"/api/v1/trips/{trip_id}/invitation/accept", headers=invitee)
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "active"
    assert client.get(f"/api/v1/trips/{trip_id}", headers=invitee).status_code == 200
    assert client.get("/api/v1/trips/invitations", headers=invitee).json() == []
    assert _events(client, owner) == ["trip_invitation_accepted"]


def test_invite_by_email_works_the_same_way(client) -> None:
    owner = register_user(client, email="email-invite-owner@example.com")
    register_user(client, email="email-invitee@example.com")
    trip = create_trip(client, owner)

    invited = _invite(client, owner, trip["trip_id"], email="Email-Invitee@Example.com")
    assert invited.status_code == 201 and invited.json()["status"] == "invited"
    assert _events(client, login_headers(client, "email-invitee@example.com")) == ["trip_invitation"]


def test_declining_removes_the_invitation_and_tells_the_owner(client) -> None:
    owner = register_user(client, email="decline-owner@example.com")
    invitee = register_user(client, email="decline-friend@example.com")
    trip = create_trip(client, owner)
    trip_id = trip["trip_id"]
    _invite(client, owner, trip_id, email="decline-friend@example.com")

    declined = client.post(f"/api/v1/trips/{trip_id}/invitation/decline", headers=invitee)
    assert declined.status_code == 204
    assert client.get(f"/api/v1/trips/{trip_id}", headers=invitee).status_code == 404
    assert _events(client, owner) == ["trip_invitation_declined"]

    # Answering twice is refused, and they can be invited again.
    again = client.post(f"/api/v1/trips/{trip_id}/invitation/accept", headers=invitee)
    assert again.status_code == 404
    assert again.json()["error"]["code"] == "invitation_not_found"
    assert _invite(client, owner, trip_id, email="decline-friend@example.com").status_code == 201


def test_only_the_invited_person_can_answer(client) -> None:
    owner = register_user(client, email="answer-owner@example.com")
    register_user(client, email="answer-invitee@example.com")
    outsider = register_user(client, email="answer-outsider@example.com")
    trip = create_trip(client, owner)
    _invite(client, owner, trip["trip_id"], email="answer-invitee@example.com")

    for action in ("accept", "decline"):
        response = client.post(
            f"/api/v1/trips/{trip['trip_id']}/invitation/{action}", headers=outsider,
        )
        assert response.status_code == 404
    assert client.get(f"/api/v1/trips/{trip['trip_id']}/members", headers=outsider).status_code == 404


def test_unknown_people_get_one_neutral_answer(client) -> None:
    owner = register_user(client, email="neutral-owner@example.com")
    trip = create_trip(client, owner)

    by_email = _invite(client, owner, trip["trip_id"], email="nobody-here@example.com")
    by_username = _invite(client, owner, trip["trip_id"], username="nobody_here")
    for response in (by_email, by_username):
        assert response.status_code == 404
        assert response.json()["error"]["code"] == "invitee_not_found"
        assert response.json()["error"]["message"] == "We couldn't find that person."


def test_invite_needs_exactly_one_way_to_find_the_person(client) -> None:
    owner = register_user(client, email="exactly-owner@example.com")
    trip = create_trip(client, owner)
    path = f"/api/v1/trips/{trip['trip_id']}/members"

    assert client.post(path, headers=owner, json={"role": "member"}).status_code == 422
    both = client.post(
        path, headers=owner, json={"email": "a@example.com", "username": "someone"},
    )
    assert both.status_code == 422


def test_duplicate_and_self_invites_are_refused(client) -> None:
    owner = register_user(client, email="dup-invite-owner@example.com")
    register_user(client, email="dup-invitee@example.com")
    trip = create_trip(client, owner)
    trip_id = trip["trip_id"]

    assert _invite(client, owner, trip_id, email="dup-invitee@example.com").status_code == 201
    again = _invite(client, owner, trip_id, email="dup-invitee@example.com")
    assert again.status_code == 400
    assert again.json()["error"]["code"] == "trip_invitation_pending"

    own = _invite(client, owner, trip_id, username=_me(client, owner)["username"])
    assert own.status_code == 400
    assert own.json()["error"]["code"] == "trip_member_already_exists"


def test_a_pending_invitation_can_be_cancelled(client) -> None:
    owner = register_user(client, email="cancel-owner@example.com")
    invitee = register_user(client, email="cancel-invitee@example.com")
    trip = create_trip(client, owner)
    invited = _invite(client, owner, trip["trip_id"], email="cancel-invitee@example.com").json()

    cancelled = client.delete(
        f"/api/v1/trips/{trip['trip_id']}/members/{invited['trip_member_id']}", headers=owner,
    )
    assert cancelled.status_code in (200, 204)
    assert client.get("/api/v1/trips/invitations", headers=invitee).json() == []


def test_invited_people_do_not_see_other_pending_invitations(client) -> None:
    owner = register_user(client, email="privacy-owner@example.com")
    register_user(client, email="privacy-invitee@example.com")
    member = register_user(client, email="privacy-member@example.com")
    trip = create_trip(client, owner)
    trip_id = trip["trip_id"]
    _invite(client, owner, trip_id, email="privacy-member@example.com")
    client.post(f"/api/v1/trips/{trip_id}/invitation/accept", headers=member)
    _invite(client, owner, trip_id, email="privacy-invitee@example.com")

    # A plain member sees active members only, not who is still pending.
    seen = client.get(f"/api/v1/trips/{trip_id}/members", headers=member).json()
    assert {m["status"] for m in seen} == {"active"}
