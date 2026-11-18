from datetime import date, datetime, time
from decimal import Decimal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.features.routes.polyline import validate_polyline5


class DestinationBase(BaseModel):
    name: str = Field(min_length=2, max_length=255)
    description: str | None = None
    district: str | None = Field(default=None, max_length=255)
    location: str | None = Field(default=None, max_length=500)
    category: str | None = Field(default=None, max_length=500)
    vibes: str | None = Field(default=None, max_length=500)
    activities: str | None = None
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    arrival_lat: float | None = Field(default=None, ge=-90, le=90)
    arrival_lng: float | None = Field(default=None, ge=-180, le=180)
    arrival_source_url: str | None = Field(default=None, max_length=2048)
    arrival_verified_at: datetime | None = None
    route_ready: bool = False
    access_trail_polyline: str | None = None
    island_group: str | None = Field(default=None, max_length=50)
    estimated_cost: Decimal | None = Field(
        default=None,
        ge=0,
        max_digits=10,
        decimal_places=2,
    )
    entrance_fee: str | None = Field(default=None, max_length=255)
    overnight_fee: str | None = Field(default=None, max_length=255)
    operating_hours: str | None = Field(default=None, max_length=255)
    best_time_to_visit: str | None = None
    how_to_get_there: str | None = None
    estimated_travel_time: str | None = None
    travel_notes: str | None = None
    what_to_bring: str | None = None
    is_kid_friendly: bool = False
    is_wheelchair_accessible: bool = False
    is_pet_friendly: bool = False
    is_elderly_friendly: bool = False
    family_friendly: bool = False
    couple_friendly: bool = False
    group_friendly: bool = False
    budget_class: str | None = Field(default=None, max_length=50)
    crowd_level: str | None = Field(default=None, max_length=50)
    difficulty_level: str | None = Field(default=None, max_length=50)
    stay_duration_type: str | None = Field(default=None, max_length=50)
    transport_accessibility: str | None = Field(default=None, max_length=100)
    image_url: str | None = Field(default=None, max_length=2048)

    @field_validator("arrival_source_url")
    @classmethod
    def validate_arrival_source_url(cls, value: str | None) -> str | None:
        return _validate_arrival_source_url(value)

    @field_validator("access_trail_polyline")
    @classmethod
    def validate_access_trail_polyline(cls, value: str | None) -> str | None:
        return _validate_access_trail_polyline(value)

    @field_validator("island_group")
    @classmethod
    def normalize_island_group(cls, value: str | None) -> str | None:
        return _normalize_optional_slug(value)

    @model_validator(mode="after")
    def validate_arrival_point(self) -> "DestinationBase":
        if (self.arrival_lat is None) != (self.arrival_lng is None):
            raise ValueError("arrival_lat and arrival_lng must be provided together")
        if self.route_ready and (
            self.arrival_lat is None
            or not self.arrival_source_url
            or self.arrival_verified_at is None
        ):
            raise ValueError(
                "route_ready requires arrival coordinates, source URL, and verification time"
            )
        return self


class DestinationCreate(DestinationBase):
    pass


class DestinationUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=255)
    description: str | None = None
    district: str | None = Field(default=None, max_length=255)
    location: str | None = Field(default=None, max_length=500)
    category: str | None = Field(default=None, max_length=500)
    vibes: str | None = Field(default=None, max_length=500)
    activities: str | None = None
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    arrival_lat: float | None = Field(default=None, ge=-90, le=90)
    arrival_lng: float | None = Field(default=None, ge=-180, le=180)
    arrival_source_url: str | None = Field(default=None, max_length=2048)
    arrival_verified_at: datetime | None = None
    route_ready: bool | None = None
    access_trail_polyline: str | None = None
    island_group: str | None = Field(default=None, max_length=50)
    estimated_cost: Decimal | None = Field(
        default=None,
        ge=0,
        max_digits=10,
        decimal_places=2,
    )
    entrance_fee: str | None = Field(default=None, max_length=255)
    overnight_fee: str | None = Field(default=None, max_length=255)
    operating_hours: str | None = Field(default=None, max_length=255)
    best_time_to_visit: str | None = None
    how_to_get_there: str | None = None
    estimated_travel_time: str | None = None
    travel_notes: str | None = None
    what_to_bring: str | None = None
    is_kid_friendly: bool | None = None
    is_wheelchair_accessible: bool | None = None
    is_pet_friendly: bool | None = None
    is_elderly_friendly: bool | None = None
    family_friendly: bool | None = None
    couple_friendly: bool | None = None
    group_friendly: bool | None = None
    budget_class: str | None = Field(default=None, max_length=50)
    crowd_level: str | None = Field(default=None, max_length=50)
    difficulty_level: str | None = Field(default=None, max_length=50)
    stay_duration_type: str | None = Field(default=None, max_length=50)
    transport_accessibility: str | None = Field(default=None, max_length=100)
    image_url: str | None = Field(default=None, max_length=2048)
    is_active: bool | None = None

    @field_validator("arrival_source_url")
    @classmethod
    def validate_arrival_source_url(cls, value: str | None) -> str | None:
        return _validate_arrival_source_url(value)

    @field_validator("access_trail_polyline")
    @classmethod
    def validate_access_trail_polyline(cls, value: str | None) -> str | None:
        return _validate_access_trail_polyline(value)

    @field_validator("island_group")
    @classmethod
    def normalize_island_group(cls, value: str | None) -> str | None:
        return _normalize_optional_slug(value)


