import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import LakbayAPIError
from app.features.destinations.candidate_repository import distance_meters
from app.features.destinations.models import Destination
from app.features.destinations.region import (
    nearest_provinces,
    province_for_destination,
)
from app.features.planning.routing import _has_non_road_access_hint
from app.features.recommendations import scoring
from app.features.recommendations.limits import (
    FORECAST_CELL_DEGREES,
    MAX_FORECAST_CELLS,
    MAX_SUGGESTIONS,
    WEATHER_FORECAST_DAYS,
)
from app.features.recommendations.preference_groups import (
    Membership,
    PreferenceGroups,
    load_category_aliases,
    load_groups,
    normalize_category,
)
from app.features.recommendations.weight_profiles import WeightProfile, get_profile
from app.features.recommendations.models import (
    DestinationInteraction,
    DestinationPopularity,
)
from app.features.recommendations.repository import RecommendationRepository
from app.features.recommendations.schemas import (
    DestinationInteractionCreate,
    DestinationInteractionResponse,
    DestinationPopularityResponse,
    PlaceQueryResult,
    PreferenceSignalResponse,
    PlanningRecommendationItem,
    RecommendationItem,
    RecommendationRequest,
    RecommendationResponse,
    TopPlaceBreakdown,
    TopPlaceFactor,
    TopPlaceFactorDetail,
    TopPlaceItem,
    TopPlacesRequest,
    TopPlacesResponse,
    TopPlacesSkipped,
    TopPlaceTravelBasis,
)
from app.features.routes.schemas import RouteCoordinate
from app.features.routes.service import FALLBACK_SPEED_KMH
from app.features.users.models import User
from app.integrations.osrm.client import MAX_PREVIEW_WAYPOINT_SNAP_METERS, OSRMClient
from app.integrations.osrm.errors import OSRMClientError

logger = logging.getLogger(__name__)

# Gets the forecast for a point: (lat, lng, days) -> a WeatherForecastResponse.
ForecastProvider = Callable[[float, float, int], Awaitable[object]]

NON_REPEATABLE_INTERACTIONS = {"save", "rate", "add_to_itinerary"}
# One OSRM table request covers at most this many places (public OSRM allows 100).
MAX_ROUTED_CANDIDATES = 50


@dataclass
class _TopPlaceCandidate:
    destination: Destination
    matched: list[str]
    matched_fields: list[str]
    # Normalized 0-1 factor values, except those that need a route (travel, access)
    # or a forecast (weather), which are added once those are known.
    values: dict[str, float]
    memberships: dict[str, Membership] = field(default_factory=dict)
    budget_relaxed: bool = False
    rain_sensitivity: str = "medium"
    # Criteria whose data was missing, so the neutral value 0.5 was used.
    defaults: set[str] = field(default_factory=set)


@dataclass(frozen=True)
class _Trip:
    minutes: int | None
    distance_km: Decimal | None
    basis: TopPlaceTravelBasis
    provider: str | None
    verified: bool
    reachable: bool = True


