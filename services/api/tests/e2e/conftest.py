import asyncio
from collections.abc import Generator
from dataclasses import dataclass, field
import math
from typing import Any, Literal

from fastapi.testclient import TestClient
from geoalchemy2 import Geography
import httpx
import pytest
from sqlalchemy import event
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.pool import StaticPool

from app.core.config import get_settings
from app.core.provider_usage import _redis_client as _provider_usage_redis_client
from app.db.base import Base, import_model_modules
from app.db.session import get_db_session
from app.features.ai import router as ai_router_module
from app.features.ai.service import _ai_user_limiter
from app.features.destinations.candidate_router import _osm_lookup_limiter
from app.features.destinations.service import clear_facets_cache
from app.features.geo_analytics.dependencies import _limiter as _geo_analytics_limiter
from app.features.planning import dependencies as planning_deps_module
from app.features.planning.dependencies import _route_limiter as _planning_route_limiter
from app.features.routes.dependencies import _route_request_limiter
from app.features.routes.polyline import encode_polyline5
from app.features.routes.schemas import RouteCoordinate, TravelMode
from app.features.users.service import _user_search_limiter
from app.features.weather.service import (
    _weather_cache,
    _weather_limiter,
)
from app.integrations.google_routes import client as google_routes_client_module
from app.integrations.google_routes.client import get_google_routes_client
from app.integrations.google_routes.errors import GoogleRoutesConfigurationError
from app.integrations.google_routes.schemas import (
    GoogleRouteLeg,
    GoogleRouteResult,
    GoogleRouteStep,
)
from app.integrations.groq import client as groq_client_module
from app.integrations.groq.client import get_groq_client
from app.integrations.groq.schemas import GroqChatCompletion
from app.integrations.osm.client import _cache as _osm_cache
from app.integrations.osrm.client import get_osrm_client
from app.integrations.osrm.errors import OSRMClientError, OSRMRouteNotFoundError
from app.integrations.osrm.schemas import (
    OSRMLeg,
    OSRMMatrixResult,
    OSRMRouteResult,
    OSRMStep,
    OSRMTableEntry,
    OSRMTableResult,
)
from app.integrations.storage.client import StorageUploadResult, get_storage_client
from app.integrations.storage.uploads import cloudinary_upload_limiter
from app.main import create_app


TEST_DATABASE_URL = "sqlite+aiosqlite://"

_PROVIDER_KEYS_TO_BLANK = (
    "GROQ_API_KEY",
    "FALLBACK_LLM_API_KEY",
    "FALLBACK_LLM_MODEL",
    "MAPBOX_DIRECTIONS_TOKEN",
    "OSRM_BASE_URL",
    "OSRM_WALKING_BASE_URL",
    "GOOGLE_ROUTES_API_KEY",
    "OPENWEATHER_API_KEY",
    "CLOUDINARY_API_KEY",
    "CLOUDINARY_API_SECRET",
    "PROVIDER_USAGE_REDIS_URL",
    "GOOGLE_OAUTH_CLIENT_IDS",
    "FCM_PROJECT_ID",
    "FCM_SERVICE_ACCOUNT_JSON",
)


@compiles(Geography, "sqlite")
def compile_geography_for_sqlite(type_, compiler, **kw) -> str:
    return "TEXT"


def _register_sqlite_spatial_functions(dbapi_connection, connection_record) -> None:
    dbapi_connection.create_function("ST_GeogFromText", 1, lambda value: value)
    dbapi_connection.create_function("AsBinary", 1, lambda value: value)


def _approx_distance_meters(a: RouteCoordinate, b: RouteCoordinate) -> float:
    lat1, lng1 = math.radians(a.lat), math.radians(a.lng)
    lat2, lng2 = math.radians(b.lat), math.radians(b.lng)
    dlat = lat2 - lat1
    dlng = lng2 - lng1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlng / 2) ** 2
    return max(500.0, 2 * 6_371_000.0 * math.asin(min(1.0, math.sqrt(h))))


