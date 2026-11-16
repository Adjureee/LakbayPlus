import app.features.auth.service as auth_service_module
from app.core.config import get_settings


def test_google_auth_creates_and_signs_in_traveler(client, monkeypatch) -> None:
    async def fake_verify(id_token: str, *, http_client=None) -> dict[str, object]:
        assert id_token == "valid-google-id-token-123"
        return {
            "email": "Elena.Cruz@gmail.com",
            "email_verified": "true",
            "name": "Elena Cruz",
            "picture": "https://lh3.googleusercontent.com/a/elena.jpg",
            "aud": "test-google-client-id",
        }

    monkeypatch.setattr(auth_service_module, "_verify_google_id_token", fake_verify)

    res1 = client.post(
        "/api/v1/auth/google",
        json={"id_token": "valid-google-id-token-123"},
    )
    assert res1.status_code == 200
    body1 = res1.json()
    assert body1["user"]["email"] == "elena.cruz@gmail.com"
    assert body1["user"]["full_name"] == "Elena Cruz"
    assert body1["user"]["role"] == "user"
    assert body1["tokens"]["access_token"]
    assert body1["tokens"]["refresh_token"]

    # Second login with same verified Google email returns the existing account
    res2 = client.post(
        "/api/v1/auth/google",
        json={"id_token": "valid-google-id-token-123"},
    )
    assert res2.status_code == 200
    assert res2.json()["user"]["user_id"] == body1["user"]["user_id"]


def test_google_auth_rejects_unverified_or_wrong_audience(client, monkeypatch) -> None:
    async def unverified_email(id_token: str, *, http_client=None) -> dict[str, object]:
        return {
            "email": "unverified@gmail.com",
            "email_verified": "false",
            "aud": "expected-client-id",
        }

    monkeypatch.setattr(auth_service_module, "_verify_google_id_token", unverified_email)
    res1 = client.post(
        "/api/v1/auth/google",
        json={"id_token": "unverified-token-value"},
    )
    assert res1.status_code == 401
    assert res1.json()["error"]["code"] == "unverified_google_email"

    # Audience enforcement when GOOGLE_OAUTH_CLIENT_IDS is configured
    monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_IDS", "expected-client-id")
    get_settings.cache_clear()
    try:
        async def wrong_aud(id_token: str, *, http_client=None) -> dict[str, object]:
            return {
                "email": "elena@gmail.com",
                "email_verified": "true",
                "aud": "another-app-client-id",
            }

        monkeypatch.setattr(auth_service_module, "_verify_google_id_token", wrong_aud)
        res2 = client.post(
            "/api/v1/auth/google",
            json={"id_token": "wrong-audience-token-value"},
        )
        assert res2.status_code == 401
        assert res2.json()["error"]["code"] == "invalid_google_token"
    finally:
        monkeypatch.setenv("GOOGLE_OAUTH_CLIENT_IDS", "")
        get_settings.cache_clear()


def test_google_auth_rejects_missing_or_placeholder_name(client, monkeypatch) -> None:
    for bad_name in ("", "   ", "Lakbay Traveler"):
        async def missing_name(
            id_token: str, *, http_client=None, _name: str = bad_name
        ) -> dict[str, object]:
            return {
                "email": "noname@gmail.com",
                "email_verified": "true",
                "name": _name,
            }

        monkeypatch.setattr(auth_service_module, "_verify_google_id_token", missing_name)
        res = client.post(
            "/api/v1/auth/google",
            json={"id_token": "google-token-without-name-value"},
        )
        assert res.status_code == 400
        assert res.json()["error"]["code"] == "missing_google_name"
