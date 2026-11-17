from datetime import date, datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.features.recommendations.limits import MAX_SUGGESTIONS
from app.features.recommendations.preference_groups import load_groups
from app.features.recommendations.weight_profiles import load_config
from app.features.routes.schemas import RouteCoordinate, TravelMode


InteractionType = Literal["view", "save", "rate", "add_to_itinerary"]
PreferenceText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=100),
]


class RecommendationRequest(BaseModel):
    preferred_categories: list[PreferenceText] = Field(
        default_factory=list,
        max_length=15,
    )
    preferred_vibes: list[PreferenceText] = Field(default_factory=list, max_length=15)
    preferred_activities: list[PreferenceText] = Field(
        default_factory=list,
        max_length=15,
    )
    preferred_districts: list[PreferenceText] = Field(
        default_factory=list,
        max_length=10,
    )
    budget_class: str | None = Field(default=None, max_length=50)
    difficulty_level: str | None = Field(default=None, max_length=50)
    stay_duration_type: str | None = Field(default=None, max_length=50)
    max_estimated_cost: Decimal | None = Field(
        default=None,
        ge=0,
        max_digits=10,
        decimal_places=2,
    )
    requires_kid_friendly: bool = False
    requires_wheelchair_accessible: bool = False
    requires_pet_friendly: bool = False
    requires_elderly_friendly: bool = False
    family_friendly: bool | None = None
    couple_friendly: bool | None = None
    group_friendly: bool | None = None
    limit: int = Field(default=5, ge=1, le=20)


class PreferenceSignalResponse(BaseModel):
    preference_signal_id: int
    user_id: int
    preferred_categories: list[str]
    preferred_vibes: list[str]
    preferred_activities: list[str]
    preferred_districts: list[str]
    budget_class: str | None
    difficulty_level: str | None
    stay_duration_type: str | None
    max_estimated_cost: Decimal | None
    requires_kid_friendly: bool
    requires_wheelchair_accessible: bool
    requires_pet_friendly: bool
    requires_elderly_friendly: bool
    family_friendly: bool | None
    couple_friendly: bool | None
    group_friendly: bool | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class RecommendationItem(BaseModel):
    destination_id: int
    name: str
    district: str | None
    category: str | None
    estimated_cost: Decimal | None
    score: float
    matched_fields: list[str]
    reasons: list[str]


class RecommendationResponse(BaseModel):
    preference_signal_id: int
    total_candidates: int
    recommendations: list[RecommendationItem]


TopPlaceTravelBasis = Literal[
    "road_route",            # verified entrance, provider road route
    "approximate_location",  # provider road route to the attraction pin
    "straight_line_estimate",  # routing unavailable; Haversine at a fallback speed
    "commute_estimate",      # public transport; Haversine until commute legs exist
    "unknown",               # no start point
]
TopPlaceCostBasis = Literal["catalog_estimate", "not_listed"]


