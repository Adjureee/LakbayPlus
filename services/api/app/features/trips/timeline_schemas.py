"""Saving a trip's itinerary timeline and reading its revision log."""

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.features.planning.schemas import PlanningState
from app.features.planning.timeline_schemas import PinIn, Timeline


class TripTimelineSave(BaseModel):
    """What to build the timeline from. The server builds and stores it; the client never
    sends a finished timeline."""

    state: PlanningState
    pins: list[PinIn] = Field(default_factory=list, max_length=10)
    include_meals: bool = True


class TripTimelineRevisionSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    revision: int
    created_at: datetime
    created_by_user_id: int | None
    changes: list[str] = Field(default_factory=list)


class TripTimelineRevisionResponse(TripTimelineRevisionSummary):
    state: PlanningState
    timeline: Timeline


class TripTimelineHistory(BaseModel):
    # The newest revision in full, or None when no timeline was saved for the trip.
    latest: TripTimelineRevisionResponse | None = None
    revisions: list[TripTimelineRevisionSummary] = Field(default_factory=list)
