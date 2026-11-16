"""The push client talks to Firebase's current (HTTP v1) API with a service account."""

import asyncio
import base64
import json

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.core.config import Settings
from app.integrations.push import client as push_client
from app.integrations.push.client import FCMClient, build_signed_assertion, clear_token_cache

TOKEN_URI = "https://oauth2.googleapis.com/token"
EMAIL = "push@lakbay-test.iam.gserviceaccount.com"


@pytest.fixture(autouse=True)
def fresh_token_cache():
    clear_token_cache()
    yield
    clear_token_cache()


@pytest.fixture(scope="module")
def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _settings(key, *, project_id: str | None = None, in_json: bool = True) -> Settings:
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    info = {"client_email": EMAIL, "private_key": pem, "token_uri": TOKEN_URI}
    if in_json:
        info["project_id"] = "lakbay-test"
    return Settings.model_construct(
        fcm_service_account_json=json.dumps(info), fcm_project_id=project_id,
    )


class FakeGoogle:
    """Answers the token request and the send request, and records both."""

    def __init__(self, send_responses=None, token_status: int = 200):
        self.token_requests: list[httpx.Request] = []
        self.sends: list[httpx.Request] = []
        self.send_responses = list(send_responses or [])
        self.token_status = token_status
        self._issued = 0

    def handle(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_URI:
            self.token_requests.append(request)
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            self._issued += 1
            return httpx.Response(200, json={"access_token": f"ya29.token{self._issued}", "expires_in": 3600})
        self.sends.append(request)
        if self.send_responses:
            return self.send_responses.pop(0)
        return httpx.Response(200, json={"name": "projects/lakbay-test/messages/1"})

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)


def _send(client: FCMClient, token="device-token-123456", data=None) -> bool:
    return asyncio.run(client.send_push(
        device_token=token, title="Trip invitation", body="Maria invited you.",
        data=data or {"event_type": "trip_invitation", "trip_id": 9},
    ))


def _jwt_parts(assertion: str):
    header, claims, signature = assertion.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)  # noqa: E731
    return (
        json.loads(base64.urlsafe_b64decode(pad(header))),
        json.loads(base64.urlsafe_b64decode(pad(claims))),
        header + "." + claims,
        base64.urlsafe_b64decode(pad(signature)),
    )


def test_unconfigured_client_is_a_quiet_no_op() -> None:
    client = FCMClient(Settings.model_construct(fcm_service_account_json=None, fcm_project_id=None))
    assert client.is_configured is False
    assert asyncio.run(client.send_notifications([
        {"device_token": "t", "title": "a", "body": "b", "data": {}},
    ])) == 0


def test_the_old_server_key_setting_is_gone() -> None:
    assert "fcm_server_key" not in Settings.model_fields


def test_signed_assertion_is_a_valid_rs256_jwt(key) -> None:
    client = FCMClient(_settings(key))
    assertion = build_signed_assertion(client._service_account(), now=1_700_000_000)
    header, claims, signing_input, signature = _jwt_parts(assertion)

    assert header == {"alg": "RS256", "typ": "JWT"}
    assert claims == {
        "iss": EMAIL,
        "scope": "https://www.googleapis.com/auth/firebase.messaging",
        "aud": TOKEN_URI,
        "iat": 1_700_000_000,
        "exp": 1_700_003_600,
    }
    # Raises if the signature does not verify with the matching public key.
    key.public_key().verify(signature, signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())


def test_sends_to_the_v1_endpoint_with_a_bearer_token_and_string_data(key) -> None:
    google = FakeGoogle()
    client = FCMClient(_settings(key), transport=google.transport)

    assert _send(client) is True

    request = google.sends[0]
    assert str(request.url) == "https://fcm.googleapis.com/v1/projects/lakbay-test/messages:send"
    assert request.headers["authorization"] == "Bearer ya29.token1"
    message = json.loads(request.content)["message"]
    assert message["token"] == "device-token-123456"
    assert message["notification"] == {"title": "Trip invitation", "body": "Maria invited you."}
    assert message["data"] == {"event_type": "trip_invitation", "trip_id": "9"}  # strings only
    assert "legacy" not in str(request.url) and "/fcm/send" not in str(request.url)

    # The token request is the JWT-bearer grant.
    form = dict(item.split("=", 1) for item in google.token_requests[0].content.decode().split("&"))
    assert form["grant_type"].replace("%3A", ":") == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert form["assertion"].count(".") == 2


def test_the_access_token_is_reused_until_it_nearly_expires(key) -> None:
    google = FakeGoogle()
    client = FCMClient(_settings(key), transport=google.transport)

    assert _send(client) and _send(client) and _send(client)

    assert len(google.token_requests) == 1
    assert len(google.sends) == 3


