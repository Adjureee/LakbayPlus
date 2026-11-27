from datetime import date, datetime
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, EmailStr
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.dependencies import require_admin
from app.db.session import get_db_session
from app.features.trips.models import Trip, TripDestination
from app.features.users.models import User


class AdminTripItem(BaseModel):
    trip_id: int
    title: str
    status: str
    completed_at: datetime | None = None
    owner_user_id: int
    owner_name: str
    owner_email: EmailStr
    start_date: date | None
    end_date: date | None
    traveler_count: int
    total_budget: Decimal
    estimated_total_cost: Decimal
    destination_names: list[str]
    created_at: datetime


class AdminTripDirectoryResponse(BaseModel):
    total_trips: int
    matching_trips: int
    items: list[AdminTripItem]


router = APIRouter(prefix="/admin/trips", tags=["admin trips"])


@router.get("", response_model=AdminTripDirectoryResponse)
async def list_admin_trips(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    _admin: Annotated[User, Depends(require_admin)],
    search: str | None = Query(default=None, max_length=255),
    trip_status: str | None = Query(default=None, alias="status", max_length=50),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> AdminTripDirectoryResponse:
    """List traveler trips across accounts for the admin workspace."""
    total_trips = await session.scalar(select(func.count(Trip.trip_id))) or 0

    base_stmt = select(Trip, User).join(User, User.user_id == Trip.owner_user_id)
    count_stmt = select(func.count(Trip.trip_id)).join(
        User, User.user_id == Trip.owner_user_id
    )

    conditions = []
    if trip_status and trip_status.strip():
        conditions.append(Trip.status == trip_status.strip().lower())
    if search and search.strip():
        pattern = f"%{search.strip()}%"
        conditions.append(
            or_(
                Trip.title.ilike(pattern),
                User.full_name.ilike(pattern),
                User.email.ilike(pattern),
            )
        )
    if conditions:
        base_stmt = base_stmt.where(*conditions)
        count_stmt = count_stmt.where(*conditions)

    matching_trips = await session.scalar(count_stmt) or 0

    rows = (
        await session.execute(
            base_stmt.options(
                selectinload(Trip.destinations).selectinload(TripDestination.destination)
            )
            .order_by(Trip.created_at.desc(), Trip.trip_id.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()

    items = [
        AdminTripItem(
            trip_id=trip.trip_id,
            title=trip.title,
            status=trip.status,
            completed_at=trip.completed_at,
            owner_user_id=owner.user_id,
            owner_name=owner.full_name,
            owner_email=owner.email,
            start_date=trip.start_date,
            end_date=trip.end_date,
            traveler_count=trip.traveler_count,
            total_budget=trip.total_budget,
            estimated_total_cost=trip.estimated_total_cost,
            destination_names=[
                td.destination.name
                for td in sorted(trip.destinations, key=lambda d: d.stop_order)
                if td.destination is not None
            ],
            created_at=trip.created_at,
        )
        for trip, owner in rows
    ]

    return AdminTripDirectoryResponse(
        total_trips=total_trips,
        matching_trips=matching_trips,
        items=items,
    )