class FakeOSRMClient:
    provider_name = "osrm"

    def __init__(
        self,
        *,
        preview_result: OSRMRouteResult | None = None,
        optimize_result: OSRMRouteResult | None = None,
        matrix_result: OSRMMatrixResult | None = None,
        error: Exception | None = None,
        unreachable_lats: set[float] | None = None,
        raise_on_matrix: bool = False,
        provider_name: str = "osrm",
    ) -> None:
        self.preview_result = preview_result
        self.optimize_result = optimize_result
        self.matrix_result = matrix_result
        self.error = error
        self.unreachable_lats = unreachable_lats or set()
        self.raise_on_matrix = raise_on_matrix
        self.provider_name = provider_name
        self.preview_calls: list[dict[str, Any]] = []
        self.optimize_calls: list[dict[str, Any]] = []
        self.matrix_calls: list[dict[str, Any]] = []
        self.table_calls: list[dict[str, Any]] = []

    def _is_unreachable(self, coordinates: list[RouteCoordinate]) -> bool:
        return any(
            any(abs(coord.lat - bad) < 1e-5 for bad in self.unreachable_lats)
            for coord in coordinates
        )

    def _build_route(self, coordinates: list[RouteCoordinate]) -> OSRMRouteResult:
        legs: list[OSRMLeg] = []
        total_dist = 0.0
        total_dur = 0.0
        for start, end in zip(coordinates, coordinates[1:]):
            dist = _approx_distance_meters(start, end)
            dur = max(120.0, dist / 11.0)
            total_dist += dist
            total_dur += dur
            legs.append(
                OSRMLeg(
                    distance_meters=dist,
                    duration_seconds=dur,
                    steps=[
                        OSRMStep(
                            distance_meters=dist,
                            duration_seconds=dur,
                            maneuver_type="depart",
                            road_name="Davao Coastal Hwy",
                            location=(start.lat, start.lng),
                        ),
                        OSRMStep(
                            distance_meters=0.0,
                            duration_seconds=0.0,
                            maneuver_type="arrive",
                            location=(end.lat, end.lng),
                        ),
                    ],
                )
            )
        polyline = (
            encode_polyline5([(c.lat, c.lng) for c in coordinates])
            if len(coordinates) >= 2
            else None
        )
        return OSRMRouteResult(
            total_distance_meters=total_dist,
            total_duration_seconds=total_dur,
            legs=legs,
            stop_order=list(range(len(coordinates))),
            polyline=polyline,
            provider=self.provider_name,
        )

    async def preview_route(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
    ) -> OSRMRouteResult:
        self.preview_calls.append({"travel_mode": travel_mode, "coordinates": coordinates})
        if self.error is not None:
            raise self.error
        if self._is_unreachable(coordinates):
            raise OSRMRouteNotFoundError("Pin could not snap to road network.")
        if self.preview_result is not None and len(self.preview_result.legs) == max(len(coordinates) - 1, 0):
            return self.preview_result
        return self._build_route(coordinates)

    async def preview_route_with_snap_limits(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
        max_snap_meters: list[float],
    ) -> OSRMRouteResult:
        self.preview_calls.append(
            {
                "travel_mode": travel_mode,
                "coordinates": coordinates,
                "max_snap_meters": max_snap_meters,
            }
        )
        if self.error is not None:
            raise self.error
        if self._is_unreachable(coordinates):
            raise OSRMRouteNotFoundError("Pin could not snap to road network.")
        if self.preview_result is not None and len(self.preview_result.legs) == max(len(coordinates) - 1, 0):
            return self.preview_result
        return self._build_route(coordinates)

    async def optimize_route(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
        roundtrip: bool,
        preserve_first: bool,
    ) -> OSRMRouteResult:
        self.optimize_calls.append(
            {
                "travel_mode": travel_mode,
                "coordinates": coordinates,
                "roundtrip": roundtrip,
                "preserve_first": preserve_first,
            }
        )
        if self.error is not None:
            raise self.error
        if self._is_unreachable(coordinates):
            raise OSRMRouteNotFoundError("Pin could not snap to road network.")
        if self.optimize_result is not None:
            return self.optimize_result
        effective = [*coordinates, coordinates[0]] if roundtrip and len(coordinates) >= 2 else coordinates
        result = self._build_route(effective)
        return OSRMRouteResult(
            total_distance_meters=result.total_distance_meters,
            total_duration_seconds=result.total_duration_seconds,
            legs=result.legs,
            stop_order=list(range(len(coordinates))),
            polyline=result.polyline,
            provider=self.provider_name,
        )

    async def matrix(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
    ) -> OSRMMatrixResult:
        self.matrix_calls.append({"travel_mode": travel_mode, "coordinates": coordinates})
        if self.error is not None:
            raise self.error
        if self.raise_on_matrix:
            raise OSRMClientError("Matrix unavailable in fake.")
        if self.matrix_result is not None:
            return self.matrix_result
        n = len(coordinates)
        durations: list[list[float | None]] = []
        distances: list[list[float | None]] = []
        for i in range(n):
            dur_row: list[float | None] = []
            dist_row: list[float | None] = []
            for j in range(n):
                if i == j:
                    dur_row.append(0.0)
                    dist_row.append(0.0)
                else:
                    dist = _approx_distance_meters(coordinates[i], coordinates[j])
                    dur_row.append(max(120.0, dist / 11.0))
                    dist_row.append(dist)
            durations.append(dur_row)
            distances.append(dist_row)
        return OSRMMatrixResult(durations_seconds=durations, distances_meters=distances)

    async def table(
        self,
        *,
        travel_mode: TravelMode,
        origin: RouteCoordinate,
        destinations: list[RouteCoordinate],
    ) -> OSRMTableResult:
        self.table_calls.append(
            {"travel_mode": travel_mode, "origin": origin, "destinations": destinations}
        )
        if self.error is not None:
            raise self.error
        entries = []
        for dest in destinations:
            if any(abs(dest.lat - bad) < 1e-5 for bad in self.unreachable_lats):
                entries.append(OSRMTableEntry(duration_seconds=None, distance_meters=None, snap_meters=5.0))
            else:
                dist = _approx_distance_meters(origin, dest)
                entries.append(
                    OSRMTableEntry(
                        duration_seconds=max(120.0, dist / 11.0),
                        distance_meters=dist,
                        snap_meters=5.0,
                    )
                )
        return OSRMTableResult(source_snap_meters=5.0, entries=entries)


