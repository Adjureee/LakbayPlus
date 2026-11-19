from fastapi.testclient import TestClient

from app.main import create_app


def test_health_endpoint_returns_foundation_status(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://user:pass@localhost/db")

    client = TestClient(create_app())
    response = client.get("/api/v1/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "app_name": "Lakbay API",
        "environment": "local",
        "api_prefix": "/api/v1",
        "timezone": "Asia/Manila",
        "claims_check_mode": "enforce",
    }


def test_health_reports_the_claims_check_mode_that_is_in_effect(monkeypatch) -> None:
    from app.core.config import get_settings

    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://user:pass@localhost/db")
    monkeypatch.setenv("CLAIMS_CHECK_MODE", "log")
    get_settings.cache_clear()
    try:
        response = TestClient(create_app()).get("/api/v1/health")
        assert response.json()["claims_check_mode"] == "log"
    finally:
        monkeypatch.delenv("CLAIMS_CHECK_MODE")
        get_settings.cache_clear()


def test_not_found_uses_standard_error_shape(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+asyncpg://user:pass@localhost/db")

    client = TestClient(create_app())
    response = client.get("/api/v1/missing")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"
