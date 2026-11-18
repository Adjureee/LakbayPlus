from datetime import date, datetime, time
from decimal import Decimal

from geoalchemy2 import Geography
from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Numeric,
    SmallInteger,
    String,
    Text,
    Time,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


class Destination(Base):
    __tablename__ = "destinations"
    __table_args__ = (
        CheckConstraint("lat >= -90 AND lat <= 90", name="ck_destinations_lat_range"),
        CheckConstraint(
            "lng >= -180 AND lng <= 180",
            name="ck_destinations_lng_range",
        ),
        CheckConstraint(
            "(arrival_lat IS NULL AND arrival_lng IS NULL) OR "
            "(arrival_lat IS NOT NULL AND arrival_lng IS NOT NULL)",
            name="ck_destinations_arrival_pair",
        ),
        CheckConstraint(
            "arrival_lat IS NULL OR (arrival_lat >= -90 AND arrival_lat <= 90)",
            name="ck_destinations_arrival_lat_range",
        ),
        CheckConstraint(
            "arrival_lng IS NULL OR (arrival_lng >= -180 AND arrival_lng <= 180)",
            name="ck_destinations_arrival_lng_range",
        ),
        CheckConstraint(
            "route_ready = false OR "
            "(arrival_lat IS NOT NULL AND arrival_lng IS NOT NULL AND "
            "arrival_source_url IS NOT NULL AND arrival_verified_at IS NOT NULL)",
            name="ck_destinations_route_ready_arrival",
        ),
        CheckConstraint(
            "estimated_cost >= 0",
            name="ck_destinations_estimated_cost_non_negative",
        ),
        CheckConstraint(
            "operating_status IS NULL OR operating_status IN "
            "('open', 'temporarily_closed', 'permanently_closed')",
            name="ck_destinations_operating_status",
        ),
        CheckConstraint(
            "booking_requirement IS NULL OR booking_requirement IN "
            "('required', 'recommended', 'not_required')",
            name="ck_destinations_booking_requirement",
        ),
        CheckConstraint(
            "(typical_visit_min_minutes IS NULL OR typical_visit_min_minutes > 0) AND "
            "(typical_visit_max_minutes IS NULL OR typical_visit_max_minutes > 0) AND "
            "(typical_visit_min_minutes IS NULL OR typical_visit_max_minutes IS NULL OR "
            "typical_visit_min_minutes <= typical_visit_max_minutes)",
            name="ck_destinations_typical_visit",
        ),
        Index("ix_destinations_geom", "geom", postgresql_using="gist"),
    )

    destination_id: Mapped[int] = mapped_column(primary_key=True, index=True)
    name: Mapped[str] = mapped_column(String(255), index=True)
    description: Mapped[str | None] = mapped_column(Text)
    district: Mapped[str | None] = mapped_column(String(255), index=True)
    location: Mapped[str | None] = mapped_column(String(500))
    category: Mapped[str | None] = mapped_column(String(500), index=True)
    vibes: Mapped[str | None] = mapped_column(String(500))
    activities: Mapped[str | None] = mapped_column(Text)
    lat: Mapped[float] = mapped_column(nullable=False)
    lng: Mapped[float] = mapped_column(nullable=False)
    arrival_lat: Mapped[float | None] = mapped_column(nullable=True)
    arrival_lng: Mapped[float | None] = mapped_column(nullable=True)
    arrival_source_url: Mapped[str | None] = mapped_column(String(2048))
    arrival_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    route_ready: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    access_trail_polyline: Mapped[str | None] = mapped_column(Text)
    # Island the destination is on ("samal", "talikud", ...); NULL is mainland.
    # Trips between island groups are routed through piers (sea_links).
    island_group: Mapped[str | None] = mapped_column(String(50), index=True)
    geom: Mapped[object | None] = mapped_column(
        Geography(geometry_type="POINT", srid=4326, spatial_index=False),
    )
    estimated_cost: Mapped[Decimal | None] = mapped_column(Numeric(10, 2), nullable=True)
    entrance_fee: Mapped[str | None] = mapped_column(String(255))
    overnight_fee: Mapped[str | None] = mapped_column(String(255))
    operating_hours: Mapped[str | None] = mapped_column(String(255))
    # Structured hours live in destination_hours; these say how far to trust them.
    open_24_hours: Mapped[bool | None] = mapped_column(Boolean)
    hours_source_url: Mapped[str | None] = mapped_column(String(2048))
    hours_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Same for the structured prices in destination_prices.
    fees_source_url: Mapped[str | None] = mapped_column(String(2048))
    fees_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Whether it is open at all, and how to book. NULL means unknown.
    operating_status: Mapped[str | None] = mapped_column(String(20))
    booking_requirement: Mapped[str | None] = mapped_column(String(20))
    booking_note: Mapped[str | None] = mapped_column(Text)
    parking_note: Mapped[str | None] = mapped_column(Text)
    typical_visit_min_minutes: Mapped[int | None] = mapped_column()
    typical_visit_max_minutes: Mapped[int | None] = mapped_column()
    best_time_to_visit: Mapped[str | None] = mapped_column(Text)
    best_time_basis: Mapped[str | None] = mapped_column(Text)
    how_to_get_there: Mapped[str | None] = mapped_column(Text)
    estimated_travel_time: Mapped[str | None] = mapped_column(Text)
    travel_notes: Mapped[str | None] = mapped_column(Text)
    what_to_bring: Mapped[str | None] = mapped_column(Text)
    is_kid_friendly: Mapped[bool | None] = mapped_column(Boolean)
    is_wheelchair_accessible: Mapped[bool | None] = mapped_column(Boolean)
    is_pet_friendly: Mapped[bool | None] = mapped_column(Boolean)
    is_elderly_friendly: Mapped[bool | None] = mapped_column(Boolean)
    family_friendly: Mapped[bool | None] = mapped_column(Boolean)
    couple_friendly: Mapped[bool | None] = mapped_column(Boolean)
    group_friendly: Mapped[bool | None] = mapped_column(Boolean)
    budget_class: Mapped[str | None] = mapped_column(String(50), index=True)
    crowd_level: Mapped[str | None] = mapped_column(String(50))
    difficulty_level: Mapped[str | None] = mapped_column(String(50), index=True)
    stay_duration_type: Mapped[str | None] = mapped_column(String(50))
    transport_accessibility: Mapped[str | None] = mapped_column(String(100))
    image_url: Mapped[str | None] = mapped_column(Text)
    # Photo attribution (migration 2026_11_11_1200).
    image_public_id: Mapped[str | None] = mapped_column(String(255))
    image_credit: Mapped[str | None] = mapped_column(String(500))
    image_license: Mapped[str | None] = mapped_column(String(100))
    image_source_url: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
    )

    accommodations: Mapped[list["Accommodation"]] = relationship(
        back_populates="destination",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )
    transportations: Mapped[list["Transportation"]] = relationship(
        back_populates="destination",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )


