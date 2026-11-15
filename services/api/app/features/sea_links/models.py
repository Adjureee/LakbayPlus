"""Piers and boat connections used to route trips to Davao's islands.

A route never crosses water by road. When consecutive stops are on different
island groups, the router drives to a departure pier, takes a sea link, and
drives on from the arrival pier.
"""

from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

# Island group of every place not on an island. Destinations with a NULL
# island_group are treated as mainland.
MAINLAND = "mainland"

VESSEL_TYPES = ("roro_barge", "passenger_ferry", "pump_boat")


class SeaPort(Base):
    __tablename__ = "sea_ports"
    __table_args__ = (
        CheckConstraint("lat >= -90 AND lat <= 90", name="ck_sea_ports_lat_range"),
        CheckConstraint("lng >= -180 AND lng <= 180", name="ck_sea_ports_lng_range"),
    )

    port_id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False, unique=True)
    # Road-side gate where travelers and vehicles board, not the pier head.
    lat: Mapped[float] = mapped_column(nullable=False)
    lng: Mapped[float] = mapped_column(nullable=False)
    island_group: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    province: Mapped[str | None] = mapped_column(String(255))
    notes: Mapped[str | None] = mapped_column(Text)
    source_url: Mapped[str | None] = mapped_column(String(2048))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(),
    )


class SeaLink(Base):
    """A boat service between two piers; bidirectional unless stated."""

    __tablename__ = "sea_links"
    __table_args__ = (
        CheckConstraint("from_port_id <> to_port_id", name="ck_sea_links_distinct_ports"),
        CheckConstraint("crossing_minutes > 0", name="ck_sea_links_crossing_positive"),
        CheckConstraint("typical_wait_minutes >= 0", name="ck_sea_links_wait_non_negative"),
        CheckConstraint(
            "vessel_type IN ('roro_barge', 'passenger_ferry', 'pump_boat')",
            name="ck_sea_links_vessel_type",
        ),
    )

    link_id: Mapped[int] = mapped_column(primary_key=True)
    from_port_id: Mapped[int] = mapped_column(
        ForeignKey("sea_ports.port_id", ondelete="CASCADE"), nullable=False, index=True,
    )
    to_port_id: Mapped[int] = mapped_column(
        ForeignKey("sea_ports.port_id", ondelete="CASCADE"), nullable=False, index=True,
    )
    bidirectional: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    vessel_type: Mapped[str] = mapped_column(String(30), nullable=False)
    allows_private_vehicle: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false",
    )
    crossing_minutes: Mapped[int] = mapped_column(Integer, nullable=False)
    typical_wait_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    schedule_text: Mapped[str | None] = mapped_column(String(500))
    fare_passenger: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    fare_vehicle: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    # Optional encoded polyline5 of the boat track; otherwise pier to pier.
    geometry_polyline: Mapped[str | None] = mapped_column(Text)
    source_url: Mapped[str | None] = mapped_column(String(2048))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(),
    )

    from_port: Mapped[SeaPort] = relationship(foreign_keys=[from_port_id], lazy="joined")
    to_port: Mapped[SeaPort] = relationship(foreign_keys=[to_port_id], lazy="joined")
