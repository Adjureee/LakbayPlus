from datetime import datetime
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
