"""Pydantic request and response models for admin sea-port and sea-link CRUD."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, computed_field, field_validator, model_validator

from app.features.routes.polyline import validate_polyline5

VesselType = Literal["roro_barge", "passenger_ferry", "pump_boat"]


def _validate_optional_url(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    if not trimmed:
        return None
    parsed = urlsplit(trimmed)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("source_url must be an HTTP or HTTPS URL")
    return trimmed


def _normalize_required_text(value: str, *, field_name: str) -> str:
    trimmed = value.strip()
    if len(trimmed) < 2:
        raise ValueError(f"{field_name} must be at least 2 characters.")
    return trimmed


def _normalize_optional_text(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None


class SeaPortCreate(BaseModel):
    name: str = Field(min_length=2, max_length=255)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    island_group: str = Field(min_length=2, max_length=50)
    province: str | None = Field(default=None, max_length=255)
    notes: str | None = None
    source_url: str | None = Field(default=None, max_length=2048)
    verified: bool | None = None
    is_active: bool = True

    @field_validator("name")
    @classmethod
    def check_name(cls, value: str) -> str:
        return _normalize_required_text(value, field_name="name")

    @field_validator("island_group")
    @classmethod
    def check_island_group(cls, value: str) -> str:
        return _normalize_required_text(value.lower(), field_name="island_group")

    @field_validator("province", "notes")
    @classmethod
    def clean_optional(cls, value: str | None) -> str | None:
        return _normalize_optional_text(value)

    @field_validator("source_url")
    @classmethod
    def check_source_url(cls, value: str | None) -> str | None:
        return _validate_optional_url(value)


class SeaPortUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=255)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    island_group: str | None = Field(default=None, min_length=2, max_length=50)
    province: str | None = Field(default=None, max_length=255)
    notes: str | None = None
    source_url: str | None = Field(default=None, max_length=2048)
    verified: bool | None = None
    is_active: bool | None = None

    @field_validator("name")
    @classmethod
    def check_name(cls, value: str | None) -> str | None:
        return None if value is None else _normalize_required_text(value, field_name="name")

    @field_validator("island_group")
    @classmethod
    def check_island_group(cls, value: str | None) -> str | None:
        return (
            None
            if value is None
            else _normalize_required_text(value.lower(), field_name="island_group")
        )

    @field_validator("province", "notes")
    @classmethod
    def clean_optional(cls, value: str | None) -> str | None:
        return _normalize_optional_text(value)

    @field_validator("source_url")
    @classmethod
    def check_source_url(cls, value: str | None) -> str | None:
        return _validate_optional_url(value)


class SeaPortResponse(BaseModel):
    port_id: int
    name: str
    lat: float
    lng: float
    island_group: str
    province: str | None = None
    notes: str | None = None
    source_url: str | None = None
    verified_at: datetime | None = None
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)

    @computed_field
    @property
    def verified(self) -> bool:
        return self.verified_at is not None


class SeaLinkCreate(BaseModel):
    from_port_id: int = Field(gt=0)
    to_port_id: int = Field(gt=0)
    bidirectional: bool = True
    vessel_type: VesselType = "roro_barge"
    allows_private_vehicle: bool = False
    crossing_minutes: int = Field(gt=0, le=1440)
    typical_wait_minutes: int = Field(default=0, ge=0, le=1440)
    schedule_text: str | None = Field(default=None, max_length=500)
    fare_passenger: Decimal | None = Field(default=None, ge=0, max_digits=10, decimal_places=2)
    fare_vehicle: Decimal | None = Field(default=None, ge=0, max_digits=10, decimal_places=2)
    geometry_polyline: str | None = None
    source_url: str | None = Field(default=None, max_length=2048)
    verified: bool | None = None
    is_active: bool = True

    @model_validator(mode="after")
    def validate_distinct_ports(self) -> "SeaLinkCreate":
        if self.from_port_id == self.to_port_id:
            raise ValueError("from_port_id and to_port_id must be different ports.")
        return self

    @field_validator("geometry_polyline")
    @classmethod
    def check_geometry(cls, value: str | None) -> str | None:
        return validate_polyline5(value)

    @field_validator("schedule_text")
    @classmethod
    def clean_schedule(cls, value: str | None) -> str | None:
        return _normalize_optional_text(value)

    @field_validator("source_url")
    @classmethod
    def check_source_url(cls, value: str | None) -> str | None:
        return _validate_optional_url(value)


class SeaLinkUpdate(BaseModel):
    from_port_id: int | None = Field(default=None, gt=0)
    to_port_id: int | None = Field(default=None, gt=0)
    bidirectional: bool | None = None
    vessel_type: VesselType | None = None
    allows_private_vehicle: bool | None = None
    crossing_minutes: int | None = Field(default=None, gt=0, le=1440)
    typical_wait_minutes: int | None = Field(default=None, ge=0, le=1440)
    schedule_text: str | None = Field(default=None, max_length=500)
    fare_passenger: Decimal | None = Field(default=None, ge=0, max_digits=10, decimal_places=2)
    fare_vehicle: Decimal | None = Field(default=None, ge=0, max_digits=10, decimal_places=2)
    geometry_polyline: str | None = None
    source_url: str | None = Field(default=None, max_length=2048)
    verified: bool | None = None
    is_active: bool | None = None

    @field_validator("geometry_polyline")
    @classmethod
    def check_geometry(cls, value: str | None) -> str | None:
        return validate_polyline5(value)

    @field_validator("schedule_text")
    @classmethod
    def clean_schedule(cls, value: str | None) -> str | None:
        return _normalize_optional_text(value)

    @field_validator("source_url")
    @classmethod
    def check_source_url(cls, value: str | None) -> str | None:
        return _validate_optional_url(value)


class SeaLinkResponse(BaseModel):
    link_id: int
    from_port_id: int
    to_port_id: int
    bidirectional: bool
    vessel_type: VesselType
    allows_private_vehicle: bool
    crossing_minutes: int
    typical_wait_minutes: int
    schedule_text: str | None = None
    fare_passenger: Decimal | None = None
    fare_vehicle: Decimal | None = None
    geometry_polyline: str | None = None
    source_url: str | None = None
    verified_at: datetime | None = None
    is_active: bool
    created_at: datetime
    updated_at: datetime
    from_port_name: str | None = None
    to_port_name: str | None = None
    from_island_group: str | None = None
    to_island_group: str | None = None
    from_lat: float | None = None
    from_lng: float | None = None
    to_lat: float | None = None
    to_lng: float | None = None

    model_config = ConfigDict(from_attributes=True)

    @computed_field
    @property
    def verified(self) -> bool:
        return self.verified_at is not None

    @classmethod
    def from_orm_link(cls, link) -> "SeaLinkResponse":
        from_port = getattr(link, "from_port", None)
        to_port = getattr(link, "to_port", None)
        return cls.model_validate({
            "link_id": link.link_id,
            "from_port_id": link.from_port_id,
            "to_port_id": link.to_port_id,
            "bidirectional": link.bidirectional,
            "vessel_type": link.vessel_type,
            "allows_private_vehicle": link.allows_private_vehicle,
            "crossing_minutes": link.crossing_minutes,
            "typical_wait_minutes": link.typical_wait_minutes,
            "schedule_text": link.schedule_text,
            "fare_passenger": link.fare_passenger,
            "fare_vehicle": link.fare_vehicle,
            "geometry_polyline": link.geometry_polyline,
            "source_url": link.source_url,
            "verified_at": link.verified_at,
            "is_active": link.is_active,
            "created_at": link.created_at,
            "updated_at": link.updated_at,
            "from_port_name": from_port.name if from_port is not None else None,
            "to_port_name": to_port.name if to_port is not None else None,
            "from_island_group": from_port.island_group if from_port is not None else None,
            "to_island_group": to_port.island_group if to_port is not None else None,
            "from_lat": from_port.lat if from_port is not None else None,
            "from_lng": from_port.lng if from_port is not None else None,
            "to_lat": to_port.lat if to_port is not None else None,
            "to_lng": to_port.lng if to_port is not None else None,
        })
