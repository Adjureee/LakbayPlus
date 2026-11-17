from datetime import datetime, timezone

from fastapi import status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.destinations.region import island_group_for, region_status
from app.core.exceptions import LakbayAPIError
from app.features.destinations.candidate_repository import CandidateRepository
from app.features.destinations.candidate_schemas import (
    CandidateCreate,
    CandidateResponse,
    CandidateUpdate,
    ManualCandidateCreate,
    NearbyPlace,
    NearbyPlacesResponse,
)
from app.features.destinations.models import DestinationCandidate
from app.features.destinations.repository import DestinationRepository
from app.features.destinations.schemas import DestinationCreate


class CandidateService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.candidates = CandidateRepository(session)

    async def list(
        self, *, review_status: str | None, limit: int, offset: int, search: str | None = None
    ) -> list[CandidateResponse]:
        candidates = await self.candidates.list(
            status=review_status, limit=limit, offset=offset, search=search
        )
        return [CandidateResponse.model_validate(item) for item in candidates]

    async def get(self, candidate_id: int) -> CandidateResponse:
        candidate = await self._get_or_404(candidate_id)
        return CandidateResponse.model_validate(candidate)

    async def create(self, data: CandidateCreate) -> CandidateResponse:
        existing = await self.candidates.get_by_osm_identity(data.osm_type, data.osm_id)
        if existing is not None:
            raise LakbayAPIError(
                "This OSM object is already in the review queue.",
                code="candidate_osm_identity_exists",
                status_code=status.HTTP_409_CONFLICT,
                details={"candidate_id": existing.candidate_id},
            )
        candidate = DestinationCandidate(
            **data.model_dump(),
            island_group=island_group_for(data.lat, data.lng),
            review_status="staged",
        )
        self.session.add(candidate)
        try:
            await self.session.commit()
        except IntegrityError as exc:
            await self.session.rollback()
            raise LakbayAPIError(
                "This OSM object is already in the review queue.",
                code="candidate_osm_identity_exists",
                status_code=status.HTTP_409_CONFLICT,
            ) from exc
        await self.session.refresh(candidate)
        return CandidateResponse.model_validate(candidate)

    async def create_manual(self, data: ManualCandidateCreate) -> CandidateResponse:
        """Queue a pin dropped on the admin map for a place missing from OSM."""
        candidate = DestinationCandidate(
            source="manual",
            source_area="Admin map",
            source_tag="manual:pin",
            name=data.name,
            lat=data.lat,
            lng=data.lng,
            suggested_category=data.suggested_category,
            district=data.district,
            review_notes=data.review_notes,
            island_group=island_group_for(data.lat, data.lng),
            review_status="staged",
        )
        self.session.add(candidate)
        await self.session.commit()
        await self.session.refresh(candidate)
        return CandidateResponse.model_validate(candidate)

    async def nearby(self, *, lat: float, lng: float, radius_m: int) -> NearbyPlacesResponse:
        """What already exists near a point, to warn before adding a duplicate."""
        rows = await self.candidates.nearby(lat, lng, radius_m)
        return NearbyPlacesResponse(
            lat=lat,
            lng=lng,
            radius_m=radius_m,
            places=[
                NearbyPlace(
                    kind=kind,
                    id=row.destination_id if kind == "destination" else row.candidate_id,
                    name=row.name,
                    distance_m=round(meters, 1),
                    review_status=None if kind == "destination" else row.review_status,
                )
                for kind, row, meters in rows
            ],
        )

    async def update(self, candidate_id: int, data: CandidateUpdate) -> CandidateResponse:
        candidate = await self._get_or_404(candidate_id, lock=True)
        self._require_staged(candidate)
        values = data.model_dump(exclude_unset=True)
        if not values:
            raise LakbayAPIError("Provide at least one field.", code="empty_candidate_update")
        if any(values.get(field, True) is None for field in ("name", "lat", "lng")):
            raise LakbayAPIError("Name and coordinates cannot be cleared.", code="invalid_candidate_location")
        if {"access_policy", "access_source_url"}.intersection(values) and "access_verified_at" not in values:
            values["access_verified_at"] = None
        if {"lat", "lng"}.intersection(values) and "island_group" not in values:
            values["island_group"] = island_group_for(
                values.get("lat", candidate.lat), values.get("lng", candidate.lng),
            )
        for field, value in values.items():
            setattr(candidate, field, value)
        await self.session.commit()
        await self.session.refresh(candidate)
        return CandidateResponse.model_validate(candidate)

    async def reject(self, candidate_id: int, reason: str) -> CandidateResponse:
        candidate = await self._get_or_404(candidate_id, lock=True)
        self._require_staged(candidate)
        candidate.review_status = "rejected"
        candidate.review_notes = reason
        await self.session.commit()
        await self.session.refresh(candidate)
        return CandidateResponse.model_validate(candidate)

    async def publish(self, candidate_id: int) -> CandidateResponse:
        candidate = await self._get_or_404(candidate_id, lock=True)
        self._require_staged(candidate)
        if (
            not candidate.category
            or not candidate.category.strip()
            or not candidate.district
            or not candidate.district.strip()
            or not candidate.visitor_purpose
            or not candidate.visitor_purpose.strip()
        ):
            raise LakbayAPIError(
                "Confirm the district and category, and explain the visitor purpose before publishing.",
                code="candidate_purpose_unverified",
            )
        if not candidate.access_policy or not candidate.access_source_url or not candidate.access_verified_at:
            raise LakbayAPIError(
                "Verify visitor access and record its source and time before publishing.",
                code="candidate_access_unverified",
            )
        verified_at = candidate.access_verified_at
        # SQLite test storage drops timezone metadata; the input schema requires it.
        if verified_at.tzinfo is None:
            verified_at = verified_at.replace(tzinfo=timezone.utc)
        if verified_at > datetime.now(timezone.utc):
            raise LakbayAPIError("Use a past access verification time.", code="invalid_access_verification_time")
        if region_status(candidate.lat, candidate.lng) == "outside":
            raise LakbayAPIError(
                "This place is outside the Davao Region (Region XI).",
                code="candidate_outside_davao_region",
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )
        duplicate = await self.candidates.nearby_same_name(candidate)
        if duplicate is not None:
            raise LakbayAPIError(
                "A nearby destination with the same name is already in the catalog.",
                code="candidate_duplicate_destination",
                status_code=status.HTTP_409_CONFLICT,
                details={"destination_id": duplicate.destination_id},
            )

        data = DestinationCreate(
            name=candidate.name,
            description=candidate.description,
            district=candidate.district,
            location=candidate.location,
            category=candidate.category,
            vibes=candidate.vibes,
            activities=candidate.activities,
            lat=candidate.lat,
            lng=candidate.lng,
            estimated_cost=candidate.estimated_cost,
            entrance_fee=candidate.entrance_fee,
            overnight_fee=candidate.overnight_fee,
            operating_hours=candidate.operating_hours,
            route_ready=False,
            island_group=candidate.island_group
            or island_group_for(candidate.lat, candidate.lng),
        )
        destination = await DestinationRepository(self.session).create(data)
        candidate.destination_id = destination.destination_id
        candidate.review_status = "published"
        await self.session.commit()
        await self.session.refresh(candidate)
        return CandidateResponse.model_validate(candidate)

    async def _get_or_404(self, candidate_id: int, *, lock: bool = False) -> DestinationCandidate:
        candidate = await self.candidates.get(candidate_id, lock=lock)
        if candidate is None:
            raise LakbayAPIError(
                "Destination candidate was not found.",
                code="candidate_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return candidate

    @staticmethod
    def _require_staged(candidate: DestinationCandidate) -> None:
        if candidate.review_status != "staged":
            raise LakbayAPIError(
                "Only staged candidates can be changed or published.",
                code="candidate_not_staged",
                status_code=status.HTTP_409_CONFLICT,
            )
