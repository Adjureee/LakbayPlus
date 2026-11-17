from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Path, Query, status
from pydantic import BaseModel, EmailStr
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import require_admin
from app.core.exceptions import LakbayAPIError
from app.db.session import get_db_session
from app.features.destinations.models import Destination
from app.features.reviews.models import TripReview
from app.features.reviews.schemas import ReviewStatus
from app.features.trips.models import Trip
from app.features.users.models import User


class AdminReviewItem(BaseModel):
    trip_review_id: int
    trip_id: int
    trip_title: str
    user_id: int
    full_name: str
    email: EmailStr
    destination_id: int | None
    destination_name: str | None
    post_trip_rating: int
    accuracy_rating: int
    route_efficiency_rating: int
    budget_adherence_rating: int
    overall_experience_rating: int
    comments: str | None
    status: ReviewStatus
    created_at: datetime


class AdminReviewDirectoryResponse(BaseModel):
    total_reviews: int
    matching_reviews: int
    items: list[AdminReviewItem]


router = APIRouter(prefix="/admin/reviews", tags=["admin reviews"])


@router.get("", response_model=AdminReviewDirectoryResponse)
async def list_admin_reviews(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    _admin: Annotated[User, Depends(require_admin)],
    search: str | None = Query(default=None, max_length=255),
    review_status: str | None = Query(default="active", alias="status", max_length=50),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> AdminReviewDirectoryResponse:
    """List traveler reviews across trips and destinations for admin review."""
    total_reviews = await session.scalar(select(func.count(TripReview.trip_review_id))) or 0

    stmt = (
        select(TripReview, Trip.title, User.full_name, User.email, Destination.name)
        .join(Trip, Trip.trip_id == TripReview.trip_id)
        .join(User, User.user_id == TripReview.user_id)
        .outerjoin(Destination, Destination.destination_id == TripReview.destination_id)
    )
    count_stmt = (
        select(func.count(TripReview.trip_review_id))
        .join(Trip, Trip.trip_id == TripReview.trip_id)
        .join(User, User.user_id == TripReview.user_id)
        .outerjoin(Destination, Destination.destination_id == TripReview.destination_id)
    )

    conditions = []
    if review_status and review_status.strip().lower() != "all":
        conditions.append(TripReview.status == review_status.strip().lower())
    if search and search.strip():
        pattern = f"%{search.strip()}%"
        conditions.append(
            or_(
                TripReview.comments.ilike(pattern),
                Trip.title.ilike(pattern),
                User.full_name.ilike(pattern),
                User.email.ilike(pattern),
                Destination.name.ilike(pattern),
            )
        )
    if conditions:
        stmt = stmt.where(*conditions)
        count_stmt = count_stmt.where(*conditions)

    matching_reviews = await session.scalar(count_stmt) or 0

    rows = (
        await session.execute(
            stmt.order_by(TripReview.created_at.desc(), TripReview.trip_review_id.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()

    items = [
        AdminReviewItem(
            trip_review_id=review.trip_review_id,
            trip_id=review.trip_id,
            trip_title=trip_title,
            user_id=review.user_id,
            full_name=full_name,
            email=email,
            destination_id=review.destination_id,
            destination_name=destination_name,
            post_trip_rating=review.post_trip_rating,
            accuracy_rating=review.accuracy_rating,
            route_efficiency_rating=review.route_efficiency_rating,
            budget_adherence_rating=review.budget_adherence_rating,
            overall_experience_rating=review.overall_experience_rating,
            comments=review.comments,
            status=review.status,
            created_at=review.created_at,
        )
        for review, trip_title, full_name, email, destination_name in rows
    ]

    return AdminReviewDirectoryResponse(
        total_reviews=total_reviews,
        matching_reviews=matching_reviews,
        items=items,
    )


@router.delete("/{review_id}", response_model=AdminReviewItem)
async def archive_admin_review(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    _admin: Annotated[User, Depends(require_admin)],
    review_id: int = Path(ge=1),
) -> AdminReviewItem:
    """Soft-delete a review from the admin moderation workspace."""
    row = (
        await session.execute(
            select(TripReview, Trip.title, User.full_name, User.email, Destination.name)
            .join(Trip, Trip.trip_id == TripReview.trip_id)
            .join(User, User.user_id == TripReview.user_id)
            .outerjoin(Destination, Destination.destination_id == TripReview.destination_id)
            .where(TripReview.trip_review_id == review_id)
        )
    ).first()
    if row is None:
        raise LakbayAPIError(
            "Trip review was not found.",
            code="review_not_found",
            status_code=status.HTTP_404_NOT_FOUND,
        )
    review, trip_title, full_name, email, destination_name = row
    review.status = "deleted"
    await session.commit()
    await session.refresh(review)
    return AdminReviewItem(
        trip_review_id=review.trip_review_id,
        trip_id=review.trip_id,
        trip_title=trip_title,
        user_id=review.user_id,
        full_name=full_name,
        email=email,
        destination_id=review.destination_id,
        destination_name=destination_name,
        post_trip_rating=review.post_trip_rating,
        accuracy_rating=review.accuracy_rating,
        route_efficiency_rating=review.route_efficiency_rating,
        budget_adherence_rating=review.budget_adherence_rating,
        overall_experience_rating=review.overall_experience_rating,
        comments=review.comments,
        status=review.status,
        created_at=review.created_at,
    )