class RecommendationService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.recommendations = RecommendationRepository(session)

    async def rank_top_places(
        self,
        *,
        data: TopPlacesRequest,
        osrm_client: OSRMClient | None,
        user: User | None = None,
        save_preference: bool = False,
        forecast_provider: ForecastProvider | None = None,
    ) -> TopPlacesResponse:
        """Rank places with the weighted scoring model (SAW) in `scoring.py`.

        The weights come from a profile in `data/weight_profiles.json`: the
        default profile, or the nature profile when the traveler chose a
        nature preference group. Places with a verified entrance and a confirmed
        road route fill the list first under the default profile; under the
        nature profile access is a weighted criterion instead.
        """
        preference_signal_id = None
        if save_preference and user is not None:
            preference = await self.recommendations.create_preference_signal(
                user_id=user.user_id,
                data=RecommendationRequest(
                    preferred_categories=data.interests,
                    preferred_vibes=data.interests,
                    preferred_activities=data.interests,
                    preferred_districts=data.preferred_districts,
                    requires_kid_friendly=data.requires_kid_friendly,
                    requires_wheelchair_accessible=data.requires_wheelchair_accessible,
                    requires_pet_friendly=data.requires_pet_friendly,
                    requires_elderly_friendly=data.requires_elderly_friendly,
                    group_friendly=True if data.party_size > 1 else None,
                    limit=data.limit,
                ),
            )
            preference_signal_id = preference.preference_signal_id

        destinations = await self.recommendations.list_active_destinations()
        popularity = await self.recommendations.list_popularity()
        groups = load_groups()
        wants = _resolve_wants(data, groups)
        profile, weights = _profile_and_weights(wants, data, groups)
        thresholds = scoring.THRESHOLDS
        party = data.party_size
        budget_per_person = (
            None if data.total_budget is None
            else data.total_budget if data.budget_scope == "per_person"
            else data.total_budget / party
        )
        max_minutes = scoring.max_travel_minutes(data.day_count)
        districts = {item.strip().lower() for item in data.preferred_districts}
        required_flags = (
            (data.requires_kid_friendly, "is_kid_friendly"),
            (data.requires_wheelchair_accessible, "is_wheelchair_accessible"),
            (data.requires_pet_friendly, "is_pet_friendly"),
            (data.requires_elderly_friendly, "is_elderly_friendly"),
        )
        road_mode = data.travel_mode in {"driving", "walking"}
        skipped = TopPlacesSkipped()
        interest_match_count = 0
        candidates: list[_TopPlaceCandidate] = []
        for destination in destinations:
            memberships = {
                key: membership
                for key in wants.group_keys
                if (membership := groups.membership(
                    key, destination.category, destination.destination_id,
                )) is not None
            }
            satisfied = _satisfied_wants(wants, destination, memberships, groups)
            if satisfied.labels:
                interest_match_count += 1
            if districts and (destination.district or "").strip().lower() not in districts:
                skipped.outside_preferred_districts += 1
                continue
            if any(required and not getattr(destination, flag) for required, flag in required_flags):
                skipped.missing_required_accessibility += 1
                continue
            if wants.total and not satisfied.labels:
                skipped.no_interest_match += 1
                continue
            cost = destination.estimated_cost
            budget_relaxed = False
            if cost is not None and budget_per_person is not None and cost > budget_per_person:
                if data.fill_to_limit and cost <= budget_per_person * Decimal(
                    str(thresholds.relax_budget_factor)
                ):
                    budget_relaxed = True
                else:
                    skipped.over_budget += 1
                    continue
            if road_mode and _has_non_road_access_hint(destination):
                skipped.needs_boat_or_ferry += 1
                continue
            record = popularity.get(destination.destination_id)
            values, defaults = _candidate_values(
                profile=profile,
                data=data,
                wants=wants,
                destination=destination,
                satisfied=satisfied,
                memberships=memberships,
                cost=cost,
                budget_per_person=budget_per_person,
                party=party,
                popularity_value=record.popularity_score if record else None,
            )
            nature = memberships.get("nature_attractions")
            candidates.append(_TopPlaceCandidate(
                destination=destination,
                matched=satisfied.labels,
                matched_fields=satisfied.fields,
                values=values,
                memberships=memberships,
                budget_relaxed=budget_relaxed,
                rain_sensitivity=nature.rain_sensitivity if nature else "medium",
                defaults=defaults,
            ))

        rain_by_destination: dict[int, list[int]] = {}
        weather_note: str | None = None
        if "weather_season" in weights and candidates:
            rain_by_destination, weather_note = await self._rain_by_destination(
                data, candidates, forecast_provider,
            )

        # Route only the strongest candidates, so one table request stays small.
        # A straight-line estimate stands in for travel while shortlisting, so
        # distant places cannot crowd out nearby ones before the road check.
        qualified, skipped, warnings = await self._score_and_rank_candidates(
            data=data,
            candidates=candidates,
            skipped=skipped,
            max_minutes=max_minutes,
            budget_per_person=budget_per_person,
            osrm_client=osrm_client,
            enforce_max_distance=True,
            profile=profile,
            weights=weights,
            rain_by_destination=rain_by_destination,
        )
        if weather_note:
            warnings.append(weather_note)
        items = [
            item.model_copy(update={"rank": index})
            for index, item in enumerate(qualified[: data.limit], start=1)
        ]
        relaxed_count = sum(1 for item in items if item.match_tier > 1)
        if relaxed_count:
            warnings.append(
                f"{relaxed_count} of these places relax a limit you set to fill the list; "
                "each card says which."
            )
        approximate = sum(1 for item in items if not item.route_verified)
        if data.origin is None:
            warnings.append("Set a start point on the map to rank places by travel time.")
        elif approximate:
            warnings.append(
                f"{approximate} of these places {'has' if approximate == 1 else 'have'} "
                "no verified road route to a visitor entrance yet, so travel times are approximate."
            )
        if data.total_budget is not None:
            warnings.append(
                "Costs are catalog estimates per person; transport, lodging and meals are not included."
            )

        if save_preference:
            await self.session.commit()
        return TopPlacesResponse(
            method=data.ranking_method,
            profile=profile.name,
            weights={name: round(value, 4) for name, value in weights.items()},
            relaxed_count=relaxed_count,
            max_travel_minutes=max_minutes,
            preference_signal_id=preference_signal_id,
            total_candidates=len(qualified),
            verified_count=sum(1 for item in qualified if item.route_verified),
            items=items,
            skipped=skipped,
            shortfall_reason=_top_place_shortfall(
                data=data,
                qualified=len(qualified),
                interest_match_count=interest_match_count,
                skipped=skipped,
            ),
            warnings=warnings,
        )

    async def _rain_by_destination(
        self,
        data: TopPlacesRequest,
        candidates: list[_TopPlaceCandidate],
        forecast_provider: ForecastProvider | None,
    ) -> tuple[dict[int, list[int]], str | None]:
        """Rain chances for the trip days per place, or a note saying why not.

        There is no assumed season: without a date inside the forecast window the
        weather criterion stays neutral and the note says so.
        """
        start = data.travel_start_date
        if start is None:
            return {}, "No travel date was set, so weather is not scored."
        today = _today()
        if start < today:
            return {}, "The travel date is in the past, so weather is not scored."
        if start > today + timedelta(days=WEATHER_FORECAST_DAYS - 1):
            return {}, (
                f"The trip starts beyond the {WEATHER_FORECAST_DAYS}-day weather forecast, "
                "so weather is not scored."
            )
        end = start + timedelta(days=max(1, data.day_count or 1) - 1)
        needed = min(WEATHER_FORECAST_DAYS, (end - today).days + 1)

        provider = forecast_provider or self._default_forecast
        cells: dict[tuple[float, float], list[_TopPlaceCandidate]] = {}
        for candidate in candidates:
            key = (
                round(candidate.destination.lat / FORECAST_CELL_DEGREES) * FORECAST_CELL_DEGREES,
                round(candidate.destination.lng / FORECAST_CELL_DEGREES) * FORECAST_CELL_DEGREES,
            )
            cells.setdefault(key, []).append(candidate)
        result: dict[int, list[int]] = {}
        failed = False
        for (lat, lng), members in list(cells.items())[:MAX_FORECAST_CELLS]:
            try:
                forecast = await provider(lat, lng, needed)
            except Exception:  # a provider outage must not break recommendations
                logger.warning("Weather forecast failed for %.2f,%.2f", lat, lng, exc_info=True)
                failed = True
                continue
            chances = [
                day.rain_chance_percent
                for day in getattr(forecast, "days", [])
                if _within(day.date, start, end)
            ]
            if not chances:
                continue
            for candidate in members:
                result[candidate.destination.destination_id] = chances
        if failed and not result:
            return {}, "The weather forecast is unavailable right now, so weather is not scored."
        return result, None

    async def _default_forecast(self, lat: float, lng: float, days: int) -> object:
        from app.features.weather.service import WeatherService

        return await WeatherService(self.session).forecast(lat=lat, lng=lng, days=days)

    async def rank_place_query(
        self,
        *,
        categories: list[str],
        province: str | None,
        origin: RouteCoordinate | None,
        travel_mode: str = "driving",
        total_budget: Decimal | None = None,
        budget_scope: str = "whole_trip",
        traveler_count: int | None = None,
        adult_count: int | None = None,
        child_ages: list[int] | None = None,
        day_count: int | None = None,
        limit: int = 5,
        osrm_client: OSRMClient | None = None,
    ) -> PlaceQueryResult:
        """Resolve an explicit show-places query using Region XI province filtering and SAW ranking."""
        norm_cats = _normalize_category_terms(categories)
        groups = load_groups()
        query_request = TopPlacesRequest(
            interests=norm_cats[:15],
            origin=origin,
            travel_mode=travel_mode if travel_mode in {"driving", "public_transport", "walking"} else "driving",
            total_budget=total_budget,
            budget_scope="per_person" if budget_scope == "per_person" else "whole_trip",
            traveler_count=traveler_count,
            adult_count=adult_count,
            child_ages=list(child_ages or []),
            day_count=day_count or 2,
            limit=max(1, min(MAX_SUGGESTIONS, limit)),
            ranking_method="simple_additive_weighting",
        )
        destinations = await self.recommendations.list_active_destinations()
        popularity = await self.recommendations.list_popularity()
        party = query_request.party_size
        budget_per_person = (
            None if query_request.total_budget is None
            else query_request.total_budget if query_request.budget_scope == "per_person"
            else query_request.total_budget / party
        )
        max_minutes = scoring.max_travel_minutes(query_request.day_count)

        candidates: list[_TopPlaceCandidate] = []
        other_province_counts: dict[str, int] = {}
        for destination in destinations:
            dest_province = province_for_destination(
                destination.lat,
                destination.lng,
                district=destination.district,
                location=destination.location,
            )
            if dest_province is None:
                continue

            matched, matched_fields = _match_place_categories(norm_cats, destination)
            # A word such as "nature" or "waterfall" also matches by preference group.
            for term in norm_cats:
                target = groups.resolve(term)
                if target is None or term in matched:
                    continue
                membership = groups.membership(
                    target.group, destination.category, destination.destination_id,
                )
                if membership is not None and (
                    target.subtype is None or target.subtype in membership.subtypes
                ):
                    matched.append(term)
                    if "category" not in matched_fields:
                        matched_fields.append("category")
            if norm_cats and not matched:
                continue

            if province is not None and dest_province != province:
                other_province_counts[dest_province] = other_province_counts.get(dest_province, 0) + 1
                continue

            cost = destination.estimated_cost
            if cost is not None and budget_per_person is not None and cost > budget_per_person:
                continue

            record = popularity.get(destination.destination_id)
            candidates.append(_TopPlaceCandidate(
                destination=destination,
                matched=matched,
                matched_fields=matched_fields,
                values={
                    "interest": scoring.interest_score(len(norm_cats), len(matched)),
                    "budget": scoring.budget_score(cost, budget_per_person),
                    "group_fit": scoring.group_fit_score(
                        has_children=bool(query_request.child_ages),
                        traveler_count=party,
                        is_kid_friendly=destination.is_kid_friendly,
                        group_friendly=destination.group_friendly,
                    ),
                    "popularity": scoring.popularity_score(
                        record.popularity_score if record else None
                    ),
                },
            ))

        qualified, _, _ = await self._score_and_rank_candidates(
            data=query_request,
            candidates=candidates,
            skipped=TopPlacesSkipped(),
            max_minutes=max_minutes,
            budget_per_person=budget_per_person,
            osrm_client=osrm_client,
            enforce_max_distance=False,
        )
        items = [
            item.model_copy(update={"rank": index})
            for index, item in enumerate(qualified[: query_request.limit], start=1)
        ]

        nearby = nearest_provinces(
            province,
            lat=origin.lat if origin is not None else None,
            lng=origin.lng if origin is not None else None,
            counts=other_province_counts if province is not None else None,
        )
        shortfall_reason: str | None = None
        if len(items) < query_request.limit and (province is not None or len(items) == 0):
            shortfall_reason = _place_query_shortfall(
                categories=categories,
                province=province,
                found=len(items),
                nearby=nearby,
                other_province_counts=other_province_counts,
            )

        return PlaceQueryResult(
            items=items,
            total_candidates=len(qualified),
            target_province=province,
            other_province_counts=other_province_counts,
            nearest_provinces=nearby,
            shortfall_reason=shortfall_reason,
        )

    async def _score_and_rank_candidates(
        self,
        *,
        data: TopPlacesRequest,
        candidates: list[_TopPlaceCandidate],
        skipped: TopPlacesSkipped,
        max_minutes: int,
        budget_per_person: Decimal | None,
        osrm_client: OSRMClient | None,
        enforce_max_distance: bool,
        profile: WeightProfile | None = None,
        weights: dict[str, float] | None = None,
        rain_by_destination: dict[int, list[int]] | None = None,
    ) -> tuple[list[TopPlaceItem], TopPlacesSkipped, list[str]]:
        profile = profile or get_profile("default")
        weights = weights or dict(profile.weights)
        rain_by_destination = rain_by_destination or {}
        thresholds = scoring.THRESHOLDS
        default_profile = profile.name == "default"
        candidates.sort(key=lambda item: (
            -_shortlist_score(data, item, max_minutes, weights),
            item.destination.destination_id,
        ))
        candidates = candidates[:MAX_ROUTED_CANDIDATES]
        travel, warnings = await _travel_times(data, candidates, osrm_client)

        qualified: list[TopPlaceItem] = []
        qualified_values: list[dict[str, float]] = []
        for candidate in candidates:
            destination = candidate.destination
            trip = travel[destination.destination_id]
            if not trip.reachable:
                skipped.no_route += 1
                continue
            travel_relaxed = False
            if enforce_max_distance and trip.minutes is not None and trip.minutes > max_minutes:
                if data.fill_to_limit and trip.minutes <= max_minutes * thresholds.relax_travel_factor:
                    travel_relaxed = True
                else:
                    skipped.too_far += 1
                    continue
            defaults = set(candidate.defaults)
            values = {**candidate.values, "travel": scoring.travel_score(trip.minutes, max_minutes)}
            if data.origin is None or trip.minutes is None:
                defaults.add("travel")
            if "access" in weights:
                values["access"] = scoring.access_score(
                    verified=trip.verified,
                    has_access_trail=bool(destination.access_trail_polyline),
                    basis=trip.basis,
                )
                if values["access"] == scoring.NEUTRAL:
                    defaults.add("access")
            rain = rain_by_destination.get(destination.destination_id, [])
            if "weather_season" in weights:
                weather = scoring.weather_score(rain, sensitivity=candidate.rain_sensitivity)
                values["weather_season"] = scoring.NEUTRAL if weather is None else weather
                if weather is None:
                    defaults.add("weather_season")
            points = scoring.weighted_points(values, weights)
            qualified_values.append(values)

            relaxations: list[str] = []
            if candidate.budget_relaxed and destination.estimated_cost is not None and budget_per_person:
                over = destination.estimated_cost - budget_per_person
                relaxations.append(f"About ₱{over:,.0f} over your per-person budget.")
            if travel_relaxed:
                relaxations.append(
                    f"{_duration_words(trip.minutes)} away, beyond your usual "
                    f"{_duration_words(max_minutes)} limit."
                )
            reasons = _top_place_reasons(
                data=data,
                candidate=candidate,
                trip=trip,
                budget_per_person=budget_per_person,
            )
            if "nature_fit" in weights:
                reasons.extend(_nature_reasons(
                    data=data, candidate=candidate, defaults=defaults, rain=rain,
                ))
            reasons = [*relaxations, *reasons]
            qualified.append(TopPlaceItem(
                rank=0,
                destination_id=destination.destination_id,
                name=destination.name,
                district=destination.district,
                category=destination.category,
                image_url=destination.image_url,
                estimated_cost=destination.estimated_cost,
                cost_basis="not_listed" if destination.estimated_cost is None else "catalog_estimate",
                lat=destination.lat,
                lng=destination.lng,
                score=scoring.total_score(points),
                breakdown=(
                    TopPlaceBreakdown(**{
                        name: TopPlaceFactor(
                            value=round(values[name], 4),
                            weight=weights[name],
                            points=points[name],
                        )
                        for name in weights
                    })
                    if default_profile else None
                ),
                profile=profile.name,
                factors=[
                    TopPlaceFactorDetail(
                        criterion=name,
                        label=scoring.CRITERION_LABELS.get(name, name),
                        value=round(values[name], 4),
                        weight=round(weights[name], 4),
                        points=points[name],
                        used_default=name in defaults,
                    )
                    for name in weights
                ],
                match_tier=1 + len(relaxations),
                relaxations=relaxations,
                matched_interests=candidate.matched,
                matched_fields=candidate.matched_fields,
                reasons=reasons,
                route_verified=trip.verified,
                travel_mode=data.travel_mode,
                travel_basis=trip.basis,
                route_provider=trip.provider,
                travel_minutes=trip.minutes,
                travel_distance_km=trip.distance_km,
            ))

        if data.ranking_method == "topsis" and qualified:
            topsis_list = scoring.topsis_scores(qualified_values, weights)
            qualified = [
                item.model_copy(update={"score": topsis_val})
                for item, topsis_val in zip(qualified, topsis_list, strict=True)
            ]

        # Places that fit every limit come first. The default profile then puts
        # verified road routes ahead of approximate places (the approved Top 5
        # rule); other profiles weigh access in the score instead. Best score
        # first within each group.
        qualified.sort(key=lambda item: (
            item.match_tier,
            (not item.route_verified) if default_profile else False,
            -item.score,
            item.travel_minutes if item.travel_minutes is not None else float("inf"),
            item.destination_id,
        ))
        return qualified, skipped, warnings

    async def recommend_destinations(
        self,
        *,
        user: User,
        data: RecommendationRequest,
    ) -> RecommendationResponse:
        preference = await self.recommendations.create_preference_signal(
            user_id=user.user_id,
            data=data,
        )
        destinations = await self.recommendations.list_active_destinations()
        popularity_by_destination = await self.recommendations.list_popularity()

        scored = [
            item
            for destination in destinations
            if (
                item := self.score_destination(
                    destination=destination,
                    preference=preference,
                    popularity=popularity_by_destination.get(
                        destination.destination_id,
                    ),
                )
            )
            is not None
        ]
        scored.sort(key=lambda item: item.score, reverse=True)

        await self.session.commit()

        return RecommendationResponse(
            preference_signal_id=preference.preference_signal_id,
            total_candidates=len(scored),
            recommendations=scored[: data.limit],
        )

    async def get_latest_preference(self, *, user: User) -> PreferenceSignalResponse:
        preference = await self.recommendations.get_latest_preference(
            user_id=user.user_id,
        )

        if preference is None:
            raise LakbayAPIError(
                "No preference signal was found for this user.",
                code="preference_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        return PreferenceSignalResponse.model_validate(preference)

    async def create_interaction(
        self,
        *,
        user: User,
        destination_id: int,
        data: DestinationInteractionCreate,
    ) -> DestinationInteractionResponse:
        await self._require_active_destination(destination_id)
        interaction = await self._record_interaction(
            user_id=user.user_id,
            destination_id=destination_id,
            data=data,
        )
        popularity = await self.recommendations.get_or_create_popularity(
            destination_id=destination_id,
        )
        interactions = await self.recommendations.list_destination_interactions(
            destination_id=destination_id,
        )

        self._recalculate_popularity(
            popularity=popularity,
            interactions=interactions,
        )
        await self.session.commit()
        await self.session.refresh(interaction)

        return DestinationInteractionResponse.model_validate(interaction)

    async def get_popularity(
        self,
        *,
        destination_id: int,
    ) -> DestinationPopularityResponse:
        await self._require_active_destination(destination_id)
        popularity = await self.recommendations.get_popularity(
            destination_id=destination_id,
        )

        if popularity is None:
            return DestinationPopularityResponse(
                destination_id=destination_id,
                view_count=0,
                save_count=0,
                rating_count=0,
                rating_sum=0,
                average_rating=Decimal("0.00"),
                add_to_itinerary_count=0,
                popularity_score=Decimal("0.00"),
                created_at=None,
                updated_at=None,
            )

        return DestinationPopularityResponse.model_validate(popularity)

    async def _require_active_destination(self, destination_id: int) -> Destination:
        destination = await self.recommendations.get_active_destination(
            destination_id=destination_id,
        )

        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        return destination

    def score_destination(
        self,
        *,
        destination: Destination,
        preference,
        popularity: DestinationPopularity | None,
    ) -> RecommendationItem | None:
        if not self._passes_hard_filters(destination=destination, preference=preference):
            return None

        score = 0.0
        matched_fields: list[str] = []
        reasons: list[str] = []

        score += _match_list(
            values=preference.preferred_categories,
            text=destination.category,
            weight=25,
            field="category",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Matches preferred destination category.",
        )
        score += _match_list(
            values=preference.preferred_vibes,
            text=destination.vibes,
            weight=15,
            field="vibes",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Matches preferred travel vibe.",
        )
        score += _match_list(
            values=preference.preferred_activities,
            text=destination.activities,
            weight=15,
            field="activities",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Offers one or more preferred activities.",
        )
        score += _match_list(
            values=preference.preferred_districts,
            text=destination.district,
            weight=10,
            field="district",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Matches preferred district.",
        )
        score += _match_value(
            preferred=preference.budget_class,
            actual=destination.budget_class,
            weight=15,
            field="budget_class",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Fits the preferred budget class.",
        )
        score += _match_value(
            preferred=preference.difficulty_level,
            actual=destination.difficulty_level,
            weight=10,
            field="difficulty_level",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Matches preferred difficulty level.",
        )
        score += _match_value(
            preferred=preference.stay_duration_type,
            actual=destination.stay_duration_type,
            weight=5,
            field="stay_duration_type",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Matches preferred trip duration.",
        )
        score += _match_bool(
            preferred=preference.family_friendly,
            actual=destination.family_friendly,
            field="family_friendly",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Works for family travel.",
        )
        score += _match_bool(
            preferred=preference.couple_friendly,
            actual=destination.couple_friendly,
            field="couple_friendly",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Works for couple travel.",
        )
        score += _match_bool(
            preferred=preference.group_friendly,
            actual=destination.group_friendly,
            field="group_friendly",
            matched_fields=matched_fields,
            reasons=reasons,
            reason="Works for group travel.",
        )

        has_ranking_preferences = _has_ranking_preferences(preference)

        if has_ranking_preferences and score <= 0:
            return None

        score += self._popularity_boost(popularity, matched_fields, reasons)

        return RecommendationItem(
            destination_id=destination.destination_id,
            name=destination.name,
            district=destination.district,
            category=destination.category,
            estimated_cost=destination.estimated_cost,
            score=round(score, 2),
            matched_fields=matched_fields,
            reasons=reasons,
        )

    def _passes_hard_filters(self, *, destination: Destination, preference) -> bool:
        if (
            preference.max_estimated_cost is not None
            and (
                destination.estimated_cost is None
                or destination.estimated_cost > preference.max_estimated_cost
            )
        ):
            return False

        required_flags = [
            (preference.requires_kid_friendly, destination.is_kid_friendly),
            (
                preference.requires_wheelchair_accessible,
                destination.is_wheelchair_accessible,
            ),
            (preference.requires_pet_friendly, destination.is_pet_friendly),
            (preference.requires_elderly_friendly, destination.is_elderly_friendly),
        ]

        return all(not required or actual for required, actual in required_flags)

    def _popularity_boost(
        self,
        popularity: DestinationPopularity | None,
        matched_fields: list[str],
        reasons: list[str],
    ) -> float:
        if popularity is None or popularity.popularity_score <= 0:
            return 0

        boost = min(float(popularity.popularity_score) / 10, 10)

        if boost > 0:
            matched_fields.append("popularity")
            reasons.append("Has positive traveler interaction history.")

        return boost

    async def _record_interaction(
        self,
        *,
        user_id: int,
        destination_id: int,
        data: DestinationInteractionCreate,
    ) -> DestinationInteraction:
        if data.interaction_type in NON_REPEATABLE_INTERACTIONS:
            existing = await self.recommendations.get_user_interaction(
                user_id=user_id,
                destination_id=destination_id,
                interaction_type=data.interaction_type,
            )

            if existing is not None:
                if data.interaction_type == "rate":
                    return await self.recommendations.update_interaction(
                        existing,
                        data,
                    )

                return existing

        return await self.recommendations.create_interaction(
            user_id=user_id,
            destination_id=destination_id,
            data=data,
        )

    def _recalculate_popularity(
        self,
        *,
        popularity: DestinationPopularity,
        interactions: list[DestinationInteraction],
    ) -> None:
        ratings = [
            interaction.rating
            for interaction in interactions
            if interaction.interaction_type == "rate" and interaction.rating is not None
        ]

        popularity.view_count = _count_interactions(interactions, "view")
        popularity.save_count = _count_interactions(interactions, "save")
        popularity.add_to_itinerary_count = _count_interactions(
            interactions,
            "add_to_itinerary",
        )
        popularity.rating_count = len(ratings)
        popularity.rating_sum = sum(ratings)
        popularity.average_rating = (
            (
                Decimal(popularity.rating_sum) / Decimal(popularity.rating_count)
            ).quantize(Decimal("0.01"))
            if popularity.rating_count
            else Decimal("0.00")
        )

        popularity.popularity_score = (
            Decimal(_int(popularity.view_count))
            + Decimal(_int(popularity.save_count) * 3)
            + Decimal(_int(popularity.add_to_itinerary_count) * 5)
            + (Decimal(popularity.average_rating or 0) * Decimal("2"))
        )


def _has_verified_arrival(destination: Destination) -> bool:
    return bool(
        destination.route_ready
        and destination.arrival_lat is not None
        and destination.arrival_lng is not None
        and destination.arrival_source_url
        and destination.arrival_verified_at
    )


def _match_list(
    *,
    values: list[str],
    text: str | None,
    weight: int,
    field: str,
    matched_fields: list[str],
    reasons: list[str],
    reason: str,
) -> float:
    if not values or not text:
        return 0

    searchable = text.lower()

    if any(value in searchable for value in values):
        matched_fields.append(field)
        reasons.append(reason)

        return weight

    return 0


def _match_value(
    *,
    preferred: str | None,
    actual: str | None,
    weight: int,
    field: str,
    matched_fields: list[str],
    reasons: list[str],
    reason: str,
) -> float:
    if preferred and actual and preferred.strip().lower() == actual.strip().lower():
        matched_fields.append(field)
        reasons.append(reason)

        return weight

    return 0


def _match_bool(
    *,
    preferred: bool | None,
    actual: bool,
    field: str,
    matched_fields: list[str],
    reasons: list[str],
    reason: str,
) -> float:
    if preferred is True and actual:
        matched_fields.append(field)
        reasons.append(reason)

        return 5

    return 0


def _has_ranking_preferences(preference) -> bool:
    return any(
        (
            preference.preferred_categories,
            preference.preferred_vibes,
            preference.preferred_activities,
            preference.preferred_districts,
            preference.budget_class,
            preference.difficulty_level,
            preference.stay_duration_type,
            preference.family_friendly is not None,
            preference.couple_friendly is not None,
            preference.group_friendly is not None,
        )
    )


def _count_interactions(
    interactions: list[DestinationInteraction],
    interaction_type: str,
) -> int:
    return sum(
        1
        for interaction in interactions
        if interaction.interaction_type == interaction_type
    )


def _int(value: int | None) -> int:
    return value or 0


def planning_recommendation_from_top_place(item: TopPlaceItem) -> PlanningRecommendationItem:
    """Shape a Top 5 place for the planning chat response."""
    return PlanningRecommendationItem(
        destination_id=item.destination_id,
        name=item.name,
        district=item.district,
        category=item.category,
        image_url=item.image_url,
        lat=item.lat,
        lng=item.lng,
        estimated_cost=item.estimated_cost,
        score=item.score,
        matched_fields=item.matched_fields,
        reasons=item.reasons,
        route_provider=item.route_provider,
        travel_mode=item.travel_mode,
        route_distance_km=item.travel_distance_km,
        route_duration_minutes=item.travel_minutes,
        route_verified=item.route_verified,
        travel_basis=item.travel_basis,
        breakdown=item.breakdown,
        profile=item.profile,
        factors=item.factors,
        match_tier=item.match_tier,
        relaxations=item.relaxations,
    )


_SINGULAR_CATEGORIES: dict[str, str] = {
    "beaches": "beach",
    "mountains": "mountain",
    "waterfalls": "waterfall",
    "falls": "waterfall",
    "islands": "island",
    "resorts": "resort",
    "parks": "park",
    "caves": "cave",
    "farms": "farm",
    "cafes": "cafe",
    "restaurants": "restaurant",
    "museums": "museum",
    "lakes": "lake",
    "hills": "hill",
    "springs": "spring",
}


def _normalize_category_terms(categories: list[str]) -> list[str]:
    terms: list[str] = []
    aliases = load_category_aliases()
    for raw in categories:
        cleaned = raw.strip().lower()
        if not cleaned:
            continue
        aliased = normalize_category(cleaned)
        if aliased and aliased not in terms:
            terms.append(aliased)
        stem = _SINGULAR_CATEGORIES.get(cleaned) or aliases.get(cleaned)
        if stem is None and len(cleaned) > 4 and cleaned.endswith("s") and not cleaned.endswith(("ss", "us", "is")):
            stem = cleaned[:-1]
        value = stem or cleaned
        if value not in terms:
            terms.append(value)
    return terms


def _match_place_categories(
    categories: list[str],
    destination: Destination,
) -> tuple[list[str], list[str]]:
    if not categories:
        return [], []
    dest_norm_cat = normalize_category(destination.category)
    matched, matched_fields = scoring.interest_matches(
        categories,
        {
            "category": " | ".join(
                part for part in (destination.category, dest_norm_cat) if part
            ),
            "vibes": destination.vibes,
            "activities": destination.activities,
        },
    )
    # Fuzzy shared-word match across normalized category words when exact substring didn't hit.
    dest_words = {
        word for word in dest_norm_cat.split() if len(word) >= 3
    }
    for term in categories:
        if term in matched:
            continue
        if dest_norm_cat == term or term in dest_norm_cat:
            matched.append(term)
            if "category" not in matched_fields:
                matched_fields.append("category")
            continue
        term_words = {w for w in term.split() if len(w) >= 3}
        if term_words and term_words <= dest_words:
            matched.append(term)
            if "category" not in matched_fields:
                matched_fields.append("category")
    if "island" in categories and "island" not in [m.lower() for m in matched] and destination.island_group:
        matched.append("island")
        if "island_group" not in matched_fields:
            matched_fields.append("island_group")
    return matched, matched_fields


def _place_query_shortfall(
    *,
    categories: list[str],
    province: str | None,
    found: int,
    nearby: list[str],
    other_province_counts: dict[str, int],
) -> str:
    cat_label = ", ".join(categories).strip()
    cat_phrase = f"{cat_label} " if cat_label else ""
    with_matches = [p for p in nearby if other_province_counts.get(p, 0) > 0][:3]
    if found == 0:
        if province is None:
            return f"No active {cat_phrase}destinations in Davao Region match your request yet."
        if with_matches:
            return (
                f"No active {cat_phrase}destinations in {province} are in our catalog yet. "
                f"Nearest provinces with options: {', '.join(with_matches)}."
            )
        fallback = nearby[:3]
        if fallback:
            return (
                f"No active {cat_phrase}destinations in {province} match your request yet. "
                f"Nearest provinces to explore: {', '.join(fallback)}."
            )
        return f"No active {cat_phrase}destinations in {province} are in our catalog yet."

    noun = "destination" if found == 1 else "destinations"
    verb = "is" if found == 1 else "are"
    if with_matches:
        return (
            f"Only {found} active {cat_phrase}{noun} in {province} {verb} listed right now. "
            f"Nearest provinces with more options: {', '.join(with_matches)}."
        )
    fallback = nearby[:3]
    extra = f" Nearest provinces to explore: {', '.join(fallback)}." if fallback else ""
    return f"Only {found} active {cat_phrase}{noun} in {province} {verb} listed right now.{extra}"


def _route_point(destination: Destination) -> RouteCoordinate:
    """The verified visitor entrance when there is one, otherwise the attraction pin."""
    if _has_verified_arrival(destination):
        return RouteCoordinate(lat=destination.arrival_lat, lng=destination.arrival_lng)
    return RouteCoordinate(lat=destination.lat, lng=destination.lng)


async def _travel_times(
    data: TopPlacesRequest,
    candidates: list[_TopPlaceCandidate],
    osrm_client: OSRMClient | None,
) -> tuple[dict[int, _Trip], list[str]]:
    """Travel from the start point to each candidate, with how it was measured."""
    if data.origin is None:
        return {
            item.destination.destination_id: _Trip(None, None, "unknown", None, False)
            for item in candidates
        }, []
    if data.travel_mode == "public_transport":
        return {
            item.destination.destination_id: _straight_line_trip(
                data.origin, item.destination, "public_transport", "commute_estimate",
            )
            for item in candidates
        }, []

    table = None
    if osrm_client is not None and candidates:
        try:
            table = await osrm_client.table(
                travel_mode=data.travel_mode,
                origin=data.origin,
                destinations=[_route_point(item.destination) for item in candidates],
            )
        except OSRMClientError:
            table = None
    if table is None:
        return {
            item.destination.destination_id: _straight_line_trip(
                data.origin, item.destination, data.travel_mode, "straight_line_estimate",
            )
            for item in candidates
        }, (
            ["Road routing was unavailable, so travel times are straight-line estimates."]
            if candidates else []
        )

    source_on_road = (
        table.source_snap_meters is not None
        and table.source_snap_meters <= MAX_PREVIEW_WAYPOINT_SNAP_METERS
    )
    trips: dict[int, _Trip] = {}
    for item, entry in zip(candidates, table.entries):
        destination_id = item.destination.destination_id
        if entry.duration_seconds is None:
            trips[destination_id] = _Trip(
                None, None, "approximate_location", "osrm", False, reachable=False,
            )
            continue
        # A road route counts as verified only to a sourced visitor entrance that
        # OSRM reached without moving either end more than 250 m.
        verified = bool(
            _has_verified_arrival(item.destination)
            and source_on_road
            and entry.snap_meters is not None
            and entry.snap_meters <= MAX_PREVIEW_WAYPOINT_SNAP_METERS
        )
        trips[destination_id] = _Trip(
            minutes=_whole_minutes(entry.duration_seconds),
            distance_km=(
                None if entry.distance_meters is None
                else (Decimal(str(entry.distance_meters)) / 1000).quantize(Decimal("0.01"))
            ),
            basis="road_route" if verified else "approximate_location",
            provider="osrm",
            verified=verified,
        )
    return trips, []


def _shortlist_score(
    data: TopPlacesRequest,
    candidate: _TopPlaceCandidate,
    max_minutes: int,
    weights: dict[str, float],
) -> float:
    """The weighted score with straight-line travel, used only to pick places to route."""
    travel = scoring.NEUTRAL
    if data.origin is not None:
        estimate = _straight_line_trip(
            data.origin, candidate.destination, data.travel_mode, "straight_line_estimate",
        )
        travel = scoring.travel_score(estimate.minutes, max_minutes)
    values = {**candidate.values, "travel": travel}
    values = {name: values.get(name, scoring.NEUTRAL) for name in weights}
    return scoring.total_score(scoring.weighted_points(values, weights))


def _straight_line_trip(
    origin: RouteCoordinate,
    destination: Destination,
    travel_mode: str,
    basis: TopPlaceTravelBasis,
) -> _Trip:
    point = _route_point(destination)
    km = distance_meters(origin.lat, origin.lng, point.lat, point.lng) / 1000
    return _Trip(
        minutes=_whole_minutes(km / float(FALLBACK_SPEED_KMH[travel_mode]) * 3600),
        distance_km=Decimal(str(round(km, 2))).quantize(Decimal("0.01")),
        basis=basis,
        provider="haversine",
        verified=False,
    )


def _whole_minutes(seconds: float) -> int:
    return max(1, round(seconds / 60)) if seconds > 0 else 0


_MODE_WORDS = {"driving": "by car", "walking": "on foot", "public_transport": "by commute"}


def _top_place_reasons(
    *,
    data: TopPlacesRequest,
    candidate: _TopPlaceCandidate,
    trip: _Trip,
    budget_per_person: Decimal | None,
) -> list[str]:
    destination = candidate.destination
    reasons: list[str] = []
    if candidate.matched:
        reasons.append(f"Matches {', '.join(candidate.matched)}.")
    elif not _has_interest_filter(data):
        reasons.append("Add a vibe or interest to rank places by what you like.")

    way = _MODE_WORDS[data.travel_mode]
    if trip.basis == "road_route":
        reasons.append(f"About {trip.minutes} min {way} from your start by road.")
    elif trip.basis == "approximate_location":
        reasons.append(
            f"About {trip.minutes} min {way}; approximate, because the visitor entrance "
            "is not verified yet."
        )
    elif trip.basis == "straight_line_estimate":
        reasons.append(f"About {trip.minutes} min {way} (straight-line estimate).")
    elif trip.basis == "commute_estimate":
        reasons.append(f"About {trip.minutes} min by commute (estimate).")
    else:
        reasons.append("Set a start point to rank by travel time.")

    cost = destination.estimated_cost
    if cost is None:
        reasons.append("Cost not listed.")
    elif budget_per_person is not None:
        reasons.append(
            f"About ₱{cost:,.0f} per person, within your ₱{budget_per_person:,.0f} per person."
        )
    else:
        reasons.append(f"About ₱{cost:,.0f} per person (catalog estimate).")

    if data.child_ages:
        reasons.append("Kid-friendly." if destination.is_kid_friendly else "Not marked kid-friendly.")
    if data.party_size >= scoring.LARGE_GROUP_SIZE and destination.group_friendly:
        reasons.append("Good for groups.")
    if candidate.values.get("popularity", 0.0) > 0:
        reasons.append("Popular with Lakbay travelers.")
    return reasons


_SKIP_PHRASES = {
    "no_interest_match": ("does not match your interests", "do not match your interests"),
    "outside_preferred_districts": ("is outside your chosen districts", "are outside your chosen districts"),
    "missing_required_accessibility": (
        "lacks a required accessibility feature", "lack a required accessibility feature",
    ),
    "over_budget": ("is over your budget", "are over your budget"),
    "needs_boat_or_ferry": ("needs a boat or ferry", "need a boat or ferry"),
    "no_route": ("has no road route from your start", "have no road route from your start"),
    "too_far": ("is too far for your trip length", "are too far for your trip length"),
}


def _top_place_shortfall(
    *,
    data: TopPlacesRequest,
    qualified: int,
    interest_match_count: int,
    skipped: TopPlacesSkipped,
) -> str | None:
    if _has_interest_filter(data) and interest_match_count == 0:
        return "No active catalog destination matches the supplied travel interests."
    if qualified >= data.limit:
        return None
    parts = [
        f"{count} {single if count == 1 else plural}"
        for name, (single, plural) in _SKIP_PHRASES.items()
        if (count := getattr(skipped, name)) > 0
    ]
    found = f"Only {qualified} {'place qualifies' if qualified == 1 else 'places qualify'} for your Top {data.limit}"
    if not parts:
        return f"{found}."
    listed = parts[0] if len(parts) == 1 else f"{', '.join(parts[:-1])} and {parts[-1]}"
    return f"{found}: {listed}."


@dataclass(frozen=True)
class _Wants:
    """What the traveler asked for, resolved against the preference groups."""

    terms: tuple[str, ...]  # free interest words, as typed
    explicit_groups: tuple[str, ...]  # groups chosen directly
    group_keys: tuple[str, ...]  # every group involved
    subtypes: frozenset[str]  # sub-types chosen (directly or by word)
    term_targets: dict[str, tuple[str, str | None]]  # word -> (group, subtype)

    @property
    def total(self) -> int:
        return len(self.terms) + len(self.explicit_groups)


@dataclass(frozen=True)
class _Satisfied:
    labels: list[str]
    fields: list[str]


def _has_interest_filter(data: TopPlacesRequest) -> bool:
    return bool(data.interests or data.preference_groups or data.sub_preferences)


def _resolve_wants(data: TopPlacesRequest, groups: PreferenceGroups) -> _Wants:
    group_keys: list[str] = list(data.preference_groups)
    subtypes: set[str] = set(data.sub_preferences)
    targets: dict[str, tuple[str, str | None]] = {}
    for term in data.interests:
        resolved = groups.resolve(term)
        if resolved is None:
            continue
        targets[term] = (resolved.group, resolved.subtype)
        if resolved.group not in group_keys:
            group_keys.append(resolved.group)
        if resolved.subtype is not None:
            subtypes.add(resolved.subtype)
    return _Wants(
        terms=tuple(data.interests),
        explicit_groups=tuple(data.preference_groups),
        group_keys=tuple(group_keys),
        subtypes=frozenset(subtypes),
        term_targets=targets,
    )


def _satisfied_wants(
    wants: _Wants,
    destination: Destination,
    memberships: dict[str, Membership],
    groups: PreferenceGroups,
) -> _Satisfied:
    """Which of the traveler's wants this place meets.

    A word that names a group is met by group membership *or* by the old text
    match on category, vibes and activities, so nothing that matched before is lost.
    """
    labels: list[str] = []
    fields: list[str] = []
    if wants.terms:
        matched, matched_fields = scoring.interest_matches(list(wants.terms), {
            "category": destination.category,
            "vibes": destination.vibes,
            "activities": destination.activities,
        })
        for term in wants.terms:
            target = wants.term_targets.get(term)
            in_group = False
            if target is not None:
                membership = memberships.get(target[0])
                in_group = membership is not None and (
                    target[1] is None or target[1] in membership.subtypes
                )
            if term in matched or in_group:
                labels.append(term)
        fields.extend(matched_fields)
    for key in wants.explicit_groups:
        membership = memberships.get(key)
        if membership is None:
            continue
        label = groups.groups[key].label
        if label not in labels:
            labels.append(label)
        for subtype_key in sorted(membership.subtypes & wants.subtypes):
            subtype_label = groups.groups[key].subtypes[subtype_key].label
            if subtype_label not in labels:
                labels.append(subtype_label)
        if "category" not in fields:
            fields.append("category")
    return _Satisfied(labels=labels, fields=fields)


def _profile_and_weights(
    wants: _Wants, data: TopPlacesRequest, groups: PreferenceGroups
) -> tuple[WeightProfile, dict[str, float]]:
    """The weight profile for the chosen groups, blended with traveler priorities.

    A specialised profile (such as nature attractions) applies only when every
    chosen group uses it: nature criteria like trail difficulty mean little for
    a beach place. A mixed request, or none, uses the default profile.
    """
    names = {groups.groups[key].weight_profile for key in wants.group_keys}
    profile = get_profile(names.pop() if len(names) == 1 else "default")
    weights = dict(profile.weights)
    if data.priority_order and profile.priority_criteria:
        weights = scoring.blend_priority_weights(
            weights,
            list(data.priority_order[: scoring.THRESHOLDS.max_priorities]),
            profile.priority_criteria,
        )
    return profile, weights


def _candidate_values(
    *,
    profile: WeightProfile,
    data: TopPlacesRequest,
    wants: _Wants,
    destination: Destination,
    satisfied: _Satisfied,
    memberships: dict[str, Membership],
    cost: Decimal | None,
    budget_per_person: Decimal | None,
    party: int,
    popularity_value,
) -> tuple[dict[str, float], set[str]]:
    """Criterion values known before routing, and which of them were missing data."""
    defaults: set[str] = set()
    budget = scoring.budget_score(cost, budget_per_person)
    if cost is None or budget_per_person is None:
        defaults.add("budget")
    group_fit = scoring.group_fit_score(
        has_children=bool(data.child_ages),
        traveler_count=party,
        is_kid_friendly=destination.is_kid_friendly,
        group_friendly=destination.group_friendly,
    )
    if profile.name == "default":
        return {
            "interest": scoring.interest_score(wants.total, len(satisfied.labels)),
            "budget": budget,
            "group_fit": group_fit,
            "popularity": scoring.popularity_score(popularity_value),
        }, defaults

    nature = memberships.get("nature_attractions")
    wanted_level = scoring.ACTIVITY_LEVELS.get(data.activity_level or "")
    place_level = scoring.normalize_difficulty(destination.difficulty_level)
    lower_one_step = data.requires_elderly_friendly or any(
        age <= scoring.THRESHOLDS.young_child_max_age for age in data.child_ages
    )
    physical = scoring.physical_suitability_score(
        place_level=place_level, wanted_level=wanted_level, lower_one_step=lower_one_step,
    )
    if place_level is None or wanted_level is None:
        defaults.add("physical_suitability")
    crowd = scoring.normalize_crowd(destination.crowd_level)
    quiet_popular = scoring.quiet_popular_score(
        prefers_quiet=data.prefers_quiet, crowd=crowd, popularity=popularity_value,
    )
    if (data.prefers_quiet and crowd is None) or (
        not data.prefers_quiet and (popularity_value is None or popularity_value <= 0)
    ):
        defaults.add("quiet_popular")
    return {
        "nature_fit": 0.5 if nature is None else scoring.nature_fit_score(
            nature.subtypes, wants.subtypes,
        ),
        "budget": budget,
        "physical_suitability": physical,
        "group_fit": group_fit,
        "quiet_popular": quiet_popular,
    }, defaults


def _nature_reasons(
    *,
    data: TopPlacesRequest,
    candidate: _TopPlaceCandidate,
    defaults: set[str],
    rain: list[int],
) -> list[str]:
    """Plain-language reasons for the nature-specific criteria."""
    destination = candidate.destination
    reasons: list[str] = []
    if data.activity_level:
        level = scoring.normalize_difficulty(destination.difficulty_level)
        wanted = scoring.ACTIVITY_LEVELS[data.activity_level]
        if level is None:
            reasons.append("Trail difficulty not listed.")
        elif level <= wanted:
            reasons.append(f"Suits a {data.activity_level} pace.")
        else:
            reasons.append(f"Harder than the {data.activity_level} pace you chose.")
    if rain:
        average = round(sum(rain) / len(rain))
        reasons.append(
            f"About {average}% chance of rain on your dates."
            if average < scoring.THRESHOLDS.rain_high_from_percent
            else f"Rain is likely on your dates ({average}%); wet trails and falls can be unsafe."
        )
    if data.prefers_quiet:
        crowd = scoring.normalize_crowd(destination.crowd_level)
        reasons.append(
            {"low": "Usually quiet.", "moderate": "Moderately busy.", "high": "Often crowded."}[crowd]
            if crowd else "Crowd level not listed."
        )
    return reasons


def _duration_words(minutes: int | None) -> str:
    if minutes is None:
        return "an unknown time"
    hours, rest = divmod(int(minutes), 60)
    if hours == 0:
        return f"{rest} min"
    return f"{hours} h" if rest == 0 else f"{hours} h {rest} min"


def _today() -> date:
    """Today's date in the configured timezone (UTC if its data is not installed)."""
    try:
        zone = ZoneInfo(get_settings().timezone)
    except ZoneInfoNotFoundError:
        logger.warning("Timezone %r is not available; using UTC.", get_settings().timezone)
        return datetime.now(UTC).date()
    return datetime.now(zone).date()


def _within(day: date, start: date, end: date) -> bool:
    return start <= day <= end
