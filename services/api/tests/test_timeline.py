"""The itinerary timeline engine: times, legs, hours, conflicts, budget and checks.

Pure functions on fixed data: no model, no network, no database.
"""

from datetime import date, time
from decimal import Decimal
from types import SimpleNamespace as N

from app.features.planning.timeline import (
    CostInfo,
    HoursInfo,
    LegInfo,
    Pin,
    StopInfo,
    TimelineInput,
    build_timeline,
    visit_length,
)

THU = date(2026, 11, 19)  # a Thursday: weekday 3


def hhmm(value) -> str:
    return value.strftime("%H:%M") if value else "None"


def stop(destination_id=1, name="Eden", **fields) -> StopInfo:
    return StopInfo(destination_id, name, **fields)


def legs(*pairs):
    return {(a, b): LegInfo(m, basis) for a, b, m, basis in pairs}


def build(stops, leg_pairs=(), **fields):
    return build_timeline(TimelineInput(stops=stops, legs=legs(*leg_pairs), **fields))


def items(timeline, kind=None, day=1):
    found = timeline.days[day - 1].items
    return [i for i in found if kind is None or i.kind == kind]


def check(timeline, check_id):
    return next(c for c in timeline.checks if c.id == check_id)


def weekly(*rows):
    """Rows: (weekday, opens, closes, closed, last_admission)."""
    return [N(weekday=d, opens_at=o, closes_at=c, is_closed=cl, last_admission_at=la)
            for d, o, c, cl, la in rows]


# --- times and travel -------------------------------------------------------------------


def test_a_day_is_built_from_the_legs_and_recorded_lengths_in_order():
    timeline = build(
        [stop(1, "Eden", typical_visit_min_minutes=120, typical_visit_max_minutes=120),
         stop(2, "Museo", activity_minutes=60)],
        [(None, 1, 45, "supported"), (1, 2, 20, "supported"), (2, None, 50, "supported")],
        start_date=THU, departure_time=time(8), return_to_origin=True,
    )
    rows = [(i.kind, hhmm(i.starts_at), hhmm(i.ends_at)) for i in items(timeline)]
    assert rows == [
        ("depart", "08:00", "08:00"),
        ("travel", "08:00", "08:45"),
        ("visit", "08:45", "10:45"),
        ("buffer", "10:45", "11:00"),
        ("travel", "11:00", "11:20"),
        ("visit", "11:20", "12:20"),
        ("travel", "12:20", "13:10"),
        ("return", "13:10", "13:10"),
    ]
    assert [i.destination_id for i in items(timeline, "visit")] == [1, 2]  # picks keep order


def test_a_traveler_stated_departure_is_confirmed_and_a_default_start_is_provisional():
    stated = build([stop()], [(None, 1, 30, "supported")], departure_time=time(9))
    assert items(stated, "travel")[0].time_basis == "confirmed"
    assert hhmm(items(stated, "travel")[0].starts_at) == "09:00"

    default = build([stop()], [(None, 1, 30, "supported")])
    assert hhmm(items(default, "travel")[0].starts_at) == "08:00"
    assert items(default, "travel")[0].time_basis == "provisional"
    assert any("8:00" in text for text in default.assumptions)


def test_a_leg_with_no_travel_time_stays_unknown_and_the_rest_is_provisional():
    timeline = build(
        [stop(1, "Eden", activity_minutes=60), stop(2, "Museo", activity_minutes=60)],
        [(None, 1, 30, "supported")],  # no leg from Eden to Museo
        departure_time=time(8),
    )
    travel = items(timeline, "travel")
    assert travel[1].travel.minutes is None and travel[1].duration_minutes is None
    assert travel[1].ends_at is None and travel[1].duration_basis == "unknown"
    # The clock did not move for the unknown leg, and what follows says so.
    assert items(timeline, "visit")[1].time_basis == "provisional"
    assert check(timeline, "travel_times").status == "cannot_verify"
    assert "Eden to Museo" in check(timeline, "travel_times").message


def test_estimated_legs_cannot_be_verified_but_still_get_a_time():
    timeline = build([stop()], [(None, 1, 40, "estimated")], departure_time=time(8))
    leg = items(timeline, "travel")[0]
    assert leg.duration_minutes == 40 and "straight-line" in leg.notes[0]
    assert check(timeline, "travel_times").status == "cannot_verify"


def test_pace_scales_planning_defaults_only_never_a_recorded_length():
    short = stop(stay_duration_type="short")  # default 90 minutes
    assert visit_length(short, "balanced") == (90, "planning_default")
    assert visit_length(short, "relaxed") == (112, "planning_default")  # x1.25
    assert visit_length(short, "packed")[0] == 76  # x0.85, floored at 60
    recorded = stop(activity_minutes=90)
    assert visit_length(recorded, "relaxed") == (90, "recorded")
    ranged = stop(typical_visit_min_minutes=60, typical_visit_max_minutes=120)
    assert visit_length(ranged, "packed") == (90, "calculated")
    assert visit_length(stop(), None)[1] == "planning_default"


