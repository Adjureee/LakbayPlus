from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, Field, PositiveInt, model_validator

TravelMode = Literal["driving", "walking", "public_transport", "cycling"]
DistanceKm = Annotated[Decimal, Field(ge=0, max_digits=10, decimal_places=2)]
TrafficLevel = Literal["unknown", "light", "moderate", "heavy", "severe"]
TrafficStatus = Literal["live", "limited_coverage", "unavailable_no_provider", "disabled"]
# How the stop order was chosen: kept as requested, exact search over every
# order with OSRM travel times, OSRM Trip's heuristic, or nearest neighbor
# improved by 2-opt when OSRM is unavailable or the mode is estimated.
# "island_aware" orders stops that need boat crossings so each island's stops
# are visited together.
OrderMethod = Literal[
    "requested", "exact", "osrm_trip", "nearest_neighbor_2opt", "island_aware",
]
SegmentMode = Literal["road", "sea", "ferry", "sea_link", "unrouted"]


class RouteCoordinate(BaseModel):
    label: str | None = Field(default=None, max_length=255)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    # Island the origin is on (e.g. "samal"); omitted means the mainland.
    island_group: str | None = Field(default=None, max_length=50)


class RouteBaseRequest(BaseModel):
    destination_ids: list[PositiveInt] = Field(min_length=1, max_length=60)
    travel_mode: TravelMode = "driving"
    origin: RouteCoordinate | None = None
    return_to_origin: bool = False
    use_live_traffic: bool = False

    @model_validator(mode="after")
    def validate_unique_destination_ids(self) -> "RouteBaseRequest":
        orig_len = len(self.destination_ids)
        deduped: list[int] = []
        for dest_id in self.destination_ids:
            if not deduped or deduped[-1] != dest_id:
                deduped.append(dest_id)

        if orig_len > 1 and len(deduped) == 1 and self.origin is None:
            raise ValueError("destination_ids must not contain consecutive duplicate IDs")

        self.destination_ids = deduped

        if self.return_to_origin and self.origin is None:
            raise ValueError("return_to_origin requires origin")

        return self


class RoutePreviewRequest(RouteBaseRequest):
    pass


class RouteOptimizeRequest(RouteBaseRequest):
    preserve_first_destination: bool = Field(
        default=True,
        description=(
            "When origin is absent, keep the first listed destination as the start. "
            "When origin is provided, it is always the fixed first stop and this "
            "setting has no effect."
        ),
    )


class RouteStop(BaseModel):
    order: int
    destination_id: int | None
    name: str
    lat: float
    lng: float
    is_origin: bool = False
    coordinate_basis: Literal["origin", "verified_arrival", "attraction"] = "attraction"


class RouteDirectionStep(BaseModel):
    order: int = Field(ge=1)
    instruction: str
    distance_meters: int = Field(ge=0)
    duration_seconds: int = Field(ge=0)


class RouteSeaCrossing(BaseModel):
    """A boat ride between two piers, chosen by Lakbay's sea-link planner."""

    order: int = Field(ge=1)
    leg_order: int = Field(ge=1, description="The stop-to-stop leg this crossing belongs to.")
    link_id: int
    vessel_type: str
    board_port: str
    land_port: str
    board_lat: float
    board_lng: float
    land_lat: float
    land_lng: float
    distance_km: DistanceKm
    crossing_minutes: int = Field(ge=0)
    typical_wait_minutes: int = Field(ge=0)
    allows_private_vehicle: bool
    schedule_text: str | None = None
    fare_passenger: Decimal | None = None
    fare_vehicle: Decimal | None = None
    # False until an administrator verifies the piers, schedule and fares.
    verified: bool = False


class RouteSegment(BaseModel):
    """A drawable part of the route: a road run or a boat crossing."""

    order: int = Field(ge=1)
    mode: SegmentMode
    from_name: str
    to_name: str
    # Encoded polyline5. For an estimated road run (no road router answer) it
    # is a straight stop-to-stop connector that must be drawn dashed, not as road.
    polyline: str | None = None
    is_estimated: bool = False
    warning: str | None = None
    reason: str | None = None


class RouteLeg(BaseModel):
    order: int
    from_destination_id: int | None
    to_destination_id: int | None
    from_name: str
    to_name: str
    distance_km: DistanceKm
    duration_minutes: int = Field(ge=0)
    is_estimated: bool
    mode: SegmentMode = "road"
    warning: str | None = None
    reason: str | None = None
    normal_duration_minutes: int | None = Field(default=None, ge=0)
    traffic_delay_minutes: int | None = Field(default=None, ge=0)
    traffic_level: TrafficLevel | None = None
    steps: list[RouteDirectionStep] = Field(default_factory=list)
    # Boat rides inside this leg; distance and duration include them.
    sea_crossings: list[RouteSeaCrossing] = Field(default_factory=list)


