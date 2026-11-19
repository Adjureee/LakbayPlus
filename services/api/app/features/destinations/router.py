from typing import Annotated

from fastapi import APIRouter, Depends, File, Query, UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import require_admin
from app.db.session import get_db_session
from app.features.destinations.schemas import (
    DestinationActivitiesResponse,
    DestinationActivitiesUpdate,
    DestinationFacetsResponse,
    DestinationHoursResponse,
    DestinationHoursUpdate,
    DestinationPricesResponse,
    DestinationPricesUpdate,
    DestinationCreate,
    DestinationListQuery,
    DestinationResponse,
    DestinationUpdate,
)
from app.features.destinations.service import DestinationService
from app.features.destinations.region import canonical_province_name
from app.features.recommendations.schemas import PlanningRecommendationItem
from app.features.recommendations.service import (
    RecommendationService,
    planning_recommendation_from_top_place,
)
from app.features.routes.schemas import RouteCoordinate
from app.features.users.models import User
from app.integrations.storage.client import CloudinaryStorageClient, get_storage_client


router = APIRouter(prefix="/destinations", tags=["destinations"])


@router.get(
    "",
    response_model=list[DestinationResponse],
    summary="List destinations",
    description=(
        "Returns active destinations for traveler browsing. Use the optional "
        "query filters for simple search, district/category filtering, budget "
        "class, difficulty level, traveler-friendly flags, and pagination."
    ),
)
async def list_destinations(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    search: str | None = Query(default=None, max_length=255),
    district: str | None = Query(default=None, max_length=255),
    category: str | None = Query(default=None, max_length=500),
    budget_class: str | None = Query(default=None, max_length=50),
    difficulty_level: str | None = Query(default=None, max_length=50),
    kid_friendly: bool | None = None,
    wheelchair_accessible: bool | None = None,
    pet_friendly: bool | None = None,
    family_friendly: bool | None = None,
    couple_friendly: bool | None = None,
    group_friendly: bool | None = None,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> list[DestinationResponse]:
    filters = DestinationListQuery(
        search=search,
        district=district,
        category=category,
        budget_class=budget_class,
        difficulty_level=difficulty_level,
        kid_friendly=kid_friendly,
        wheelchair_accessible=wheelchair_accessible,
        pet_friendly=pet_friendly,
        family_friendly=family_friendly,
        couple_friendly=couple_friendly,
        group_friendly=group_friendly,
        limit=limit,
        offset=offset,
    )

    return await DestinationService(session).list_destinations(filters)


@router.post(
    "",
    response_model=DestinationResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create destination",
    description=(
        "Admin-only endpoint for adding a destination to the catalog. The "
        "request stores readable latitude/longitude values and also prepares "
        "the PostGIS point column when the database supports it."
    ),
)
async def create_destination(
    data: DestinationCreate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationResponse:
    return await DestinationService(session).create_destination(data)


@router.get(
    "/facets",
    response_model=DestinationFacetsResponse,
    summary="Preference groups with counts",
    description=(
        "Public. The preference groups a traveler can choose (for example Nature "
        "attractions and its sub-types), each with how many active destinations "
        "it covers. The app builds its preference chips from this, so no "
        "preference is typed into the app."
    ),
)
async def destination_facets(
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> DestinationFacetsResponse:
    return await DestinationService(session).facets()


@router.get(
    "/browse",
    response_model=list[PlanningRecommendationItem],
    summary="Browse top ranked places by category without AI",
    description=(
        "Public. Ranks active catalog destinations matching a normalized category "
        "using Lakbay's deterministic scoring, returning up to 5 cards with zero AI calls."
    ),
)
async def browse_destinations_by_category(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    category: str | None = Query(default=None, max_length=120),
    province: str | None = Query(default=None, max_length=120),
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    limit: int = Query(default=5, ge=1, le=5),
) -> list[PlanningRecommendationItem]:
    origin = (
        RouteCoordinate(lat=lat, lng=lng)
        if lat is not None and lng is not None
        else None
    )
    resolved_province = canonical_province_name(province) if province else None
    categories = [category.strip()] if category and category.strip() else []
    result = await RecommendationService(session).rank_place_query(
        categories=categories,
        province=resolved_province,
        origin=origin,
        limit=limit,
    )
    return [planning_recommendation_from_top_place(item) for item in result.items]


@router.get(
    "/{destination_id}",
    response_model=DestinationResponse,
    summary="Get destination",
    description=(
        "Returns one active destination by ID. Inactive destinations are hidden "
        "from public reads so soft-deleted places do not appear in Flutter."
    ),
)
async def get_destination(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> DestinationResponse:
    return await DestinationService(session).get_destination(destination_id)


@router.get(
    "/{destination_id}/hours",
    response_model=DestinationHoursResponse,
    summary="Get a destination's opening hours",
    description=(
        "Structured weekly hours, date exceptions, a one-line summary and how far "
        "to trust them (supported, estimated or unknown)."
    ),
)
async def get_destination_hours(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> DestinationHoursResponse:
    return await DestinationService(session).get_hours(destination_id)


@router.put(
    "/{destination_id}/hours",
    response_model=DestinationHoursResponse,
    summary="Replace a destination's opening hours",
    description=(
        "Admin-only. Replaces the weekly windows, the date exceptions, the 24-hour "
        "flag and the source and verified date in one save."
    ),
)
async def replace_destination_hours(
    destination_id: int,
    data: DestinationHoursUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationHoursResponse:
    return await DestinationService(session).replace_hours(destination_id, data)


@router.get(
    "/{destination_id}/prices",
    response_model=DestinationPricesResponse,
    summary="Get a destination's prices",
    description=(
        "Structured prices (entrance, overnight, parking and so on, by audience), "
        "a one-line summary and how far to trust them (supported, estimated or unknown)."
    ),
)
async def get_destination_prices(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> DestinationPricesResponse:
    return await DestinationService(session).get_prices(destination_id)


@router.put(
    "/{destination_id}/prices",
    response_model=DestinationPricesResponse,
    summary="Replace a destination's prices",
    description=(
        "Admin-only. Replaces every price and the source and verified date in one save."
    ),
)
async def replace_destination_prices(
    destination_id: int,
    data: DestinationPricesUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationPricesResponse:
    return await DestinationService(session).replace_prices(destination_id, data)


@router.get(
    "/{destination_id}/activities",
    response_model=DestinationActivitiesResponse,
    summary="Get a destination's activities",
    description=(
        "What to do at the place, each with its availability, duration, extra fee, "
        "effort and restrictions, a one-line summary and how far to trust it."
    ),
)
async def get_destination_activities(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> DestinationActivitiesResponse:
    return await DestinationService(session).get_activities(destination_id)


@router.put(
    "/{destination_id}/activities",
    response_model=DestinationActivitiesResponse,
    summary="Replace a destination's activities",
    description="Admin-only. Replaces every activity of the place in one save.",
)
async def replace_destination_activities(
    destination_id: int,
    data: DestinationActivitiesUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationActivitiesResponse:
    return await DestinationService(session).replace_activities(destination_id, data)


@router.patch(
    "/{destination_id}",
    response_model=DestinationResponse,
    summary="Update destination",
    description=(
        "Admin-only endpoint for editing destination details, filters, costs, "
        "accessibility flags, images, and coordinates."
    ),
)
async def update_destination(
    destination_id: int,
    data: DestinationUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationResponse:
    return await DestinationService(session).update_destination(destination_id, data)


@router.post(
    "/{destination_id}/image",
    response_model=DestinationResponse,
    summary="Upload destination photo",
    description=(
        "Admin-only multipart endpoint. Uploads one JPEG, PNG or WebP photo to "
        "Cloudinary under destinations/{destination_id} and sets it as the "
        "destination's image_url. The previous image is kept in Cloudinary."
    ),
)
async def upload_destination_photo(
    destination_id: int,
    file: Annotated[UploadFile, File(...)],
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
    storage_client: Annotated[CloudinaryStorageClient, Depends(get_storage_client)],
) -> DestinationResponse:
    return await DestinationService(
        session,
        storage_client=storage_client,
    ).upload_photo(destination_id, file=file, admin_user_id=admin.user_id)


@router.delete(
    "/{destination_id}",
    response_model=DestinationResponse,
    summary="Deactivate destination",
    description=(
        "Admin-only soft delete. The destination remains in the database but "
        "is marked inactive and disappears from public browse/get endpoints."
    ),
)
async def deactivate_destination(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> DestinationResponse:
    return await DestinationService(session).deactivate_destination(destination_id)