class FakeGoogleRoutesClient:
    def __init__(
        self,
        *,
        is_configured: bool = True,
        result: GoogleRouteResult | None = None,
        error: Exception | None = None,
        delay_seconds_per_leg: float = 180.0,
    ) -> None:
        self.is_configured = is_configured
        self.result = result
        self.error = error
        self.delay_seconds_per_leg = delay_seconds_per_leg
        self.calls: list[dict[str, Any]] = []

    async def compute_route(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
    ) -> GoogleRouteResult:
        self.calls.append({"travel_mode": travel_mode, "coordinates": coordinates})
        if not self.is_configured:
            raise GoogleRoutesConfigurationError("GOOGLE_ROUTES_API_KEY is not configured.")
        if self.error is not None:
            raise self.error
        if self.result is not None and len(self.result.legs) == max(len(coordinates) - 1, 0):
            return self.result
        legs: list[GoogleRouteLeg] = []
        total_dist = 0.0
        total_static = 0.0
        total_live = 0.0
        for start, end in zip(coordinates, coordinates[1:]):
            dist = _approx_distance_meters(start, end)
            static_dur = max(120.0, dist / 12.0)
            live_dur = static_dur + self.delay_seconds_per_leg
            total_dist += dist
            total_static += static_dur
            total_live += live_dur
            legs.append(
                GoogleRouteLeg(
                    distance_meters=dist,
                    duration_seconds=live_dur,
                    static_duration_seconds=static_dur,
                    steps=[
                        GoogleRouteStep(
                            instruction=f"Drive from {start.label or 'stop'} to {end.label or 'next stop'}",
                            distance_meters=dist,
                            duration_seconds=live_dur,
                        )
                    ],
                )
            )
        polyline = (
            encode_polyline5([(c.lat, c.lng) for c in coordinates])
            if len(coordinates) >= 2
            else None
        )
        return GoogleRouteResult(
            total_distance_meters=total_dist,
            total_duration_seconds=total_live,
            total_static_duration_seconds=total_static,
            legs=legs,
            cache_hit=False,
            polyline=polyline,
        )


class FakeGroqClient:
    def __init__(
        self,
        responses: list[str | Exception] | None = None,
        *,
        default_response: str | None = None,
    ) -> None:
        self.responses: list[str | Exception] = list(responses or [])
        self.default_response = default_response
        self.calls: list[dict[str, Any]] = []

    async def create_chat_completion(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        response_format: dict | None = None,
        provider: str = "groq",
        temperature: float | None = None,
        max_tokens: int | None = None,
        max_rate_limit_wait_seconds: int | None = None,
    ) -> GroqChatCompletion:
        self.calls.append(
            {
                "model": model,
                "messages": messages,
                "response_format": response_format,
                "provider": provider,
                "temperature": temperature,
                "max_tokens": max_tokens,
                "max_rate_limit_wait_seconds": max_rate_limit_wait_seconds,
            }
        )
        if self.responses:
            item = self.responses.pop(0)
        elif self.default_response is not None:
            item = self.default_response
        else:
            raise AssertionError("FakeGroqClient has no queued or default response.")

        if isinstance(item, Exception):
            raise item

        return GroqChatCompletion(
            content=item,
            model=model,
            prompt_tokens=16,
            completion_tokens=32,
            total_tokens=48,
        )