def test_project_id_setting_overrides_the_one_in_the_key(key) -> None:
    google = FakeGoogle()
    client = FCMClient(_settings(key, project_id="override-project"), transport=google.transport)

    assert _send(client)

    assert "/projects/override-project/" in str(google.sends[0].url)


def test_project_id_can_come_from_the_setting_alone(key) -> None:
    google = FakeGoogle()
    client = FCMClient(_settings(key, project_id="only-setting", in_json=False), transport=google.transport)

    assert _send(client)

    assert "/projects/only-setting/" in str(google.sends[0].url)


def test_a_rejected_access_token_is_replaced_once_and_the_send_retried(key) -> None:
    google = FakeGoogle(send_responses=[httpx.Response(401, json={"error": {"status": "UNAUTHENTICATED"}})])
    client = FCMClient(_settings(key), transport=google.transport)

    assert _send(client) is True

    assert len(google.token_requests) == 2
    assert [r.headers["authorization"] for r in google.sends] == ["Bearer ya29.token1", "Bearer ya29.token2"]


def test_a_device_token_firebase_says_is_gone_is_reported(key) -> None:
    gone = httpx.Response(404, json={"error": {"status": "NOT_FOUND", "details": [
        {"@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": "UNREGISTERED"},
    ]}})
    google = FakeGoogle(send_responses=[gone])
    client = FCMClient(_settings(key), transport=google.transport)

    sent = asyncio.run(client.send_notifications([
        {"device_token": "stale-token-000001", "title": "a", "body": "b", "data": {}},
    ]))

    assert sent == 0
    assert client.invalid_tokens == {"stale-token-000001"}


def test_a_server_error_is_not_treated_as_a_dead_token(key) -> None:
    google = FakeGoogle(send_responses=[httpx.Response(503, json={"error": {"status": "UNAVAILABLE"}})])
    client = FCMClient(_settings(key), transport=google.transport)

    assert asyncio.run(client.send_notifications([
        {"device_token": "ok-token-000001", "title": "a", "body": "b", "data": {}},
    ])) == 0
    assert client.invalid_tokens == set()


def test_failing_to_get_an_access_token_never_raises(key) -> None:
    google = FakeGoogle(token_status=400)
    client = FCMClient(_settings(key), transport=google.transport)

    assert _send(client) is False
    assert google.sends == []


def test_a_network_error_never_reaches_the_caller(key) -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    client = FCMClient(_settings(key), transport=httpx.MockTransport(boom))

    assert asyncio.run(client.send_notifications([
        {"device_token": "x-token-0000001", "title": "a", "body": "b", "data": {}},
    ])) == 0


def test_bad_configuration_is_reported_as_not_configured() -> None:
    client = FCMClient(Settings.model_construct(
        fcm_service_account_json="{not json", fcm_project_id=None,
    ))
    assert client.is_configured is False
    client = FCMClient(Settings.model_construct(
        fcm_service_account_json=json.dumps({"client_email": EMAIL}), fcm_project_id=None,
    ))
    assert client.is_configured is False


def test_the_module_no_longer_mentions_the_dead_endpoint() -> None:
    source = open(push_client.__file__, encoding="utf-8").read()
    assert 'https://fcm.googleapis.com/fcm/send"' not in source
    assert "key={" not in source


def test_a_token_firebase_rejects_is_switched_off_so_it_is_not_tried_again(client, monkeypatch) -> None:
    from app.features.notifications import service as notification_service
    from tests.test_phase8_group_collaboration import create_trip, register_user

    attempts: list[list[str]] = []

    class RejectingClient:
        is_configured = True
        invalid_tokens: set[str] = set()

        async def send_notifications(self, messages):
            attempts.append([m["device_token"] for m in messages])
            self.invalid_tokens = {m["device_token"] for m in messages}
            return 0

    monkeypatch.setattr(notification_service, "get_fcm_client", lambda: RejectingClient())

    owner = register_user(client, email="reject-owner@example.com")
    invitee = register_user(client, email="reject-invitee@example.com")
    trip = create_trip(client, owner)
    registered = client.post(
        "/api/v1/notifications/device-tokens", headers=invitee,
        json={"device_token": "uninstalled-device-token-1", "platform": "android"},
    )
    assert registered.status_code == 200

    invited = client.post(
        f"/api/v1/trips/{trip['trip_id']}/members", headers=owner,
        json={"email": "reject-invitee@example.com", "role": "member"},
    )
    assert invited.status_code == 201
    assert attempts == [["uninstalled-device-token-1"]]

    # Switched off: the next notification does not try that device.
    resent = client.post(
        f"/api/v1/trips/{trip['trip_id']}/members/{invited.json()['trip_member_id']}/resend",
        headers=owner,
    )
    assert resent.status_code == 200
    assert attempts == [["uninstalled-device-token-1"]]
