from decimal import Decimal
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, PositiveInt, StringConstraints
from pydantic import field_validator, model_validator

from app.features.planning.schemas import (
    PlanningPreviewResponse,
    PlanningState,
)
from app.features.recommendations.limits import MAX_SUGGESTIONS
from app.features.recommendations.schemas import PlanningRecommendationItem

Money = Annotated[
    Decimal,
    Field(ge=0, max_digits=10, decimal_places=2),
]
TotalBudget = Annotated[
    Decimal,
    Field(gt=0, max_digits=10, decimal_places=2),
]
PreferenceText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=100),
]
ModelRole = Literal["default", "fast", "quality"]
ChatRole = Literal["user", "assistant"]
AILanguage = Literal["auto", "english", "filipino", "bisaya"]


class AIItineraryGenerateRequest(BaseModel):
    total_budget: TotalBudget
    traveler_count: int = Field(ge=1, le=100)
    day_count: int = Field(ge=1, le=30)
    destination_ids: list[PositiveInt] = Field(min_length=1, max_length=10)
    accommodation_ids: list[PositiveInt] = Field(default_factory=list, max_length=50)
    transportation_ids: list[PositiveInt] = Field(default_factory=list, max_length=50)
    meal_cost_per_day: Money = Decimal("0.00")
    miscellaneous_cost: Money = Decimal("0.00")
    interests: list[PreferenceText] = Field(default_factory=list, max_length=15)
    travel_style: str | None = Field(default=None, max_length=100)
    special_requirements: str | None = Field(default=None, max_length=1000)
    language: AILanguage = "auto"
    model_role: ModelRole = "quality"
    compare_models: bool = False
    allow_fallback: bool = True
    planning_state: PlanningState | None = None
    input_revision: int = Field(default=0, ge=0)
    strict_budget_filter: bool = False

    @model_validator(mode="after")
    def validate_unique_ids(self) -> "AIItineraryGenerateRequest":
        _require_unique_ids("destination_ids", self.destination_ids)
        _require_unique_ids("accommodation_ids", self.accommodation_ids)
        _require_unique_ids("transportation_ids", self.transportation_ids)

        return self


class AIItineraryActivity(BaseModel):
    time: str = Field(min_length=1, max_length=20)
    title: str = Field(min_length=1, max_length=255)
    description: str = Field(min_length=1, max_length=1000)
    destination_id: int | None = None
    accommodation_id: int | None = None
    transportation_id: int | None = None
    estimated_cost: Money = Decimal("0.00")
    cost_source: Literal["ai_draft_estimate"] = "ai_draft_estimate"
    notes: str | None = Field(default=None, max_length=1000)


class AIItineraryDay(BaseModel):
    day: PositiveInt
    title: str = Field(min_length=1, max_length=255)
    summary: str = Field(min_length=1, max_length=1000)
    activities: list[AIItineraryActivity] = Field(min_length=1, max_length=20)


class AIItineraryOption(BaseModel):
    option_number: PositiveInt
    title: str = Field(min_length=1, max_length=255)
    summary: str = Field(min_length=1, max_length=1000)
    estimated_total_cost: Money
    cost_source: Literal["ai_draft_estimate"] = "ai_draft_estimate"
    is_over_budget: bool
    days: list[AIItineraryDay] = Field(min_length=1, max_length=30)
    quality_warnings: list[str] = Field(default_factory=list)


class AIModelRunResult(BaseModel):
    ai_generation_run_id: int
    model_role: str
    model_id: str
    status: str
    validation_status: str
    response_time_ms: int | None
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None
    error_message: str | None
    options: list[AIItineraryOption] = Field(default_factory=list)


class AIItineraryGenerateResponse(BaseModel):
    options: list[AIItineraryOption]
    model_runs: list[AIModelRunResult]
    selected_generation_run_id: int | None = None
    planning_preview: PlanningPreviewResponse | None = None
    geo_analytics_context: dict[str, Any] | None = None


class AIChatMessage(BaseModel):
    role: ChatRole
    content: str = Field(min_length=1, max_length=2000)


class AIChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    history: list[AIChatMessage] = Field(default_factory=list, max_length=12)
    context: dict | None = None
    planning_state: PlanningState | None = None
    input_revision: int = Field(default=0, ge=0)
    language: AILanguage = "auto"
    model_role: ModelRole = "default"
    allow_fallback: bool = True
    use_rag: bool = True
    rag_limit: int = Field(default=6, ge=0, le=12)
    is_onboarding: bool = False


class AIPlanningOriginUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: PreferenceText


class AIPlanningStateUpdates(BaseModel):
    """Allowlisted conversational changes; UI selections stay caller-owned."""

    model_config = ConfigDict(extra="forbid")

    origin: AIPlanningOriginUpdate | None = None
    destination_ids: list[PositiveInt] | None = Field(default=None, max_length=10)
    total_budget: TotalBudget | None = None
    budget_scope: Literal["whole_trip", "per_person"] | None = None
    traveler_count: int | None = Field(default=None, ge=1, le=100)
    day_count: int | None = Field(default=None, ge=1, le=30)
    night_count: int | None = Field(default=None, ge=0, le=30)
    return_to_origin: bool | None = None
    interests: list[PreferenceText] | None = Field(default=None, max_length=15)

    @model_validator(mode="after")
    def reject_null_non_clearable_fields(self) -> "AIPlanningStateUpdates":
        for field_name in ("destination_ids", "budget_scope", "interests"):
            if field_name in self.model_fields_set and getattr(self, field_name) is None:
                raise ValueError(f"{field_name} cannot be null; use an empty list to clear it.")
        if self.destination_ids is not None:
            _require_unique_ids("destination_ids", self.destination_ids)
        return self