class FakeStorageClient:
    def __init__(
        self,
        *,
        media_url: str | None = None,
        media_duration: float | None = None,
    ) -> None:
        self.calls: list[dict[str, Any]] = []
        self.media_calls: list[dict[str, Any]] = []
        self.deleted_calls: list[dict[str, Any]] = []
        self.media_url = media_url
        self.media_duration = media_duration

    async def upload_image(
        self,
        *,
        file_bytes: bytes,
        filename: str | None,
        content_type: str,
        folder_suffix: str | None = None,
    ) -> StorageUploadResult:
        self.calls.append(
            {
                "file_bytes": file_bytes,
                "filename": filename,
                "content_type": content_type,
                "folder_suffix": folder_suffix,
            }
        )
        ext = "png" if content_type == "image/png" else ("webp" if content_type == "image/webp" else "jpg")
        folder = folder_suffix or "destinations/1"
        return StorageUploadResult(
            image_url=f"https://res.cloudinary.com/demo/image/upload/v1/lakbay/{folder}/photo.{ext}",
            cloudinary_public_id=f"lakbay/{folder}/photo",
            original_filename=filename,
            content_type=content_type,
            bytes=len(file_bytes),
            format=ext,
            resource_type="image",
        )

    async def upload_media(
        self,
        *,
        file_bytes: bytes,
        filename: str | None,
        content_type: str,
        resource_type: Literal["image", "video"] = "image",
        folder_suffix: str | None = None,
    ) -> StorageUploadResult:
        self.media_calls.append(
            {
                "file_bytes": file_bytes,
                "filename": filename,
                "content_type": content_type,
                "resource_type": resource_type,
                "folder_suffix": folder_suffix,
            }
        )
        folder = folder_suffix or "destinations/1"
        if resource_type == "video":
            ext = "webm" if content_type == "video/webm" else "mp4"
            default_url = f"https://res.cloudinary.com/demo/video/upload/v1/lakbay/{folder}/clip.{ext}"
            fmt = ext
        elif content_type == "image/gif":
            default_url = f"https://res.cloudinary.com/demo/image/upload/v1/lakbay/{folder}/loop.gif"
            fmt = "gif"
        else:
            ext = "png" if content_type == "image/png" else ("webp" if content_type == "image/webp" else "jpg")
            default_url = f"https://res.cloudinary.com/demo/image/upload/v1/lakbay/{folder}/photo.{ext}"
            fmt = ext
        return StorageUploadResult(
            image_url=self.media_url or default_url,
            cloudinary_public_id=f"lakbay/{folder}/clip",
            original_filename=filename,
            content_type=content_type,
            bytes=len(file_bytes),
            format=fmt,
            resource_type=resource_type,
            duration=self.media_duration,
        )

    async def delete_image(self, public_id: str) -> str:
        return await self.delete_media(public_id, resource_type="image")

    async def delete_media(
        self,
        public_id: str,
        *,
        resource_type: Literal["image", "video"] = "image",
    ) -> str:
        self.deleted_calls.append({"public_id": public_id, "resource_type": resource_type})
        return "ok"


@dataclass
class E2EFakeRegistry:
    osrm: FakeOSRMClient = field(default_factory=FakeOSRMClient)
    google_routes: FakeGoogleRoutesClient = field(
        default_factory=lambda: FakeGoogleRoutesClient(is_configured=False)
    )
    groq: FakeGroqClient = field(default_factory=FakeGroqClient)
    storage: FakeStorageClient = field(default_factory=FakeStorageClient)


