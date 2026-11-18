"""Builds an itinerary timeline from the traveler's picks, in code (no model, no network).

Design: docs/ITINERARY_TIMELINE_DESIGN.md. The builder takes the picks in route order,
the travel legs a route result supplied, and what the place records hold (hours, visit
lengths, booking notes, costs), and returns days of items. Rules that matter:

- Nothing is invented. A leg with no travel time stays `minutes: None` and the times
  after it are provisional; a cost with no price stays unknown; a place with no
  structured hours is placed provisionally and noted.
- Picks are never dropped or reordered. A pick that does not fit is placed anyway, flagged,
  and reported as a conflict the traveler decides on.
- Planning defaults (8:00 start, lunch at 12:00, 15-minute buffers, pace factors) are
  labelled as such and applied only where no recorded value exists.
"""

from dataclasses import dataclass, field
from datetime import date, time, timedelta
from decimal import Decimal
from typing import Literal

from app.features.destinations.hours import clock_text, hours_on
from app.features.planning.draft import _STAY_DURATION_MINUTES
from app.features.planning.timeline_checks import build_checks
from app.features.planning.timeline_schemas import (
    BudgetSummary,
    Conflict,
    CostStatus,
    DurationBasis,
    ItemCost,
    LegBasis,
    TimeBasis,
    Timeline,
    TimelineDay,
    TimelineItem,
    TravelLeg,
)

# Planning defaults, all shown to the traveler as provisional.
DEFAULT_DAY_START = 8 * 60
DEFAULT_DAY_END = 20 * 60
LUNCH_FROM, LUNCH_AT, LUNCH_MINUTES = 11 * 60 + 30, 12 * 60, 60
DINNER_FROM, DINNER_MINUTES = 18 * 60, 60
BUFFER_MINUTES = 15
REST_AFTER, REST_MINUTES = 180, 20
PACE_FACTORS = {"relaxed": 1.25, "balanced": 1.0, "packed": 0.85}
_RANK = {"confirmed": 0, "estimated": 1, "provisional": 2, "unknown": 3}


@dataclass
class HoursInfo:
    open_24_hours: bool | None = None
    # Rows with weekday, is_closed, opens_at, closes_at, last_admission_at; and date
    # exceptions with starts_on, ends_on, is_closed, opens_at, closes_at.
    weekly: list = field(default_factory=list)
    exceptions: list = field(default_factory=list)
    text: str | None = None

    @property
    def structured(self) -> bool:
        return bool(self.weekly or self.exceptions or self.open_24_hours)


@dataclass
class CostInfo:
    label: str
    amount: Decimal | None
    status: CostStatus = "known"
    scope: Literal["per_person", "shared"] = "shared"
    included_in: str | None = None


@dataclass
class StopInfo:
    destination_id: int
    name: str
    typical_visit_min_minutes: int | None = None
    typical_visit_max_minutes: int | None = None
    activity_minutes: int | None = None
    stay_duration_type: str | None = None
    hours: HoursInfo = field(default_factory=HoursInfo)
    operating_status: str | None = None
    booking_requirement: str | None = None
    booking_note: str | None = None
    min_age: int | None = None
    in_region: bool | None = None
    costs: list[CostInfo] = field(default_factory=list)


@dataclass
class LegInfo:
    minutes: int | None
    basis: LegBasis = "unknown"
    mode: str | None = None
    route_verified: bool = False


@dataclass
class Pin:
    destination_id: int
    day: int | None = None
    starts_at: time | None = None


@dataclass
class TimelineInput:
    stops: list[StopInfo]
    # (from place id, to place id); None is the start or the return place.
    legs: dict[tuple[int | None, int | None], LegInfo] = field(default_factory=dict)
    start_date: date | None = None
    day_count: int = 1
    departure_time: time | None = None
    return_deadline: time | None = None
    pace: str | None = None
    return_to_origin: bool = False
    origin_label: str = "your starting point"
    return_label: str | None = None
    traveler_count: int | None = None
    child_ages: list[int] = field(default_factory=list)
    total_budget: Decimal | None = None
    budget_scope: Literal["whole_trip", "per_person"] = "whole_trip"
    meal_cost_per_person: Decimal | None = None
    include_meals: bool = True
    pins: list[Pin] = field(default_factory=list)