ChatIntent = Literal[
    "question",
    "brainstorm",
    "show_places",
    "plan_trip",
    "modify_trip",
    "logistics",
    "smalltalk",
]


class AIPlaceQuery(BaseModel):
    model_config = ConfigDict(extra="ignore")

    categories: list[str] = Field(default_factory=list, max_length=10)
    province: str | None = Field(default=None, max_length=120)
    limit: int = Field(default=MAX_SUGGESTIONS, ge=1, le=MAX_SUGGESTIONS)

    @field_validator("limit", mode="before")
    @classmethod
    def clamp_limit(cls, value: object) -> int:
        """A model asking for 8 cards gets 5; an unreadable value gets the default."""
        try:
            number = int(value)  # type: ignore[call-overload]
        except (TypeError, ValueError):
            return MAX_SUGGESTIONS
        return max(1, min(MAX_SUGGESTIONS, number))


class AIPlanningChatOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    chat_response: str = Field(min_length=1, max_length=2000)
    state_updates: AIPlanningStateUpdates = Field(default_factory=AIPlanningStateUpdates)
    # What the traveler wants this turn, judged by the model; the app uses it
    # instead of keyword matching to decide whether to build itineraries.
    intent: ChatIntent | None = None
    place_query: AIPlaceQuery | None = None
    suggested_replies: list[str] = Field(default_factory=list)

    @field_validator("suggested_replies", mode="before")
    @classmethod
    def clean_suggested_replies(cls, value):
        # Advisory UI chips: keep at most three short strings, drop the rest,
        # never reject the whole reply over them.
        if not isinstance(value, list):
            return []
        cleaned = []
        for item in value:
            if isinstance(item, str) and item.strip() and len(item.strip()) <= 80:
                cleaned.append(item.strip())
        return cleaned[:3]

    @field_validator("intent", mode="before")
    @classmethod
    def unknown_intent_is_none(cls, value):
        allowed = {
            "question",
            "brainstorm",
            "show_places",
            "plan_trip",
            "modify_trip",
            "logistics",
            "smalltalk",
        }
        return value if value in allowed else None

    @field_validator("place_query", mode="before")
    @classmethod
    def clean_place_query(cls, value):
        if value is None or not isinstance(value, dict):
            return None
        raw_cats = value.get("categories")
        cats: list[str] = []
        if isinstance(raw_cats, str):
            raw_cats = [raw_cats]
        if isinstance(raw_cats, list):
            for item in raw_cats:
                if isinstance(item, str):
                    cleaned = item.strip()[:60]
                    if cleaned and cleaned.lower() not in {c.lower() for c in cats}:
                        cats.append(cleaned)
        raw_prov = value.get("province")
        province = (
            raw_prov.strip()[:120]
            if isinstance(raw_prov, str) and raw_prov.strip()
            else None
        )
        raw_limit = value.get("limit", 5)
        limit = (
            max(1, min(10, raw_limit))
            if isinstance(raw_limit, int) and not isinstance(raw_limit, bool)
            else 5
        )
        return {"categories": cats[:10], "province": province, "limit": limit}


class AIPlanningChatResult(BaseModel):
    input_revision: int
    intent: ChatIntent | None = None
    place_query: AIPlaceQuery | None = None
    suggested_replies: list[str] = Field(default_factory=list)
    state_updates: dict[str, Any] = Field(default_factory=dict)
    update_status: Literal[
        "applied", "no_changes", "needs_clarification", "invalid_output",
    ]
    preview: PlanningPreviewResponse
    recommendations: list[PlanningRecommendationItem] = Field(default_factory=list)
    recommendation_total_candidates: int = 0
    recommendation_shortfall_reason: str | None = None
    # Where the conversation stands after this reply, computed from the saved
    # state: {"stage", "missing_details", "ask_next"}. The app shows the next
    # question's answer buttons from it.
    conversation: dict[str, Any] | None = None


class AIChatResponse(BaseModel):
    message: str = "ok"
    chat_response: str = Field(min_length=1)
    mode: str = "chat"
    parsed_preferences: dict = Field(default_factory=dict)
    results: list[dict] = Field(default_factory=list)
    retrieved_context: list[dict] = Field(default_factory=list)
    planning: AIPlanningChatResult | None = None
    model_role: str
    model_id: str
    ai_generation_run_id: int
    response_time_ms: int | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None


def _require_unique_ids(field_name: str, values: list[int]) -> None:
    if len(values) != len(set(values)):
        raise ValueError(f"{field_name} must not contain duplicate IDs")


class AITripDraftRequest(BaseModel):
    """Free-text trip request turned into a quick structured draft.

    Used by the app's onboarding and "create trip from prompt" flows, for
    guests and signed-in travelers. Drafts are suggestions, not validated
    catalog itineraries (see /ai/itineraries/generate for those).
    """

    message: str = Field(min_length=1, max_length=2000)
    history: list[AIChatMessage] = Field(default_factory=list, max_length=12)
    current_location: str | None = Field(default=None, max_length=255)
    user_lat: float | None = Field(default=None, ge=-90, le=90)
    user_lng: float | None = Field(default=None, ge=-180, le=180)
    preferred_vibes: list[Annotated[str, StringConstraints(max_length=40)]] = Field(
        default_factory=list, max_length=10,
    )
    strict_budget: bool = False
    default_days: int = Field(default=3, ge=1, le=14)
    language: AILanguage = "auto"


class AITripDraftResponse(BaseModel):
    # The model's JSON: reply, should_create_itinerary, title, destination,
    # vibe, days_count, center_lat/lng, suggested_replies, days[].activities[].
    draft: dict[str, Any]
    model_id: str
    provider: str