def test_a_planning_default_length_makes_the_visit_durations_check_unverifiable():
    timeline = build([stop(stay_duration_type="short")], [(None, 1, 10, "supported")])
    assert check(timeline, "visit_durations").status == "cannot_verify"
    assert any("planning default" in n for n in items(timeline, "visit")[0].notes)
    recorded = build([stop(activity_minutes=60)], [(None, 1, 10, "supported")])
    assert check(recorded, "visit_durations").status == "passed"


# --- opening hours ----------------------------------------------------------------------


def hours_rows(opens, closes, last=None, weekday=3):
    return HoursInfo(weekly=weekly((weekday, opens, closes, False, last)))


def test_a_visit_waits_for_opening_time_and_that_start_is_confirmed():
    place = stop(activity_minutes=60, hours=hours_rows(time(9), time(17)))
    timeline = build([place], [(None, 1, 30, "supported")], start_date=THU,
                     departure_time=time(8))
    visit = items(timeline, "visit")[0]
    assert hhmm(visit.starts_at) == "09:00" and visit.time_basis == "confirmed"
    assert any("Opens at 9:00 AM" in n for n in visit.notes)
    assert check(timeline, "opening_hours").status == "passed"


def test_a_visit_that_does_not_fit_moves_to_the_next_day_when_there_is_one():
    place = stop(activity_minutes=120, hours=HoursInfo(weekly=weekly(
        (3, time(9), time(10), False, None), (4, time(9), time(17), False, None))))
    timeline = build([place], [(None, 1, 10, "supported")], start_date=THU, day_count=2,
                     departure_time=time(8))
    assert items(timeline, "visit", day=1) == []
    visit = items(timeline, "visit", day=2)[0]
    assert hhmm(visit.starts_at) == "09:00"
    assert timeline.conflicts == [] and timeline.feasible


def test_a_pick_that_cannot_fit_is_kept_flagged_and_offered_three_choices():
    place = stop(activity_minutes=120, hours=hours_rows(time(9), time(10)))
    timeline = build([place], [(None, 1, 10, "supported")], start_date=THU,
                     departure_time=time(8))
    assert [i.destination_id for i in items(timeline, "visit")] == [1]  # never dropped
    assert [c.code for c in timeline.conflicts] == ["does_not_fit_hours"]
    assert timeline.conflicts[0].choices == [
        "prioritise_places", "change_time_window", "relax_another_constraint"]
    assert check(timeline, "opening_hours").status == "failed" and not timeline.feasible


def test_a_place_closed_that_weekday_is_a_conflict():
    place = stop(hours=HoursInfo(weekly=weekly((3, None, None, True, None),
                                               (4, time(9), time(17), False, None))))
    timeline = build([place], [(None, 1, 10, "supported")], start_date=THU)
    assert [c.code for c in timeline.conflicts] == ["closed_that_day"]


def test_after_the_last_admission_is_a_conflict():
    place = stop(activity_minutes=30, hours=hours_rows(time(8), time(18), last=time(9)))
    timeline = build([place], [(None, 1, 90, "supported")], start_date=THU,
                     departure_time=time(8))
    assert [c.code for c in timeline.conflicts] == ["after_last_admission"]


def test_a_date_exception_closes_a_place_that_is_normally_open():
    place = stop(hours=HoursInfo(
        weekly=weekly((3, time(8), time(17), False, None)),
        exceptions=[N(starts_on=THU, ends_on=THU, is_closed=True, opens_at=None,
                      closes_at=None, reason="Holiday")]))
    timeline = build([place], [(None, 1, 10, "supported")], start_date=THU)
    assert [c.code for c in timeline.conflicts] == ["closed_that_day"]


def test_text_only_hours_and_missing_hours_are_noted_and_cannot_be_verified():
    text_only = stop(hours=HoursInfo(text="Daytime visits"))
    timeline = build([text_only], [(None, 1, 10, "supported")], start_date=THU)
    assert any("Daytime visits" in n for n in items(timeline, "visit")[0].notes)
    assert check(timeline, "opening_hours").status == "cannot_verify"
    assert timeline.conflicts == []


def test_recorded_hours_with_no_travel_date_cannot_be_checked():
    place = stop(hours=hours_rows(time(9), time(17)))
    timeline = build([place], [(None, 1, 10, "supported")])  # no start_date
    assert check(timeline, "opening_hours").status == "cannot_verify"
    assert check(timeline, "travel_date").status == "cannot_verify"


