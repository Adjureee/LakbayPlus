"""How to reach a place by public transport, step by step.

A commute route is one way to get to a destination: for example "Davao City
Proper": Jeepney to Bemwa Farm, then a tricycle to the entry gate, then the local
community fee. The steps are entered (or drafted from the place's notes and
reviewed) by an admin. A route is shown to travelers only once it is verified.
Anything the admin does not know stays empty; nothing is filled in.
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
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

# "fee" is a payment with no ride (an entrance or community fee).
VEHICLES = (
    "jeepney", "tricycle", "habal_habal", "van", "bus", "taxi", "ferry", "walk", "fee",
)
CHARGING_UNITS = ("per_person", "per_trip")


class CommuteRoute(Base):
    __tablename__ = "commute_routes"

    commute_route_id: Mapped[int] = mapped_column(primary_key=True, index=True)
    destination_id: Mapped[int] = mapped_column(
        ForeignKey("destinations.destination_id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    # Where this way starts, for example "Davao City Proper". Free text.
    start_area: Mapped[str | None] = mapped_column(String(255))
    notes: Mapped[str | None] = mapped_column(Text)
    source_url: Mapped[str | None] = mapped_column(String(2048))
    is_verified: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false",
    )
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verified_by_user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.user_id", ondelete="SET NULL"),
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(),
    )

    steps: Mapped[list["CommuteStep"]] = relationship(
        back_populates="route",
        cascade="all, delete-orphan",
        order_by="CommuteStep.step_order",
        lazy="selectin",
    )


class CommuteStep(Base):
    __tablename__ = "commute_steps"
    __table_args__ = (
        UniqueConstraint("commute_route_id", "step_order", name="uq_commute_steps_route_order"),
        CheckConstraint("step_order >= 1", name="ck_commute_steps_order_positive"),
        CheckConstraint(
            "vehicle IN ('jeepney', 'tricycle', 'habal_habal', 'van', 'bus', 'taxi', "
            "'ferry', 'walk', 'fee')",
            name="ck_commute_steps_vehicle",
        ),
        CheckConstraint(
            "minutes IS NULL OR (minutes >= 0 AND minutes <= 1440)",
            name="ck_commute_steps_minutes_range",
        ),
        CheckConstraint("fare_php IS NULL OR fare_php >= 0", name="ck_commute_steps_fare_non_negative"),
        CheckConstraint(
            "charging_unit IS NULL OR charging_unit IN ('per_person', 'per_trip')",
            name="ck_commute_steps_charging_unit",
        ),
    )

    commute_step_id: Mapped[int] = mapped_column(primary_key=True)
    commute_route_id: Mapped[int] = mapped_column(
        ForeignKey("commute_routes.commute_route_id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    step_order: Mapped[int] = mapped_column(Integer, nullable=False)
    vehicle: Mapped[str] = mapped_column(String(20), nullable=False)
    from_place: Mapped[str | None] = mapped_column(String(255))
    to_place: Mapped[str | None] = mapped_column(String(255))
    # The stop to get off at, for example "Bemwa Farm".
    get_off_at: Mapped[str | None] = mapped_column(String(255))
    minutes: Mapped[int | None] = mapped_column(Integer)
    fare_php: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    # None means the unit is not known; it is never assumed.
    charging_unit: Mapped[str | None] = mapped_column(String(20))
    notes: Mapped[str | None] = mapped_column(Text)

    route: Mapped[CommuteRoute] = relationship(back_populates="steps")
