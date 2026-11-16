from app.integrations.push import (
    reset_fcm_sender_for_test,
    set_fcm_sender_for_test,
)
from tests.test_phase8_group_collaboration import create_trip, register_user


def _me(client, headers) -> dict:
    response = client.get("/api/v1/users/me", headers=headers)
    assert response.status_code == 200
    return response.json()


def test_resend_pending_invitation_creates_fresh_notification(client) -> None:
    owner_headers = register_user(client, email="resend-owner@example.com")
    invitee_headers = register_user(client, email="resend-invitee@example.com")
    assert (
        client.patch(
            "/api/v1/users/me",
            headers=invitee_headers,
            json={"username": "resendfriend"},
        ).status_code
        == 200
    )
    trip = create_trip(client, owner_headers)
    trip_id = trip["trip_id"]

    invite_res = client.post(
        f"/api/v1/trips/{trip_id}/members",
        headers=owner_headers,
        json={"username": "resendfriend", "role": "member"},
    )
    assert invite_res.status_code == 201
    member_id = invite_res.json()["trip_member_id"]

    # Invitee marks first notification read
    notifs = client.get("/api/v1/notifications", headers=invitee_headers).json()
    assert len(notifs) == 1
    client.patch(
        f"/api/v1/notifications/{notifs[0]['notification_id']}/read",
        headers=invitee_headers,
    )
    assert (
        client.get("/api/v1/notifications/unread-count", headers=invitee_headers)
        .json()["unread_count"]
        == 0
    )

    # Owner resends pending invitation
    resend_res = client.post(
        f"/api/v1/trips/{trip_id}/members/{member_id}/resend",
        headers=owner_headers,
    )
    assert resend_res.status_code == 200
    assert resend_res.json()["status"] == "invited"

    unread = client.get(
        "/api/v1/notifications/unread-count", headers=invitee_headers
    ).json()
    assert unread["unread_count"] == 1

    # Accepting makes resending fail cleanly with 400
    accept_res = client.post(
        f"/api/v1/trips/{trip_id}/invitation/accept",
        headers=invitee_headers,
    )
    assert accept_res.status_code == 200
    second_resend = client.post(
        f"/api/v1/trips/{trip_id}/members/{member_id}/resend",
        headers=owner_headers,
    )
    assert second_resend.status_code == 400
    assert second_resend.json()["error"]["code"] == "trip_invitation_not_pending"


def test_device_token_registration_and_fcm_dispatch(client) -> None:
    owner_headers = register_user(client, email="fcm-owner@example.com")
    invitee_headers = register_user(client, email="fcm-invitee@example.com")
    assert (
        client.patch(
            "/api/v1/users/me",
            headers=invitee_headers,
            json={"username": "fcmfriend"},
        ).status_code
        == 200
    )
    invitee = _me(client, invitee_headers)
    trip = create_trip(client, owner_headers)
    trip_id = trip["trip_id"]

    reg_res = client.post(
        "/api/v1/notifications/device-tokens",
        headers=invitee_headers,
        json={"device_token": "fcm_tok_android_12345", "platform": "android"},
    )
    assert reg_res.status_code == 200
    assert reg_res.json()["is_active"] is True
    assert reg_res.json()["user_id"] == invitee["user_id"]

    # Upsert idempotently
    reg_again = client.post(
        "/api/v1/notifications/device-tokens",
        headers=invitee_headers,
        json={"device_token": "fcm_tok_android_12345", "platform": "android"},
    )
    assert reg_again.status_code == 200

    dispatched: list[tuple[str, dict]] = []

    async def fake_sender(token: str, payload: dict) -> bool:
        dispatched.append((token, payload))
        return True

    set_fcm_sender_for_test(fake_sender)
    try:
        invite_res = client.post(
            f"/api/v1/trips/{trip_id}/members",
            headers=owner_headers,
            json={"username": "fcmfriend", "role": "member"},
        )
        assert invite_res.status_code == 201
        assert len(dispatched) == 1
        token, payload = dispatched[0]
        assert token == "fcm_tok_android_12345"
        assert payload["data"]["event_type"] == "trip_invitation"
        assert payload["data"]["trip_id"] == str(trip_id)

        # Deactivating token stops further pushes
        del_res = client.delete(
            "/api/v1/notifications/device-tokens",
            headers=invitee_headers,
            params={"device_token": "fcm_tok_android_12345"},
        )
        assert del_res.status_code == 200
        assert del_res.json()["deactivated"] == 1

        member_id = invite_res.json()["trip_member_id"]
        resend_res = client.post(
            f"/api/v1/trips/{trip_id}/members/{member_id}/resend",
            headers=owner_headers,
        )
        assert resend_res.status_code == 200
        assert len(dispatched) == 1
    finally:
        reset_fcm_sender_for_test()