def test_open_24_hours_is_verified_and_a_closed_status_is_a_conflict_that_is_not_moved():
    assert check(build([stop(hours=HoursInfo(open_24_hours=True))],
                       [(None, 1, 10, "supported")], start_date=THU),
                 "opening_hours").status == "passed"
    closed = build([stop(operating_status="temporarily_closed")],
                   [(None, 1, 10, "supported")], day_count=3)
    assert [c.code for c in closed.conflicts] == ["place_closed"]
    assert len(items(closed, "visit", day=1)) == 1  # not shuffled to another day
    assert check(closed, "operating_status").status == "failed"


# --- days, meals, rest, return ----------------------------------------------------------


def test_a_stop_that_runs_past_the_day_moves_on_or_becomes_a_conflict():
    long = [stop(1, "A", activity_minutes=420), stop(2, "B", activity_minutes=420)]
    two_days = build(long, [(None, 1, 10, "supported"), (1, 2, 10, "supported")],
                     day_count=2, departure_time=time(8))
    assert [len(items(two_days, "visit", day=d)) for d in (1, 2)] == [1, 1]
    assert two_days.conflicts == []
    one_day = build(long, [(None, 1, 10, "supported"), (1, 2, 10, "supported")],
                    day_count=1, departure_time=time(8))
    assert [c.code for c in one_day.conflicts] == ["exceeds_day"]
    assert len(items(one_day, "visit")) == 2  # both picks stay listed


def test_lunch_is_a_provisional_item_with_an_unknown_cost_unless_an_allowance_is_set():
    stops = [stop(1, "A", activity_minutes=210), stop(2, "B", activity_minutes=60)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 10, "supported")]
    plain = build(stops, pairs, departure_time=time(8), traveler_count=2)
    meal = items(plain, "meal")[0]
    assert hhmm(meal.starts_at) == "12:00" and meal.time_basis == "provisional"
    assert meal.costs[0].amount is None and meal.costs[0].status == "unknown"
    assert any("Meal" in u for u in plain.budget.unknown)

    allowed = build(stops, pairs, departure_time=time(8), traveler_count=2,
                    meal_cost_per_person=Decimal("150"))
    assert allowed.budget.estimated_total == Decimal("300")
    assert "allowance" in items(allowed, "meal")[0].notes[0]

    none = build(stops, pairs, departure_time=time(8), include_meals=False)
    assert items(none, "meal") == []


def test_a_relaxed_pace_adds_a_rest_after_three_hours_of_visits():
    stops = [stop(1, "A", activity_minutes=200), stop(2, "B", activity_minutes=30)]
    pairs = [(None, 1, 5, "supported"), (1, 2, 5, "supported")]
    relaxed = build(stops, pairs, departure_time=time(8), pace="relaxed", include_meals=False)
    assert [i.kind for i in items(relaxed)].count("rest") == 1
    balanced = build(stops, pairs, departure_time=time(8), pace="balanced", include_meals=False)
    assert "rest" not in [i.kind for i in items(balanced)]


def test_the_return_is_checked_against_the_deadline():
    pairs = [(None, 1, 30, "supported"), (1, None, 90, "supported")]
    late = build([stop(activity_minutes=300)], pairs, departure_time=time(8),
                 return_deadline=time(14), return_to_origin=True)
    assert [c.code for c in late.conflicts] == ["after_return_deadline"]
    assert check(late, "return_deadline").status == "failed"

    ok = build([stop(activity_minutes=60)], pairs, departure_time=time(8),
               return_deadline=time(18), return_to_origin=True)
    assert check(ok, "return_deadline").status == "passed"

    no_leg = build([stop(activity_minutes=60)], [(None, 1, 30, "supported")],
                   departure_time=time(8), return_deadline=time(18), return_to_origin=True)
    assert check(no_leg, "return_deadline").status == "cannot_verify"
    assert items(no_leg, "return") == []  # no invented arrival time


def test_a_one_way_trip_has_no_return():
    timeline = build([stop()], [(None, 1, 30, "supported")], return_to_origin=False)
    assert items(timeline, "return") == []
    assert not any(c.id == "return_deadline" for c in timeline.checks)


def test_pins_keep_a_stop_on_its_day_and_at_its_time():
    stops = [stop(1, "A", activity_minutes=60), stop(2, "B", activity_minutes=60)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 10, "supported")]
    timeline = build(stops, pairs, day_count=2, departure_time=time(8),
                     pins=[Pin(2, day=2, starts_at=time(10))])
    visit = items(timeline, "visit", day=2)[0]
    assert visit.destination_id == 2 and hhmm(visit.starts_at) == "10:00"
    assert visit.time_basis == "confirmed" and "pinned" in visit.notes[0]


# --- budget -----------------------------------------------------------------------------


