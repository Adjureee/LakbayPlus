"""Request and response models for commute directions."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, computed_field, field_validator

Vehicle = Literal[
    "jeepney", "tricycle", "habal_habal", "van", "bus", "taxi", "ferry", "walk", "fee",
]
ChargingUnit = Literal["per_person", "per_trip"]

# Steps that are an actual ride (a fee or a walk is not a transfer).
RIDES = frozenset({"jeepney", "tricycle", "habal_habal", "van", "bus", "taxi", "ferry"})

Place = Annotated[str, StringConstraints(strip_whitespace=True, max_length=255)]


def _blank_to_none(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None


class CommuteStepInput(BaseModel):
    vehicle: Vehicle
    from_place: Place | None = None
    to_place: Place | None = None
    get_off_at: Place | None = None
    minutes: int | None = Field(default=None, ge=0, le=1440)
    fare_php: Decimal | None = Field(default=None, ge=0, le=100000, max_digits=10, decimal_places=2)
    charging_unit: ChargingUnit | None = None
    notes: str | None = Field(default=None, max_length=1000)

    @field_validator("from_place", "to_place", "get_off_at", "notes")
    @classmethod
    def blank_is_none(cls, value: str | None) -> str | None:
        return _blank_to_none(value)


class CommuteRouteInput(BaseModel):
    start_area: Place | None = None
    notes: str | None = Field(default=None, max_length=2000)
    source_url: str | None = Field(default=None, max_length=2048)
    is_verified: bool = False
    is_active: bool = True
    steps: list[CommuteStepInput] = Field(min_length=1, max_length=12)

    @field_validator("start_area", "notes")
    @classmethod
    def blank_is_none(cls, value: str | None) -> str | None:
        return _blank_to_none(value)

    @field_validator("source_url")
    @classmethod
    def check_url(cls, value: str | None) -> str | None:
        value = _blank_to_none(value)
        if value is None:
            return None
        parsed = urlsplit(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("source_url must be an HTTP or HTTPS URL")
        return value


class CommuteStepResponse(CommuteStepInput):
    model_config = ConfigDict(from_attributes=True)

    commute_step_id: int
    step_order: int


class CommuteRouteResponse(BaseModel):
    """One way to reach a place, with totals worked out from its steps."""

    model_config = ConfigDict(from_attributes=True)

    commute_route_id: int
    destination_id: int
    start_area: str | None
    notes: str | None
    source_url: str | None
    is_verified: bool
    verified_at: datetime | None
    is_active: bool
    steps: list[CommuteStepResponse]

    @computed_field  # type: ignore[prop-decorator]
    @property
    def total_minutes(self) -> int:
        """Minutes of the steps that have one; see minutes_complete."""
        return sum(step.minutes or 0 for step in self.steps)

    @computed_field  # type: ignore[prop-decorator]
    @property
    def minutes_complete(self) -> bool:
        """True when every ride and walk has its time, so the total is the whole trip."""
        return all(step.minutes is not None for step in self.steps if step.vehicle != "fee")

    @computed_field  # type: ignore[prop-decorator]
    @property
    def total_fare_per_person_php(self) -> Decimal:
        """Fares that are stated per person. Other fares are not added in."""
        return sum(
            (step.fare_php for step in self.steps
             if step.fare_php is not None and step.charging_unit == "per_person"),
            Decimal("0.00"),
        )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def fare_complete(self) -> bool:
        """True when every ride and fee has a per-person fare, so the total is the whole fare."""
        return all(
            step.fare_php is not None and step.charging_unit == "per_person"
            for step in self.steps
            if step.vehicle != "walk"
        )

    @computed_field  # type: ignore[prop-decorator]
    @property
    def transfers(self) -> int:
        return max(0, sum(1 for step in self.steps if step.vehicle in RIDES) - 1)


class CommuteOptionsResponse(BaseModel):
    destination_id: int
    routes: list[CommuteRouteResponse]


class CommuteDraftRequest(BaseModel):
    # Defaults to the place's saved "how to get there" notes.
    notes: str | None = Field(default=None, max_length=4000)


class CommuteDraftResponse(BaseModel):
    """A draft for an admin to review. Nothing is saved and nothing is verified."""

    destination_id: int
    source_text: str
    routes: list[CommuteRouteInput]
    unclear: list[str]
    model_id: str