class TopPlacesRequest(BaseModel):
    interests: list[PreferenceText] = Field(default_factory=list, max_length=15)
    preferred_districts: list[PreferenceText] = Field(default_factory=list, max_length=10)
    origin: RouteCoordinate | None = None
    travel_mode: TravelMode = "driving"
    total_budget: Decimal | None = Field(default=None, gt=0, max_digits=10, decimal_places=2)
    budget_scope: Literal["whole_trip", "per_person"] = "whole_trip"
    traveler_count: int | None = Field(default=None, ge=1, le=100)
    adult_count: int | None = Field(default=None, ge=0, le=100)
    child_ages: list[int] = Field(default_factory=list, max_length=100)
    day_count: int | None = Field(default=None, ge=1, le=30)
    requires_kid_friendly: bool = False
    requires_wheelchair_accessible: bool = False
    requires_pet_friendly: bool = False
    requires_elderly_friendly: bool = False
    limit: int = Field(default=MAX_SUGGESTIONS, ge=1, le=MAX_SUGGESTIONS)
    ranking_method: Literal["simple_additive_weighting", "topsis"] = (
        "simple_additive_weighting"
    )
    # Preference groups from GET /destinations/facets (for example
    # "nature_attractions") and sub-types within them (for example "waterfalls").
    # Words such as "nature" or "waterfalls" are accepted and resolved.
    preference_groups: list[PreferenceText] = Field(default_factory=list, max_length=6)
    sub_preferences: list[PreferenceText] = Field(default_factory=list, max_length=12)
    activity_level: Literal["easy", "moderate", "challenging"] | None = None
    # Start of the trip. Needed to score weather; there is no assumed season.
    travel_start_date: date | None = None
    prefers_quiet: bool = False
    # Up to three of the profile's priorities, most important first.
    priority_order: list[PreferenceText] = Field(default_factory=list, max_length=3)
    # Fill the list up to `limit` with clearly labelled near matches (a longer
    # trip or slightly over budget) when fewer places fit strictly.
    fill_to_limit: bool = False

    @model_validator(mode="after")
    def validate_child_ages(self) -> "TopPlacesRequest":
        if any(age < 0 or age > 17 for age in self.child_ages):
            raise ValueError("child_ages must be between 0 and 17 years.")
        return self

    @model_validator(mode="after")
    def validate_preferences(self) -> "TopPlacesRequest":
        groups = load_groups()
        group_keys: list[str] = []
        sub_keys: list[str] = []
        for term in self.preference_groups:
            resolved = groups.resolve(term)
            if resolved is None:
                raise ValueError(f"'{term}' is not a known preference group.")
            if resolved.group not in group_keys:
                group_keys.append(resolved.group)
            if resolved.subtype is not None and resolved.subtype not in sub_keys:
                sub_keys.append(resolved.subtype)
        for term in self.sub_preferences:
            resolved = groups.resolve(term)
            if resolved is None or resolved.subtype is None:
                raise ValueError(f"'{term}' is not a known sub-preference.")
            if resolved.group not in group_keys:
                group_keys.append(resolved.group)
            if resolved.subtype not in sub_keys:
                sub_keys.append(resolved.subtype)
        known_priorities = {
            name
            for profile in load_config().profiles.values()
            for name in profile.priority_criteria
        }
        unknown = [name for name in self.priority_order if name not in known_priorities]
        if unknown:
            raise ValueError(
                f"Unknown priority {unknown[0]!r}. Choose from: {', '.join(sorted(known_priorities))}."
            )
        if len(set(self.priority_order)) != len(self.priority_order):
            raise ValueError("priority_order cannot repeat a priority.")
        self.preference_groups = group_keys
        self.sub_preferences = sub_keys
        return self

    @property
    def party_size(self) -> int:
        return max(
            self.traveler_count or 0,
            (self.adult_count or 0) + len(self.child_ages),
            1,
        )


class TopPlaceFactor(BaseModel):
    value: float = Field(description="Normalized factor score from 0 to 1.")
    weight: float
    points: float = Field(description="Contribution to the 0-100 score: 100 x weight x value.")


class TopPlaceFactorDetail(BaseModel):
    """One criterion of the weighted score, for any weight profile."""

    criterion: str
    label: str
    value: float = Field(description="Normalized score from 0 to 1.")
    weight: float
    points: float
    used_default: bool = Field(
        default=False,
        description="True when the data was missing and the neutral value 0.5 was used.",
    )


class TopPlaceBreakdown(BaseModel):
    interest: TopPlaceFactor
    travel: TopPlaceFactor
    budget: TopPlaceFactor
    group_fit: TopPlaceFactor
    popularity: TopPlaceFactor