def test_budget_separates_known_estimated_and_unknown_and_never_calls_incomplete_complete():
    place = stop(costs=[
        CostInfo("Entrance", Decimal("100"), "known", scope="per_person"),
        CostInfo("Parking", Decimal("50"), "estimated"),
        CostInfo("Zipline", None, "unknown"),
    ])
    timeline = build([place], [(None, 1, 10, "supported")], traveler_count=3,
                     total_budget=Decimal("1000"), include_meals=False)
    budget = timeline.budget
    assert (budget.known_total, budget.estimated_total) == (Decimal("300"), Decimal("50"))
    assert budget.subtotal == Decimal("350") and not budget.complete
    assert budget.unknown == ["Zipline (Eden)"]
    assert budget.remaining is None and budget.fit == "undetermined"
    assert any("not the full trip cost" in n for n in budget.notes)


def test_a_complete_budget_has_a_remaining_amount_and_fits_only_then():
    place = stop(costs=[CostInfo("Entrance", Decimal("100"), "known", scope="per_person")])
    timeline = build([place], [(None, 1, 10, "supported")], traveler_count=2,
                     total_budget=Decimal("1000"), include_meals=False)
    assert timeline.budget.complete and timeline.budget.remaining == Decimal("800")
    assert timeline.budget.fit == "fits_known_costs"


def test_known_costs_over_the_budget_are_reported_even_when_incomplete():
    place = stop(costs=[CostInfo("Entrance", Decimal("900"), "known"),
                        CostInfo("Fee", None, "unknown")])
    timeline = build([place], [(None, 1, 10, "supported")], total_budget=Decimal("500"),
                     include_meals=False)
    assert timeline.budget.fit == "over_budget"


def test_a_fee_included_in_admission_is_not_counted_twice():
    place = stop(costs=[CostInfo("Entrance", Decimal("100"), "known"),
                        CostInfo("Guided walk", Decimal("40"), "known",
                                 included_in="admission")])
    timeline = build([place], [(None, 1, 10, "supported")], include_meals=False)
    assert timeline.budget.subtotal == Decimal("100")
    assert any("not counted twice" in n for n in timeline.budget.notes)


def test_a_per_person_budget_scales_with_the_group_and_a_missing_count_is_unknown():
    place = stop(costs=[CostInfo("Entrance", Decimal("100"), "known", scope="per_person")])
    scaled = build([place], [(None, 1, 10, "supported")], traveler_count=4,
                   total_budget=Decimal("500"), budget_scope="per_person", include_meals=False)
    assert scaled.budget.total_budget == Decimal("2000")
    no_count = build([place], [(None, 1, 10, "supported")], include_meals=False)
    assert not no_count.budget.complete
    assert check(no_count, "budget_arithmetic").status == "cannot_verify"


# --- the other checks -------------------------------------------------------------------


def test_missing_information_never_counts_as_passed():
    timeline = build([stop()], [(None, 1, 10, "supported")])
    for check_id in ("geographic_scope", "operating_status", "opening_hours",
                     "visit_durations", "travel_date"):
        assert check(timeline, check_id).status == "cannot_verify", check_id
    assert timeline.feasible  # nothing failed, and the unverifiable checks are listed
    assert len(timeline.unverified) >= 4


def test_scope_and_children_checks():
    outside = build([stop(in_region=False)], [(None, 1, 10, "supported")])
    assert check(outside, "geographic_scope").status == "failed" and not outside.feasible
    inside = build([stop(in_region=True)], [(None, 1, 10, "supported")])
    assert check(inside, "geographic_scope").status == "passed"

    young = build([stop(min_age=7)], [(None, 1, 10, "supported")], child_ages=[5, 12])
    assert check(young, "activity_suitability").status == "failed"
    unrecorded = build([stop()], [(None, 1, 10, "supported")], child_ages=[5])
    assert check(unrecorded, "activity_suitability").status == "cannot_verify"
    adults_only = build([stop()], [(None, 1, 10, "supported")])
    assert not any(c.id == "activity_suitability" for c in adults_only.checks)


def test_booking_notes_travel_with_the_visit():
    place = stop(booking_requirement="required", booking_note="Call two days ahead")
    timeline = build([place], [(None, 1, 10, "supported")])
    assert items(timeline, "visit")[0].booking == "Booking required. Call two days ahead"


def test_several_picks_are_never_dropped_or_reordered_whatever_conflicts():
    stops = [stop(1, "A", activity_minutes=300, operating_status="permanently_closed"),
             stop(2, "B", activity_minutes=300), stop(3, "C", activity_minutes=300)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 10, "supported"), (2, 3, 10, "supported")]
    timeline = build(stops, pairs, departure_time=time(8), day_count=1)
    assert [i.destination_id for i in items(timeline, "visit")] == [1, 2, 3]
    assert check(timeline, "selected_places").status == "passed"
    assert {c.code for c in timeline.conflicts} >= {"place_closed", "exceeds_day"}