class DestinationResponse(DestinationBase):
    destination_id: int
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


def _validate_arrival_source_url(value: str | None) -> str | None:
    if value is None:
        return None
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("arrival_source_url must be an HTTP or HTTPS URL")
    return value


def _validate_access_trail_polyline(value: str | None) -> str | None:
    return validate_polyline5(value)


def _normalize_optional_slug(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None


class FacetSubtype(BaseModel):
    key: str
    label: str
    count: int


class FacetGroup(BaseModel):
    key: str
    label: str
    description: str
    count: int
    subtypes: list[FacetSubtype]


class FacetCategory(BaseModel):
    key: str
    label: str
    count: int
    group: str
    groups: list[str] = Field(default_factory=list)
    examples: list[str] = Field(default_factory=list)


class DestinationFacetsResponse(BaseModel):
    """Preference groups and live categories, for the traveler's preference and browse chips."""

    total_places: int
    groups: list[FacetGroup]
    categories: list[FacetCategory] = Field(default_factory=list)


class DestinationListQuery(BaseModel):
    search: str | None = None
    district: str | None = None
    category: str | None = None
    budget_class: str | None = None
    difficulty_level: str | None = None
    kid_friendly: bool | None = None
    wheelchair_accessible: bool | None = None
    pet_friendly: bool | None = None
    family_friendly: bool | None = None
    couple_friendly: bool | None = None
    group_friendly: bool | None = None
    limit: int = Field(default=50, ge=1, le=100)
    offset: int = Field(default=0, ge=0)
    include_inactive: bool = False


class HoursWindowIn(BaseModel):
    """One weekday's opening window (Monday = 0); `is_closed` days carry no times."""

    model_config = ConfigDict(from_attributes=True)

    weekday: int = Field(ge=0, le=6)
    is_closed: bool = False
    opens_at: time | None = None
    closes_at: time | None = None
    last_admission_at: time | None = None

    @model_validator(mode="after")
    def check_window(self) -> "HoursWindowIn":
        if self.is_closed:
            if self.opens_at or self.closes_at or self.last_admission_at:
                raise ValueError("A closed day cannot have opening times.")
        elif self.opens_at is None or self.closes_at is None:
            raise ValueError("An open day needs opens_at and closes_at.")
        elif self.opens_at >= self.closes_at:
            raise ValueError("opens_at must be earlier than closes_at.")
        elif self.last_admission_at is not None and not (
            self.opens_at <= self.last_admission_at <= self.closes_at
        ):
            raise ValueError("last_admission_at must fall within the opening window.")
        return self


class HoursExceptionIn(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    starts_on: date
    ends_on: date
    is_closed: bool = False
    opens_at: time | None = None
    closes_at: time | None = None
    reason: str | None = Field(default=None, max_length=255)

    @model_validator(mode="after")
    def check_exception(self) -> "HoursExceptionIn":
        if self.starts_on > self.ends_on:
            raise ValueError("starts_on must not be after ends_on.")
        if self.is_closed:
            if self.opens_at or self.closes_at:
                raise ValueError("A closed date cannot have opening times.")
        elif self.opens_at is None or self.closes_at is None:
            raise ValueError("An open date needs opens_at and closes_at.")
        elif self.opens_at >= self.closes_at:
            raise ValueError("opens_at must be earlier than closes_at.")
        return self


class DestinationHoursUpdate(BaseModel):
    """Replaces everything about a place's structured hours in one save."""

    open_24_hours: bool | None = None
    hours_source_url: str | None = Field(default=None, max_length=2048)
    hours_verified_at: datetime | None = None
    weekly: list[HoursWindowIn] = Field(default_factory=list, max_length=28)
    exceptions: list[HoursExceptionIn] = Field(default_factory=list, max_length=60)

    @field_validator("hours_source_url")
    @classmethod
    def validate_source_url(cls, value: str | None) -> str | None:
        if value is None:
            return None
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("hours_source_url must be an HTTP or HTTPS URL")
        return value

    @model_validator(mode="after")
    def check_schedule(self) -> "DestinationHoursUpdate":
        if self.open_24_hours and self.weekly:
            raise ValueError("A place open 24 hours has no weekly windows.")
        # Windows on one weekday must not overlap, and a closed day stands alone.
        by_day: dict[int, list[HoursWindowIn]] = {}
        for row in self.weekly:
            by_day.setdefault(row.weekday, []).append(row)
        for rows in by_day.values():
            if any(r.is_closed for r in rows) and len(rows) > 1:
                raise ValueError("A closed day cannot also have an opening window.")
            windows = sorted((r.opens_at, r.closes_at) for r in rows if not r.is_closed)
            for (_, end), (start, _) in zip(windows, windows[1:]):
                if start < end:
                    raise ValueError("Opening windows on one day must not overlap.")
        return self


class DestinationHoursResponse(BaseModel):
    destination_id: int
    open_24_hours: bool | None = None
    hours_source_url: str | None = None
    hours_verified_at: datetime | None = None
    weekly: list[HoursWindowIn] = Field(default_factory=list)
    exceptions: list[HoursExceptionIn] = Field(default_factory=list)
    summary: str | None = None
    # supported (structured and checked within a year), estimated, or unknown.
    data_quality: str = "unknown"