def _clear_all_limiters_and_caches() -> None:
    get_settings.cache_clear()
    _ai_user_limiter.clear()
    cloudinary_upload_limiter.clear()
    _route_request_limiter.clear()
    _planning_route_limiter.cache_clear()
    _osm_lookup_limiter.clear()
    _user_search_limiter.clear()
    _osm_cache.clear()
    clear_facets_cache()
    google_routes_client_module._CACHE.clear()
    google_routes_client_module._REQUEST_COUNTS.clear()
    groq_client_module._groq_model_limiter.clear()
    _geo_analytics_limiter.cache_clear()
    _weather_cache.clear()
    _weather_limiter.clear()
    _provider_usage_redis_client.cache_clear()


@pytest.fixture(autouse=True)
def e2e_offline_isolation(monkeypatch: pytest.MonkeyPatch) -> Generator[None, None, None]:
    for key in _PROVIDER_KEYS_TO_BLANK:
        monkeypatch.setenv(key, "")

    monkeypatch.setenv("DATABASE_URL", TEST_DATABASE_URL)
    monkeypatch.setenv("JWT_SECRET_KEY", "e2e-test-secret-key")
    monkeypatch.setenv("ADMIN_REGISTRATION_CODE", "admin-test-code")
    monkeypatch.setenv("CLOUDINARY_CLOUD_NAME", "demo")
    monkeypatch.setenv("GROQ_MODEL_DEFAULT", "default-model")
    monkeypatch.setenv("GROQ_MODEL_FAST", "fast-model")
    monkeypatch.setenv("GROQ_MODEL_QUALITY", "quality-model")
    monkeypatch.setenv("GROQ_MODEL_FALLBACK", "fallback-model")
    monkeypatch.setenv("GROQ_MODEL_COMPARE_A", "compare-a-model")
    monkeypatch.setenv("GROQ_MODEL_COMPARE_B", "compare-b-model")
    monkeypatch.setenv("GROQ_MODEL_COMPARE_C", "compare-c-model")
    monkeypatch.setenv("AI_MODEL_COMPARISON_ENABLED", "false")
    monkeypatch.setenv("AI_ITINERARY_OPTION_COUNT", "2")
    monkeypatch.setenv("GUEST_AI_CHAT_ENABLED", "true")
    monkeypatch.setenv("ROUTE_MAX_DESTINATIONS", "50")

    async def _blocked_async_send(self: httpx.AsyncClient, request: httpx.Request, *args, **kwargs):
        transport = getattr(self, "_transport", None)
        if isinstance(transport, httpx.ASGITransport):
            return await _orig_async_send(self, request, *args, **kwargs)
        raise RuntimeError(
            f"Unmocked outbound HTTP request blocked in E2E suite: {request.method} {request.url}"
        )

    _orig_async_send = httpx.AsyncClient.send
    monkeypatch.setattr(httpx.AsyncClient, "send", _blocked_async_send)

    _clear_all_limiters_and_caches()
    yield
    _clear_all_limiters_and_caches()


@pytest.fixture
def e2e_fakes() -> E2EFakeRegistry:
    return E2EFakeRegistry()


@pytest.fixture
def client(
    monkeypatch: pytest.MonkeyPatch,
    e2e_fakes: E2EFakeRegistry,
) -> Generator[TestClient, None, None]:
    get_settings.cache_clear()
    import_model_modules()

    engine = create_async_engine(
        TEST_DATABASE_URL,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    event.listen(engine.sync_engine, "connect", _register_sqlite_spatial_functions)
    testing_session_local = async_sessionmaker(
        bind=engine,
        expire_on_commit=False,
        autoflush=False,
    )

    async def create_tables() -> None:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    async def drop_tables() -> None:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.drop_all)
        await engine.dispose()

    async def override_get_db_session():
        async with testing_session_local() as session:
            try:
                yield session
            except Exception:
                await session.rollback()
                raise

    asyncio.run(create_tables())

    app = create_app()
    app.dependency_overrides[get_db_session] = override_get_db_session
    app.dependency_overrides[get_osrm_client] = lambda: e2e_fakes.osrm
    app.dependency_overrides[get_google_routes_client] = lambda: e2e_fakes.google_routes
    app.dependency_overrides[get_groq_client] = lambda: e2e_fakes.groq
    app.dependency_overrides[get_storage_client] = lambda: e2e_fakes.storage

    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: e2e_fakes.osrm)
    monkeypatch.setattr(planning_deps_module, "get_osrm_client", lambda: e2e_fakes.osrm)

    with TestClient(app) as test_client:
        test_client.e2e_fakes = e2e_fakes  # type: ignore[attr-defined]
        yield test_client

    app.dependency_overrides.clear()
    asyncio.run(drop_tables())