class DestinationCandidate(Base):
    """Unpublished place awaiting an administrator's visitor review.

    source = 'osm' for an OpenStreetMap object (OSM identity required and
    unique); 'manual' for a pin an admin dropped on the admin map.
    """

    __tablename__ = "destination_candidates"
    __table_args__ = (
        UniqueConstraint("osm_type", "osm_id", name="uq_destination_candidates_osm_identity"),
        CheckConstraint("lat >= -90 AND lat <= 90", name="ck_destination_candidates_lat_range"),
        CheckConstraint("lng >= -180 AND lng <= 180", name="ck_destination_candidates_lng_range"),
        CheckConstraint("estimated_cost IS NULL OR estimated_cost >= 0", name="ck_destination_candidates_cost_non_negative"),
        CheckConstraint("review_status IN ('staged', 'rejected', 'published')", name="ck_destination_candidates_review_status"),
        CheckConstraint("source IN ('osm', 'manual')", name="ck_destination_candidates_source"),
        CheckConstraint(
            "source <> 'osm' OR "
            "(osm_type IS NOT NULL AND osm_id IS NOT NULL AND osm_url IS NOT NULL)",
            name="ck_destination_candidates_osm_identity_for_osm",
        ),
        Index("ix_destination_candidates_review_status", "review_status"),
    )

    candidate_id: Mapped[int] = mapped_column(primary_key=True)
    source: Mapped[str] = mapped_column(String(20), nullable=False, default="osm", server_default="osm")
    osm_type: Mapped[str | None] = mapped_column(String(16))
    osm_id: Mapped[int | None] = mapped_column(BigInteger)
    osm_url: Mapped[str | None] = mapped_column(String(2048))
    source_area: Mapped[str] = mapped_column(String(100), nullable=False)
    source_tag: Mapped[str] = mapped_column(String(255), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    lat: Mapped[float] = mapped_column(nullable=False)
    lng: Mapped[float] = mapped_column(nullable=False)
    suggested_category: Mapped[str | None] = mapped_column(String(500))
    category: Mapped[str | None] = mapped_column(String(500))
    visitor_purpose: Mapped[str | None] = mapped_column(Text)
    description: Mapped[str | None] = mapped_column(Text)
    district: Mapped[str | None] = mapped_column(String(255))
    location: Mapped[str | None] = mapped_column(String(500))
    vibes: Mapped[str | None] = mapped_column(String(500))
    activities: Mapped[str | None] = mapped_column(Text)
    estimated_cost: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    entrance_fee: Mapped[str | None] = mapped_column(String(255))
    overnight_fee: Mapped[str | None] = mapped_column(String(255))
    operating_hours: Mapped[str | None] = mapped_column(String(255))
    access_policy: Mapped[str | None] = mapped_column(String(20))
    # Island the place is on, from OSM island outlines; copied on publish so
    # island destinations route through a pier. NULL is mainland.
    island_group: Mapped[str | None] = mapped_column(String(50))
    access_source_url: Mapped[str | None] = mapped_column(String(2048))
    access_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    review_status: Mapped[str] = mapped_column(String(20), nullable=False, default="staged", server_default="staged")
    review_notes: Mapped[str | None] = mapped_column(Text)
    destination_id: Mapped[int | None] = mapped_column(ForeignKey("destinations.destination_id"), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())


class DestinationHours(Base):
    """One opening window of a place on one weekday (Monday = 0).

    A place may have several rows for a day (a lunch break). No rows means the hours
    are unknown, not that the place is closed.
    """

    __tablename__ = "destination_hours"
    __table_args__ = (
        CheckConstraint("weekday >= 0 AND weekday <= 6", name="ck_destination_hours_weekday"),
        CheckConstraint(
            "(is_closed AND opens_at IS NULL AND closes_at IS NULL "
            "AND last_admission_at IS NULL) OR "
            "(NOT is_closed AND opens_at IS NOT NULL AND closes_at IS NOT NULL "
            "AND opens_at < closes_at)",
            name="ck_destination_hours_window",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    destination_id: Mapped[int] = mapped_column(
        ForeignKey("destinations.destination_id", ondelete="CASCADE"), index=True,
    )
    weekday: Mapped[int] = mapped_column(SmallInteger)
    opens_at: Mapped[time | None] = mapped_column(Time)
    closes_at: Mapped[time | None] = mapped_column(Time)
    is_closed: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    last_admission_at: Mapped[time | None] = mapped_column(Time)


class DestinationHourException(Base):
    """Dates when the weekly hours do not apply (a holiday, a closure)."""

    __tablename__ = "destination_hour_exceptions"
    __table_args__ = (
        CheckConstraint("starts_on <= ends_on", name="ck_destination_hour_exceptions_range"),
        CheckConstraint(
            "(is_closed AND opens_at IS NULL AND closes_at IS NULL) OR "
            "(NOT is_closed AND opens_at IS NOT NULL AND closes_at IS NOT NULL "
            "AND opens_at < closes_at)",
            name="ck_destination_hour_exceptions_window",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    destination_id: Mapped[int] = mapped_column(
        ForeignKey("destinations.destination_id", ondelete="CASCADE"), index=True,
    )
    starts_on: Mapped[date] = mapped_column(Date)
    ends_on: Mapped[date] = mapped_column(Date)
    is_closed: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    opens_at: Mapped[time | None] = mapped_column(Time)
    closes_at: Mapped[time | None] = mapped_column(Time)
    reason: Mapped[str | None] = mapped_column(String(255))


class DestinationPrice(Base):
    """One price a place charges: an item, who pays it, and per what.

    No row for an item means the price is unknown. A row with amount 0 means the source
    says it is free.
    """

    __tablename__ = "destination_prices"
    __table_args__ = (
        CheckConstraint(
            "item IN ('entrance', 'overnight', 'parking', 'cottage', 'other')",
            name="ck_destination_prices_item",
        ),
        CheckConstraint(
            "audience IN ('adult', 'child', 'senior', 'pwd', 'student', 'resident', "
            "'non_resident', 'everyone')",
            name="ck_destination_prices_audience",
        ),
        CheckConstraint(
            "unit IN ('per_person', 'per_group', 'per_vehicle', 'per_night')",
            name="ck_destination_prices_unit",
        ),
        CheckConstraint("amount >= 0", name="ck_destination_prices_amount"),
        CheckConstraint(
            "(age_min IS NULL OR age_min >= 0) AND (age_max IS NULL OR age_max >= 0) AND "
            "(age_min IS NULL OR age_max IS NULL OR age_min <= age_max)",
            name="ck_destination_prices_ages",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    destination_id: Mapped[int] = mapped_column(
        ForeignKey("destinations.destination_id", ondelete="CASCADE"), index=True,
    )
    item: Mapped[str] = mapped_column(String(20))
    audience: Mapped[str] = mapped_column(String(20))
    amount: Mapped[Decimal] = mapped_column(Numeric(10, 2))
    unit: Mapped[str] = mapped_column(String(20))
    age_min: Mapped[int | None] = mapped_column(SmallInteger)
    age_max: Mapped[int | None] = mapped_column(SmallInteger)
    note: Mapped[str | None] = mapped_column(Text)


class DestinationActivity(Base):
    """One thing to do at a place, with its own availability, cost and rules.

    A place being open does not mean every activity is available; an unset field means
    unknown, never "no" or "free".
    """

    __tablename__ = "destination_activities"
    __table_args__ = (
        CheckConstraint(
            "availability IS NULL OR availability IN "
            "('always', 'scheduled', 'seasonal', 'by_arrangement')",
            name="ck_destination_activities_availability",
        ),
        CheckConstraint(
            "effort_level IS NULL OR effort_level IN ('easy', 'moderate', 'challenging')",
            name="ck_destination_activities_effort",
        ),
        CheckConstraint(
            "weather_dependency IS NULL OR weather_dependency IN "
            "('none', 'dry_weather', 'calm_seas', 'daylight')",
            name="ck_destination_activities_weather",
        ),
        CheckConstraint(
            "extra_fee IS NULL OR extra_fee >= 0", name="ck_destination_activities_fee",
        ),
        CheckConstraint(
            "(duration_min_minutes IS NULL OR duration_min_minutes > 0) AND "
            "(duration_max_minutes IS NULL OR duration_max_minutes > 0) AND "
            "(duration_min_minutes IS NULL OR duration_max_minutes IS NULL OR "
            "duration_min_minutes <= duration_max_minutes)",
            name="ck_destination_activities_duration",
        ),
        CheckConstraint(
            "(min_age IS NULL OR min_age >= 0) AND (max_age IS NULL OR max_age >= 0) AND "
            "(min_age IS NULL OR max_age IS NULL OR min_age <= max_age)",
            name="ck_destination_activities_ages",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    destination_id: Mapped[int] = mapped_column(
        ForeignKey("destinations.destination_id", ondelete="CASCADE"), index=True,
    )
    sort_order: Mapped[int] = mapped_column(default=0, server_default="0")
    name: Mapped[str] = mapped_column(String(255))
    description: Mapped[str | None] = mapped_column(Text)
    availability: Mapped[str | None] = mapped_column(String(20))
    schedule_note: Mapped[str | None] = mapped_column(Text)
    last_admission_at: Mapped[time | None] = mapped_column(Time)
    duration_min_minutes: Mapped[int | None] = mapped_column()
    duration_max_minutes: Mapped[int | None] = mapped_column()
    extra_fee: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    fee_included_in_admission: Mapped[bool | None] = mapped_column(Boolean)
    effort_level: Mapped[str | None] = mapped_column(String(20))
    accessibility_note: Mapped[str | None] = mapped_column(Text)
    min_age: Mapped[int | None] = mapped_column(SmallInteger)
    max_age: Mapped[int | None] = mapped_column(SmallInteger)
    restriction_note: Mapped[str | None] = mapped_column(Text)
    weather_dependency: Mapped[str | None] = mapped_column(String(20))
    best_time_note: Mapped[str | None] = mapped_column(Text)
    best_time_basis: Mapped[str | None] = mapped_column(Text)
    source_url: Mapped[str | None] = mapped_column(String(2048))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