class RouteFerryCrossing(BaseModel):
    """A boat crossing inside a road route, such as a RoRo ferry to Samal."""

    name: str | None = None
    distance_km: DistanceKm
    duration_minutes: int = Field(ge=0)
    from_lat: float | None = None
    from_lng: float | None = None
    to_lat: float | None = None
    to_lng: float | None = None


class RouteTrafficCongestionSegment(BaseModel):
    leg_order: int = Field(ge=1)
    level: TrafficLevel = "unknown"
    polyline: str | None = None
    distance_meters: int | None = Field(default=None, ge=0)
    duration_seconds: int | None = Field(default=None, ge=0)


class RouteTrafficInfo(BaseModel):
    status: TrafficStatus
    provider: str | None = None
    delay_seconds: int | None = Field(default=None, ge=0)
    congestion_segments: list[RouteTrafficCongestionSegment] = Field(default_factory=list)
    advisory: str | None = None


class RouteTrafficSummary(BaseModel):
    provider: str
    live_duration_minutes: int = Field(ge=0)
    normal_duration_minutes: int = Field(ge=0)
    delay_minutes: int = Field(ge=0)
    traffic_level: TrafficLevel
    cache_hit: bool = False
    advisory: str
    status: TrafficStatus = "live"
    delay_seconds: int | None = Field(default=None, ge=0)
    congestion_segments: list[RouteTrafficCongestionSegment] = Field(default_factory=list)


class RouteSummaryResponse(BaseModel):
    travel_mode: TravelMode
    route_provider: str
    is_estimated: bool
    order_method: OrderMethod = "requested"
    total_distance_km: DistanceKm
    total_duration_minutes: int = Field(ge=0)
    stops: list[RouteStop]
    legs: list[RouteLeg]
    polyline: str | None = None
    polyline_encoding: Literal["polyline5"] | None = None
    arrival_points_verified: bool = False
    warnings: list[str] = Field(default_factory=list)
    traffic: RouteTrafficSummary | None = None
    traffic_info: RouteTrafficInfo | None = None
    # Boat parts of the route. The total time includes the crossing but not
    # waiting at the pier.
    ferry_crossings: list[RouteFerryCrossing] = Field(default_factory=list)
    # Pier-to-pier boat rides planned by Lakbay. Total time includes the boat
    # and typical pier waiting time; total distance includes sea_distance_km.
    sea_crossings: list[RouteSeaCrossing] = Field(default_factory=list)
    sea_distance_km: DistanceKm = Decimal("0.00")
    # Road and sea parts in travel order, for drawing each with its own style.
    segments: list[RouteSegment] = Field(default_factory=list)
    # Island groups a stop is on that no active sea link reaches.
    unconnected_island_groups: list[str] = Field(default_factory=list)
    skipped_destination_ids: list[int] = Field(default_factory=list)


TripPaceLiteral = Literal["relaxed", "balanced", "packed"]
CostSourceLiteral = Literal["haversine", "osrm", "mapbox", "google_routes"]


class RoutePlanRequest(RouteBaseRequest):
    days: int = Field(default=3, ge=1, le=14)
    pace: TripPaceLiteral = "balanced"
    preserve_first_destination: bool = False
    locked_first_destination_id: int | None = None
    must_visit_destination_ids: list[int] | None = None
    prune_optional_to_fit: bool = False


class RoutePlanStopSummary(BaseModel):
    destination_id: int | None = None
    name: str
    lat: float
    lng: float
    island_group: str | None = None
    stay_duration_type: str
    visit_hours: float


class RoutePlanDay(BaseModel):
    day_number: int
    stops: list[RoutePlanStopSummary]
    visit_hours: float
    transit_hours: float
    total_hours: float
    is_continuation_day: bool = False
    continuation_of_name: str | None = None
    is_overloaded: bool = False
    overload_warning: str | None = None


class RoutePlanSavings(BaseModel):
    baseline_distance_km: float
    optimized_distance_km: float
    distance_saved_km: float
    distance_saved_percent: float
    baseline_transit_minutes: float
    optimized_transit_minutes: float
    minutes_saved: float


class RoutePlanResponse(BaseModel):
    order_method: OrderMethod
    cost_source: CostSourceLiteral
    suggested_days: int
    pace: TripPaceLiteral
    savings_vs_input: RoutePlanSavings
    warnings: list[str]
    skipped_destination_ids: list[int] = Field(default_factory=list)
    days: list[RoutePlanDay]
    route: RouteSummaryResponse
