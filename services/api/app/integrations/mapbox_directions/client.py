"""Mapbox Directions, Matrix and Optimization as an OSRM-compatible road router.

Mapbox runs an OSRM-based engine with fresher Philippine road data than the
public OSRM demo server, and its responses use the same shape (``code``,
``routes``/``trips``, ``legs``, ``steps``, ``waypoints``, ``durations``), so the
OSRM parsers are reused unchanged.
"""

import logging

from app.core.config import Settings, get_settings
from app.features.routes.schemas import RouteCoordinate, TravelMode
from app.integrations.osrm.client import OSRMClient, _coordinates_path
from app.integrations.osrm.errors import OSRMClientError, OSRMConfigurationError
from app.integrations.osrm.schemas import (
    OSRMMatrixResult,
    OSRMRouteResult,
    OSRMTableResult,
)

logger = logging.getLogger(__name__)

# Documented Mapbox request limits (coordinates per request).
MAPBOX_DIRECTIONS_MAX_COORDINATES = 25
MAPBOX_OPTIMIZATION_MAX_COORDINATES = 12
MAPBOX_MATRIX_MAX_COORDINATES = 25


class MapboxDirectionsClient(OSRMClient):
    provider_name = "mapbox"

    def __init__(self, settings: Settings | None = None) -> None:
        super().__init__(settings)
        if not getattr(self.settings, "mapbox_directions_token", None):
            raise OSRMConfigurationError("MAPBOX_DIRECTIONS_TOKEN is not configured.")

    async def preview_route(
        self, *, travel_mode: TravelMode, coordinates: list[RouteCoordinate],
    ) -> OSRMRouteResult:
        _require_max(coordinates, MAPBOX_DIRECTIONS_MAX_COORDINATES, "Directions")
        return await super().preview_route(
            travel_mode=travel_mode, coordinates=coordinates,
        )

    async def optimize_route(
        self,
        *,
        travel_mode: TravelMode,
        coordinates: list[RouteCoordinate],
        roundtrip: bool,
        preserve_first: bool,
    ) -> OSRMRouteResult:
        _require_max(coordinates, MAPBOX_OPTIMIZATION_MAX_COORDINATES, "Optimization")
        return await super().optimize_route(
            travel_mode=travel_mode,
            coordinates=coordinates,
            roundtrip=roundtrip,
            preserve_first=preserve_first,
        )

    async def table(
        self,
        *,
        travel_mode: TravelMode,
        origin: RouteCoordinate,
        destinations: list[RouteCoordinate],
    ) -> OSRMTableResult:
        _require_max([origin, *destinations], MAPBOX_MATRIX_MAX_COORDINATES, "Matrix")
        return await super().table(
            travel_mode=travel_mode, origin=origin, destinations=destinations,
        )

    async def matrix(
        self, *, travel_mode: TravelMode, coordinates: list[RouteCoordinate],
    ) -> OSRMMatrixResult:
        _require_max(coordinates, MAPBOX_MATRIX_MAX_COORDINATES, "Matrix")
        return await super().matrix(travel_mode=travel_mode, coordinates=coordinates)

    # Directions may use live traffic; Matrix and Optimization use the plain
    # driving profile, whose coordinate limits fit a 10-stop trip plus origin.
    def _route_path(self, profile: str, coordinates: list[RouteCoordinate]) -> str:
        return f"/directions/v5/mapbox/{profile}/{_coordinates_path(coordinates)}"

    def _trip_path(self, profile: str, coordinates: list[RouteCoordinate]) -> str:
        return (
            f"/optimization/v1/mapbox/{_base_profile(profile)}/"
            f"{_coordinates_path(coordinates)}"
        )

    def _table_path(self, profile: str, coordinates: list[RouteCoordinate]) -> str:
        return (
            f"/directions-matrix/v1/mapbox/{_base_profile(profile)}/"
            f"{_coordinates_path(coordinates)}"
        )

    def _request_params(self) -> dict[str, str]:
        return {"access_token": self.settings.mapbox_directions_token}

    def _request_timeout(self) -> float:
        return self.settings.mapbox_directions_timeout_seconds

    def _profile_for_mode(self, travel_mode: TravelMode) -> str:
        if travel_mode == "driving":
            return self.settings.mapbox_directions_profile_driving
        if travel_mode == "walking":
            return "walking"
        raise OSRMConfigurationError("Mapbox does not support public_transport mode.")

    def _base_url_for_mode(self, travel_mode: TravelMode) -> str:
        if travel_mode not in ("driving", "walking"):
            raise OSRMConfigurationError("Mapbox does not support public_transport mode.")
        return self.settings.mapbox_directions_base_url


class ChainedRoutingClient(OSRMClient):
    """Tries each road router in order and returns the first answer.

    Every method keeps the OSRMClient signature, so RouteService, recommendations
    and geo analytics work without knowing which provider answered.
    """

    def __init__(self, clients: list[OSRMClient], settings: Settings | None = None) -> None:
        super().__init__(settings)
        if not clients:
            raise OSRMConfigurationError("No road routing provider is configured.")
        self.clients = clients

    @property
    def provider_name(self) -> str:  # type: ignore[override]
        return self.clients[0].provider_name

    async def preview_route(self, **kwargs) -> OSRMRouteResult:
        return await self._first("preview_route", kwargs)

    async def preview_route_with_snap_limits(self, **kwargs) -> OSRMRouteResult:
        return await self._first("preview_route_with_snap_limits", kwargs)

    async def optimize_route(self, **kwargs) -> OSRMRouteResult:
        return await self._first("optimize_route", kwargs)

    async def table(self, **kwargs) -> OSRMTableResult:
        return await self._first("table", kwargs)

    async def matrix(self, **kwargs) -> OSRMMatrixResult:
        return await self._first("matrix", kwargs)

    async def _first(self, method: str, kwargs: dict):
        last_error: OSRMClientError | None = None
        for client in self.clients:
            try:
                return await getattr(client, method)(**kwargs)
            except OSRMClientError as exc:
                logger.info(
                    "%s %s failed, trying the next road router: %s",
                    client.provider_name, method, exc,
                )
                last_error = exc
        assert last_error is not None
        raise last_error


def _base_profile(profile: str) -> str:
    return "driving" if profile == "driving-traffic" else profile


def _require_max(coordinates: list[RouteCoordinate], limit: int, api: str) -> None:
    if len(coordinates) > limit:
        raise OSRMConfigurationError(
            f"Mapbox {api} accepts at most {limit} coordinates."
        )
