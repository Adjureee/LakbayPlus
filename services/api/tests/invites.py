"""Test helper: invite a registered traveler to a trip and have them accept.

Inviting no longer adds someone straight away (they join when they accept), so
tests about shared trips use this to get an active member.
"""


def login_headers(client, email: str, password: str = "password123") -> dict[str, str]:
    response = client.post("/api/v1/auth/login", json={"email": email, "password": password})
    assert response.status_code == 200, response.json()
    return {"Authorization": f"Bearer {response.json()['tokens']['access_token']}"}


def join_trip(
    client,
    *,
    headers: dict[str, str],
    trip_id: int,
    email: str,
    role: str = "member",
) -> dict:
    """Invite by email, accept as the invitee, and return the active member."""
    invited = client.post(
        f"/api/v1/trips/{trip_id}/members",
        headers=headers,
        json={"email": email, "role": role},
    )
    assert invited.status_code == 201, invited.json()
    assert invited.json()["status"] == "invited"

    accepted = client.post(
        f"/api/v1/trips/{trip_id}/invitation/accept", headers=login_headers(client, email),
    )
    assert accepted.status_code == 200, accepted.json()
    return accepted.json()