class TopPlaceItem(BaseModel):
    rank: int
    destination_id: int
    name: str
    district: str | None
    category: str | None
    image_url: str | None
    estimated_cost: Decimal | None
    cost_basis: TopPlaceCostBasis
    # The place's pin, so a card can be shown on a map without a second lookup.
    lat: float | None = None
    lng: float | None = None
    score: float
    # The five default-profile factors; None for other profiles (see `factors`).
    breakdown: TopPlaceBreakdown | None = None
    profile: str = "default"
    factors: list[TopPlaceFactorDetail] = Field(default_factory=list)
    # 1 = fits every limit. 2 or 3 = one or two limits were relaxed to fill the
    # list; `relaxations` says which, in plain words.
    match_tier: int = Field(default=1, ge=1, le=3)
    relaxations: list[str] = Field(default_factory=list)
    matched_interests: list[str]
    matched_fields: list[str]
    reasons: list[str]
    route_verified: bool
    travel_mode: TravelMode
    travel_basis: TopPlaceTravelBasis
    route_provider: str | None
    travel_minutes: int | None
    travel_distance_km: Decimal | None


class TopPlacesSkipped(BaseModel):
    no_interest_match: int = 0
    outside_preferred_districts: int = 0
    missing_required_accessibility: int = 0
    over_budget: int = 0
    needs_boat_or_ferry: int = 0
    no_route: int = 0
    too_far: int = 0


class TopPlacesResponse(BaseModel):
    method: Literal["simple_additive_weighting", "topsis"] = "simple_additive_weighting"
    profile: str = "default"
    # The weights actually applied (profile weights, blended with any priorities).
    weights: dict[str, float]
    relaxed_count: int = 0
    max_travel_minutes: int
    preference_signal_id: int | None
    total_candidates: int
    verified_count: int
    items: list[TopPlaceItem]
    skipped: TopPlacesSkipped
    shortfall_reason: str | None
    warnings: list[str]


class PlanningRecommendationItem(RecommendationItem):
    """A Top 5 place in the planning chat; `score` is the 0-100 weighted score."""

    image_url: str | None = None
    lat: float | None = None
    lng: float | None = None
    route_provider: str | None = None
    travel_mode: TravelMode
    route_distance_km: Decimal | None = None
    route_duration_minutes: int | None = None
    route_verified: bool = False
    travel_basis: TopPlaceTravelBasis = "unknown"
    breakdown: TopPlaceBreakdown | None = None
    profile: str = "default"
    factors: list[TopPlaceFactorDetail] = Field(default_factory=list)
    match_tier: int = Field(default=1, ge=1, le=3)
    relaxations: list[str] = Field(default_factory=list)


class PlaceQueryResult(BaseModel):
    items: list[TopPlaceItem] = Field(default_factory=list)
    total_candidates: int = 0
    target_province: str | None = None
    other_province_counts: dict[str, int] = Field(default_factory=dict)
    nearest_provinces: list[str] = Field(default_factory=list)
    shortfall_reason: str | None = None


class DestinationInteractionCreate(BaseModel):
    interaction_type: InteractionType
    rating: int | None = Field(default=None, ge=1, le=5)
    notes: str | None = Field(default=None, max_length=1000)

    @model_validator(mode="after")
    def validate_rating_for_type(self) -> "DestinationInteractionCreate":
        if self.interaction_type == "rate" and self.rating is None:
            raise ValueError("rating is required for rate interactions")

        if self.interaction_type != "rate" and self.rating is not None:
            raise ValueError("rating is only allowed for rate interactions")

        return self


class DestinationInteractionResponse(BaseModel):
    interaction_id: int
    user_id: int
    destination_id: int
    interaction_type: str
    rating: int | None
    notes: str | None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class DestinationPopularityResponse(BaseModel):
    destination_id: int
    view_count: int
    save_count: int
    rating_count: int
    rating_sum: int
    average_rating: Decimal
    add_to_itinerary_count: int
    popularity_score: Decimal
    created_at: datetime | None
    updated_at: datetime | None

    model_config = ConfigDict(from_attributes=True)
