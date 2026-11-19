"""What the itinerary timeline engine returns (docs/ITINERARY_TIMELINE_DESIGN.md).

Every time says how far to trust it, every cost says whether it is known, and every
check is passed, failed or cannot verify. Unknown stays unknown: a leg with no travel
time has `minutes: None`, a cost with no price has `amount: None`.
"""

from datetime import time
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field

from app.features.planning.schemas import PlanningPreviewRequest

ItemKind = Literal["depart", "travel", "visit", "meal", "rest", "buffer", "return"]
# confirmed: fixed by the traveler or by recorded opening hours, nothing uncertain before
# it; estimated: calculated from recorded or estimated durations and travel times;
# provisional: depends on a planning default or on a leg with no travel time; unknown.
TimeBasis = Literal["confirmed", "estimated", "provisional", "unknown"]
DurationBasis = Literal["recorded", "planning_default", "calculated", "unknown"]
LegBasis = Literal["supported", "estimated", "unknown"]
CostStatus = Literal["known", "estimated", "unknown"]
CheckStatus = Literal["passed", "failed", "cannot_verify"]
ConflictCode = Literal[
    "closed_that_day", "does_not_fit_hours", "after_last_admission", "exceeds_day",
    "after_return_deadline", "place_closed",
]
# What the traveler can do about a conflict (specification B6); nothing is removed for them.
CONFLICT_CHOICES = ("prioritise_places", "change_time_window", "relax_another_constraint")


class TravelLeg(BaseModel):
    from_label: str
    to_label: str
    minutes: int | None
    basis: LegBasis
    mode: str | None = None
    route_verified: bool = False


class ItemCost(BaseModel):
    label: str
    amount: Decimal | None
    status: CostStatus
    scope: Literal["per_person", "shared"] = "shared"
    # Set when the amount is already part of another price (admission, a package).
    included_in: str | None = None
    # False for an estimate whose charging basis is not recorded (per person? per trip?):
    # it is shown, but it never decides whether the trip fits the budget.
    basis_recorded: bool = True


class TimelineItem(BaseModel):
    kind: ItemKind
    day: int
    starts_at: time | None
    ends_at: time | None
    duration_minutes: int | None
    time_basis: TimeBasis
    duration_basis: DurationBasis
    label: str
    destination_id: int | None = None
    travel: TravelLeg | None = None
    costs: list[ItemCost] = Field(default_factory=list)
    booking: str | None = None
    notes: list[str] = Field(default_factory=list)


class TimelineDay(BaseModel):
    day: int
    date: str | None = None
    items: list[TimelineItem] = Field(default_factory=list)


class Conflict(BaseModel):
    code: ConflictCode
    destination_id: int | None
    day: int | None
    message: str
    choices: list[str] = Field(default_factory=lambda: list(CONFLICT_CHOICES))


class Check(BaseModel):
    id: str
    status: CheckStatus
    message: str
    destination_ids: list[int] = Field(default_factory=list)


class BudgetSummary(BaseModel):
    known_total: Decimal
    estimated_total: Decimal
    # Items whose cost is unknown; the totals above are not the full trip cost while
    # this is not empty.
    unknown: list[str] = Field(default_factory=list)
    # Estimates with no recorded charging basis (included in the totals, not used to
    # decide whether the trip fits).
    unbased: list[str] = Field(default_factory=list)
    # What the traveler could add to complete the estimate (prompts, not costs).
    to_complete: list[str] = Field(default_factory=list)
    subtotal: Decimal
    complete: bool
    total_budget: Decimal | None = None
    # Only when the picture is complete and a budget is set (specification B7).
    remaining: Decimal | None = None
    # fits_known_costs: complete and within budget; over_budget: the known subtotal
    # already exceeds it; undetermined: unknown costs remain, or no budget was given.
    fit: Literal["fits_known_costs", "over_budget", "undetermined"]
    notes: list[str] = Field(default_factory=list)


class PinIn(BaseModel):
    """A stop the traveler locked to a day and/or a start time; the builder keeps it."""

    destination_id: int
    day: int | None = Field(default=None, ge=1, le=30)
    starts_at: time | None = None


class Timeline(BaseModel):
    days: list[TimelineDay]
    conflicts: list[Conflict] = Field(default_factory=list)
    checks: list[Check] = Field(default_factory=list)
    budget: BudgetSummary
    # True only when nothing failed and no pick is in conflict. It never means "fully
    # verified": the checks that cannot verify are listed in `unverified`.
    feasible: bool
    unverified: list[str] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list)
    # The pins that were in effect when this timeline was built, so a saved or restored
    # revision keeps them and the next revision starts from them.
    pins: list[PinIn] = Field(default_factory=list)


class TimelineRequest(PlanningPreviewRequest):
    """The trip state plus what a revision needs: pins and the timeline being revised."""

    pins: list[PinIn] = Field(default_factory=list, max_length=10)
    previous: Timeline | None = None
    include_meals: bool = True


class TimelineResponse(BaseModel):
    input_revision: int
    timeline: Timeline
    # Plain-language list of what moved since `previous`; empty without a previous one.
    changes: list[str] = Field(default_factory=list)
    route_status: str = "not_requested"
    # Picks that are no longer active in the catalog: reported, never silently dropped.
    unavailable_destination_ids: list[int] = Field(default_factory=list)