@dataclass
class StopMeta:
    """What the checks need to know about how a stop was placed."""

    day: int = 1
    hours: Literal["verified", "unverified", "failed"] = "unverified"
    duration_basis: DurationBasis = "unknown"
    placed: bool = False


def to_minutes(value: time) -> int:
    return value.hour * 60 + value.minute


def to_time(minutes: int) -> time:
    return time((minutes // 60) % 24, minutes % 60)


def _worse(a: TimeBasis, b: TimeBasis) -> TimeBasis:
    return a if _RANK[a] >= _RANK[b] else b


def visit_length(stop: StopInfo, pace: str | None) -> tuple[int, DurationBasis]:
    """A recorded length first, then a planning default scaled by pace."""
    if stop.activity_minutes:
        return stop.activity_minutes, "recorded"
    low, high = stop.typical_visit_min_minutes, stop.typical_visit_max_minutes
    if low and high:
        return (low, "recorded") if low == high else (round((low + high) / 2), "calculated")
    if low or high:
        return (low or high), "recorded"
    key = (stop.stay_duration_type or "half_day").strip().lower()
    base = _STAY_DURATION_MINUTES.get(key, 180)
    factor = PACE_FACTORS.get(pace or "", 1.0)
    return min(480, max(60, round(base * factor))), "planning_default"


class _Builder:
    def __init__(self, inp: TimelineInput) -> None:
        self.inp = inp
        self.day_count = max(1, inp.day_count or 1)
        self.days: list[list[TimelineItem]] = [[]]
        self.day = 0
        self.clock = DEFAULT_DAY_START
        self.basis: TimeBasis = "provisional"
        self.prev_id: int | None = None
        self.lunch = self.dinner = False
        self.since_break = 0
        self.last_was_visit = False
        self.conflicts: list[Conflict] = []
        self.meta: dict[int, StopMeta] = {s.destination_id: StopMeta() for s in inp.stops}
        self.pins = {p.destination_id: p for p in inp.pins}
        self.stops = {s.destination_id: s for s in inp.stops}
        self._start_day(1)

    # ---- state -------------------------------------------------------------------------

    def _start_day(self, number: int) -> None:
        while len(self.days) < number:
            self.days.append([])
        self.day = number - 1
        if self.inp.departure_time is not None:
            self.clock, self.basis = to_minutes(self.inp.departure_time), "confirmed"
        else:
            self.clock, self.basis = DEFAULT_DAY_START, "provisional"
        self.lunch = self.dinner = False
        self.since_break = 0
        self.last_was_visit = False
        if number == 1:
            label = f"Leave {self.inp.origin_label}"
            self._add("depart", label, start=self.clock, minutes=0, dur_basis="calculated")

    def _snapshot(self):
        return (self.day, len(self.days[self.day]), len(self.days), self.clock, self.basis,
                self.prev_id, self.lunch, self.dinner, self.since_break, self.last_was_visit)

    def _restore(self, snap) -> None:
        (self.day, length, days, self.clock, self.basis, self.prev_id, self.lunch,
         self.dinner, self.since_break, self.last_was_visit) = snap
        del self.days[days:]
        del self.days[self.day][length:]

    def _day_end(self) -> int:
        final = self.day == self.day_count - 1
        if final and self.inp.return_deadline is not None:
            return to_minutes(self.inp.return_deadline)
        return DEFAULT_DAY_END

    def _date(self) -> date | None:
        if self.inp.start_date is None:
            return None
        return self.inp.start_date + timedelta(days=self.day)

    # ---- items -------------------------------------------------------------------------

    def _add(
        self, kind, label, *, start, minutes, dur_basis: DurationBasis,
        basis: TimeBasis | None = None, **extra,
    ) -> TimelineItem:
        item = TimelineItem(
            kind=kind, day=self.day + 1, label=label,
            starts_at=to_time(start),
            ends_at=None if minutes is None else to_time(start + minutes),
            duration_minutes=minutes,
            time_basis=basis or self.basis,
            duration_basis=dur_basis,
            **extra,
        )
        self.days[self.day].append(item)
        return item

    def _planning_item(self, kind, label, minutes, *, start=None, costs=None, note=None):
        start = self.clock if start is None else start
        self._add(
            kind, label, start=start, minutes=minutes, dur_basis="planning_default",
            basis="provisional", costs=costs or [],
            notes=[note] if note else ["A planning default, not a confirmed time."],
        )
        self.clock = start + minutes

    def _meal(self, label, at=None) -> None:
        per_person = self.inp.meal_cost_per_person
        cost = ItemCost(
            label="Meal", amount=per_person,
            status="estimated" if per_person is not None else "unknown",
            scope="per_person",
        )
        note = (
            "Meal cost is the traveler's own allowance, not a verified restaurant price."
            if per_person is not None else "No meal allowance set, so the cost is unknown."
        )
        self._planning_item("meal", label, LUNCH_MINUTES, start=at, costs=[cost], note=note)
        self.since_break = 0

    # ---- placing one stop --------------------------------------------------------------

    def _break_items(self) -> None:
        if self.inp.include_meals:
            if not self.lunch and LUNCH_FROM <= self.clock < DINNER_FROM:
                self.lunch = True
                self._meal("Lunch", at=max(self.clock, LUNCH_AT))
            if not self.dinner and self.clock >= DINNER_FROM:
                self.dinner = True
                self._meal("Dinner")
        if self.inp.pace == "relaxed" and self.since_break >= REST_AFTER:
            self._planning_item("rest", "Rest", REST_MINUTES)
            self.since_break = 0

    def _hours_slot(self, stop: StopInfo, arrival: int, length: int):
        """(visit start, problem or None, hours state, note) for one stop on this day."""
        hours = stop.hours
        if stop.operating_status in {"temporarily_closed", "permanently_closed"}:
            return arrival, ("place_closed", f"{stop.name} is recorded as "
                             f"{stop.operating_status.replace('_', ' ')}."), "failed", None
        if hours.open_24_hours:
            return arrival, None, "verified", "Open 24 hours."
        on = self._date()
        if not hours.structured:
            note = ("Hours are listed only as text, so they are not checked: "
                    f"{hours.text}." if hours.text else "Opening hours are not recorded.")
            return arrival, None, "unverified", note
        if on is None:
            return arrival, None, "unverified", (
                "Opening hours are recorded, but no travel date is set to check them against."
            )
        state, windows = hours_on(on, hours.open_24_hours, hours.weekly, hours.exceptions)
        if state == "unknown":
            return arrival, None, "unverified", "Opening hours are not recorded for this day."
        if state == "closed":
            return arrival, ("closed_that_day", f"{stop.name} is closed on {on:%A %d %B}."), \
                "failed", None
        last_admission = self._last_admission(hours, on)
        too_late = False
        for opens, closes in windows:
            opens_m, closes_m = to_minutes(opens), to_minutes(closes)
            start = max(arrival, opens_m)
            if last_admission is not None and start > last_admission:
                too_late = True
                continue
            if start + length > closes_m:
                continue
            note = (f"Opens at {clock_text(opens)}, so the visit starts then."
                    if start > arrival else None)
            return start, None, "verified", note
        code = "after_last_admission" if too_late else "does_not_fit_hours"
        text = (f"{stop.name} would be reached after its last admission."
                if too_late else
                f"A {length}-minute visit to {stop.name} does not fit its opening hours that day.")
        return arrival, (code, text), "failed", None

    @staticmethod
    def _last_admission(hours: HoursInfo, on: date) -> int | None:
        if any(e.starts_on <= on <= e.ends_on for e in hours.exceptions):
            return None
        values = [
            to_minutes(r.last_admission_at) for r in hours.weekly
            if r.weekday == on.weekday() and getattr(r, "last_admission_at", None)
        ]
        return max(values) if values else None

    def _try_place(self, stop: StopInfo, *, force: bool):
        """Adds the items for one stop; returns the problem found, if any."""
        pin = self.pins.get(stop.destination_id)
        self._break_items()
        if self.last_was_visit:
            self._planning_item("buffer", "Buffer", BUFFER_MINUTES,
                                note="A planning buffer between stops.")
        leg = self.inp.legs.get((self.prev_id, stop.destination_id)) or LegInfo(None)
        from_label = (self.inp.origin_label if self.prev_id is None
                      else self.stops[self.prev_id].name)
        travel = TravelLeg(
            from_label=from_label, to_label=stop.name, minutes=leg.minutes,
            basis=leg.basis if leg.minutes is not None else "unknown", mode=leg.mode,
            route_verified=leg.route_verified,
        )
        if leg.minutes is None:
            self._add("travel", f"Travel to {stop.name}", start=self.clock, minutes=None,
                      dur_basis="unknown", travel=travel,
                      notes=["No travel time is available for this leg, so the times after "
                             "it are provisional and will shift once it is known."])
            self.basis = _worse(self.basis, "provisional")
        elif leg.minutes > 0:
            self._add("travel", f"Travel to {stop.name}", start=self.clock,
                      minutes=leg.minutes, dur_basis="calculated", travel=travel,
                      notes=([] if leg.basis == "supported" else
                             ["Estimated from straight-line distance."]))
            self.clock += leg.minutes
            self.basis = _worse(self.basis, "estimated")
        arrival = self.clock
        notes: list[str] = []
        if pin and pin.starts_at is not None:
            wanted = to_minutes(pin.starts_at)
            if wanted >= arrival:
                arrival, self.basis = wanted, "confirmed"
                notes.append("Start time pinned by the traveler.")
            else:
                notes.append("The pinned start time could not be kept: the earlier stops "
                             "run past it.")
        length, dur_basis = visit_length(stop, self.inp.pace)
        start, problem, hours_state, hours_note = self._hours_slot(stop, arrival, length)
        if hours_note:
            notes.append(hours_note)
        waited = start > arrival and hours_state == "verified"
        start_basis = "confirmed" if waited else self.basis
        if dur_basis == "planning_default":
            notes.append("Visit length is a planning default: no recorded visit length.")
        end = start + length
        if problem is None and end > self._day_end():
            problem = ("exceeds_day", f"{stop.name} would end at {clock_text(to_time(end))}, "
                       "after the day's window.")
        if problem is not None and not force:
            return problem
        booking = None
        if stop.booking_requirement or stop.booking_note:
            booking = " ".join(filter(None, [
                {"required": "Booking required.", "recommended": "Booking recommended.",
                 "not_required": "No booking needed."}.get(stop.booking_requirement or ""),
                stop.booking_note,
            ]))
        costs = [ItemCost(label=c.label, amount=c.amount, status=c.status, scope=c.scope,
                          included_in=c.included_in) for c in stop.costs]
        self._add("visit", stop.name, start=start, minutes=length, dur_basis=dur_basis,
                  basis=start_basis, destination_id=stop.destination_id, costs=costs,
                  booking=booking, notes=notes)
        meta = self.meta[stop.destination_id]
        meta.day, meta.hours, meta.duration_basis, meta.placed = (
            self.day + 1, hours_state, dur_basis, True)
        self.clock, self.basis = end, _worse(start_basis, "estimated")
        self.since_break += length
        self.last_was_visit = True
        self.prev_id = stop.destination_id
        return problem

    def place(self, stop: StopInfo) -> None:
        pin = self.pins.get(stop.destination_id)
        if pin and pin.day and pin.day > self.day + 1:
            self._start_day(min(pin.day, self.day_count))
        pinned_here = bool(pin and pin.day)
        while True:
            snap = self._snapshot()
            problem = self._try_place(stop, force=False)
            if problem is None:
                return
            self._restore(snap)
            if self.day < self.day_count - 1 and not pinned_here and problem[0] != "place_closed":
                self._start_day(self.day + 2)
                continue
            problem = self._try_place(stop, force=True)
            if problem is not None:
                self.conflicts.append(Conflict(
                    code=problem[0], destination_id=stop.destination_id,
                    day=self.day + 1, message=problem[1]))
            return

    def finish(self) -> None:
        if not self.inp.return_to_origin or not self.stops:
            return
        label = self.inp.return_label or self.inp.origin_label
        leg = self.inp.legs.get((self.prev_id, None)) or LegInfo(None)
        travel = TravelLeg(
            from_label=self.stops[self.prev_id].name if self.prev_id else self.inp.origin_label,
            to_label=label, minutes=leg.minutes,
            basis=leg.basis if leg.minutes is not None else "unknown", mode=leg.mode,
            route_verified=leg.route_verified)
        if leg.minutes is None:
            self._add("travel", f"Return to {label}", start=self.clock, minutes=None,
                      dur_basis="unknown", travel=travel,
                      notes=["No travel time is available for the return, so the arrival "
                             "time is unknown."])
            return
        if leg.minutes > 0:
            self._add("travel", f"Return to {label}", start=self.clock, minutes=leg.minutes,
                      dur_basis="calculated", travel=travel)
            self.clock += leg.minutes
            self.basis = _worse(self.basis, "estimated")
        self._add("return", f"Back at {label}", start=self.clock, minutes=0,
                  dur_basis="calculated")
        deadline = self.inp.return_deadline
        if deadline is not None and self.day == self.day_count - 1 and \
                self.clock > to_minutes(deadline):
            self.conflicts.append(Conflict(
                code="after_return_deadline", destination_id=None, day=self.day + 1,
                message=(f"The return would arrive at {clock_text(to_time(self.clock))}, "
                         f"after the {clock_text(deadline)} deadline.")))


def summarize_budget(inp: TimelineInput, days: list[TimelineDay]) -> BudgetSummary:
    known = estimated = Decimal("0")
    unknown: list[str] = []
    notes: list[str] = []
    count = inp.traveler_count
    for day in days:
        for item in day.items:
            for cost in item.costs:
                if cost.included_in:
                    notes.append(f"{cost.label} is included in {cost.included_in}, not counted twice.")
                    continue
                if cost.amount is None:
                    unknown.append(f"{cost.label} ({item.label})")
                    continue
                if cost.scope == "per_person":
                    if count is None:
                        unknown.append(f"{cost.label} ({item.label}): traveler count missing")
                        continue
                    amount = cost.amount * count
                else:
                    amount = cost.amount
                if cost.status == "known":
                    known += amount
                else:
                    estimated += amount
    subtotal = known + estimated
    budget = inp.total_budget
    if budget is not None and inp.budget_scope == "per_person":
        budget = budget * count if count else None
    complete = not unknown
    if budget is None:
        fit = "undetermined"
    elif subtotal > budget:
        fit = "over_budget"
    else:
        fit = "fits_known_costs" if complete else "undetermined"
    if not complete:
        notes.append(f"This is not the full trip cost: {len(unknown)} cost(s) are unknown.")
    return BudgetSummary(
        known_total=known, estimated_total=estimated, unknown=unknown, subtotal=subtotal,
        complete=complete, total_budget=budget,
        remaining=(budget - subtotal) if complete and budget is not None else None,
        fit=fit, notes=notes,
    )


def build_timeline(inp: TimelineInput) -> Timeline:
    builder = _Builder(inp)
    for stop in inp.stops:
        builder.place(stop)
    builder.finish()
    days = [
        TimelineDay(
            day=index + 1,
            date=(inp.start_date + timedelta(days=index)).isoformat() if inp.start_date else None,
            items=items,
        )
        for index, items in enumerate(builder.days)
    ]
    budget = summarize_budget(inp, days)
    checks = build_checks(inp, days, builder.conflicts, builder.meta, budget)
    assumptions = []
    if inp.departure_time is None:
        assumptions.append("The day starts at 8:00 (a planning default): no departure time was given.")
    if inp.include_meals:
        assumptions.append("Lunch at 12:00 for 60 minutes and 15-minute buffers between stops "
                           "are planning defaults.")
    if inp.pace in PACE_FACTORS:
        assumptions.append(f"The {inp.pace} pace only scales default visit lengths, "
                           "never a recorded one.")
    failed = [c for c in checks if c.status == "failed"]
    return Timeline(
        days=days, conflicts=builder.conflicts, checks=checks, budget=budget,
        feasible=not failed and not builder.conflicts,
        unverified=[c.message for c in checks if c.status == "cannot_verify"],
        assumptions=assumptions,
    )
