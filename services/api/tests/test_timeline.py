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
    Lodging,
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
    assert items(stated, "depart")[0].time_basis == "confirmed"
    assert hhmm(items(stated, "travel")[0].starts_at) == "09:00"
    # The leg's own duration is an estimate, so the leg is never labelled confirmed.
    assert items(stated, "travel")[0].time_basis == "estimated"

    default = build([stop()], [(None, 1, 30, "supported")])
    assert hhmm(items(default, "travel")[0].starts_at) == "08:00"
    assert items(default, "depart")[0].time_basis == "provisional"
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


# --- presentation fixes found in the live check -----------------------------------------


def test_a_leg_with_no_travel_time_is_provisional_even_after_a_stated_departure():
    timeline = build([stop()], [], departure_time=time(8))  # no leg at all
    leg = items(timeline, "travel")[0]
    assert leg.time_basis == "provisional" and leg.duration_minutes is None


def test_a_visit_cannot_end_before_it_starts_when_it_runs_past_midnight():
    """Live case: a full-day default visit showed 16:53 to 00:53."""
    timeline = build([stop(activity_minutes=480)], [(None, 1, 60, "supported")],
                     departure_time=time(16))
    visit = items(timeline, "visit")[0]
    assert hhmm(visit.starts_at) == "17:00" and hhmm(visit.ends_at) == "23:59"
    assert visit.duration_minutes == 480
    assert any("past midnight" in n for n in visit.notes)
    assert [c.code for c in timeline.conflicts] == ["exceeds_day"]
    assert check(timeline, "chronological_order").status == "passed"


def test_an_estimate_with_no_recorded_basis_never_decides_the_budget_verdict():
    """Live case: two catalog estimates of unknown basis were called over budget."""
    place = stop(costs=[CostInfo("Catalog estimate", Decimal("3000"), "estimated",
                                 scope="per_person", basis_recorded=False)])
    timeline = build([place], [(None, 1, 10, "supported")], traveler_count=2,
                     total_budget=Decimal("5000"), include_meals=False)
    budget = timeline.budget
    assert budget.estimated_total == Decimal("6000") and budget.fit == "undetermined"
    assert budget.remaining is None
    assert len(budget.unbased) == 1 and "about ₱6,000" in budget.unbased[0]
    assert any("not used to decide" in n for n in budget.notes)


def test_known_costs_still_decide_over_budget_and_a_recorded_basis_estimate_counts():
    over = build([stop(costs=[CostInfo("Entrance", Decimal("900"), "known"),
                              CostInfo("Catalog estimate", Decimal("3000"), "estimated",
                                       basis_recorded=False)])],
                 [(None, 1, 10, "supported")], total_budget=Decimal("500"),
                 include_meals=False)
    assert over.budget.fit == "over_budget"
    based = build([stop(costs=[CostInfo("Parking", Decimal("900"), "estimated")])],
                  [(None, 1, 10, "supported")], total_budget=Decimal("500"),
                  include_meals=False)
    assert based.budget.fit == "over_budget" and not based.budget.unbased


def test_prompts_to_complete_the_estimate_are_kept_apart_from_costs():
    timeline = build([stop()], [(None, 1, 10, "supported")], include_meals=False,
                     budget_prompts=["Provide night_count before completing the estimate."])
    assert timeline.budget.to_complete == ["Provide night_count before completing the estimate."]
    assert timeline.budget.unknown == ["Entrance fee (Eden)"] or timeline.budget.unknown == []


def test_no_lunch_is_added_to_an_afternoon_start():
    timeline = build([stop(activity_minutes=60)], [(None, 1, 30, "supported")],
                     departure_time=time(16))
    assert items(timeline, "meal") == []


# --- pins are echoed so a saved or restored revision keeps them --------------------------


def test_the_timeline_echoes_the_pins_in_effect_and_drops_the_rest():
    stops = [stop(1, "A", activity_minutes=60), stop(2, "B", activity_minutes=60)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 10, "supported")]
    timeline = build(
        stops, pairs, day_count=2, departure_time=time(8),
        pins=[Pin(2, day=2, starts_at=time(10)), Pin(99, day=1), Pin(1)],  # 99 is not a pick
    )
    assert [(p.destination_id, p.day, p.starts_at) for p in timeline.pins] == [
        (2, 2, time(10))]  # a pin on a place not in the trip, or with nothing pinned, is dropped
    assert build(stops, pairs).pins == []


def test_a_pin_past_the_last_day_is_placed_on_the_last_day_and_says_so():
    timeline = build([stop(1, "A", activity_minutes=60)], [(None, 1, 10, "supported")],
                     day_count=2, departure_time=time(8), pins=[Pin(1, day=5)])
    visit = items(timeline, "visit", day=2)[0]
    assert any("Pinned to day 5, but the trip has 2" in n for n in visit.notes)


def test_a_pin_that_travel_pushes_past_says_travel_not_earlier_stops():
    """Live case: day 2 starts at 8:00 and the leg takes 2 h 17 min, so a 10:00 pin slips."""
    stops = [stop(1, "A", activity_minutes=60), stop(2, "B", activity_minutes=60)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 137, "supported")]
    timeline = build(stops, pairs, day_count=2, departure_time=time(8),
                     include_meals=False, pins=[Pin(2, day=2, starts_at=time(10))])
    visit = items(timeline, "visit", day=2)[0]
    assert hhmm(visit.starts_at) == "10:17"
    note = next(n for n in visit.notes if "could not be kept" in n)
    assert "the travel from A arrives after it" in note
    assert "earlier stops" not in note


def test_a_pin_that_earlier_stops_push_past_still_says_so():
    stops = [stop(1, "A", activity_minutes=300), stop(2, "B", activity_minutes=60)]
    pairs = [(None, 1, 10, "supported"), (1, 2, 10, "supported")]
    timeline = build(stops, pairs, departure_time=time(8), include_meals=False,
                     pins=[Pin(2, starts_at=time(10))])
    note = next(n for n in items(timeline, "visit")[1].notes if "could not be kept" in n)
    assert "the earlier stops run past it" in note


# --- nights ------------------------------------------------------------------------------


def overnight_trip(lodging=None, lodging_note=None, leg_pairs=None, order=(1, 2), pin=(2, 2)):
    """Two or three days: the picks in `order`, the pin sending one to day 2, no meals."""
    places = {1: stop(1, "A", activity_minutes=60), 2: stop(2, "B", activity_minutes=60),
              3: stop(3, "C", activity_minutes=60)}
    pairs = leg_pairs or [(None, 1, 10, "supported"), (1, 2, 30, "supported"),
                          (2, 1, 20, "estimated"), (None, 2, 10, "supported")]
    return build([places[i] for i in order], pairs, day_count=2, departure_time=time(8),
                 include_meals=False, lodging=lodging, lodging_note=lodging_note,
                 pins=[Pin(pin[0], day=pin[1])])


def test_without_a_chosen_stay_the_night_says_so_and_day_two_starts_from_the_last_place():
    timeline = overnight_trip()
    night = items(timeline, "overnight")[0]
    assert night.label == "Overnight (place to stay not chosen)"
    assert any("measured from A, where this day ended" in n for n in night.notes)
    leg = items(timeline, "travel", day=2)[0].travel
    assert (leg.from_label, leg.to_label, leg.minutes) == ("A", "B", 30)
    stay = check(timeline, "overnight_stay")
    assert stay.status == "cannot_verify" and "not chosen" in stay.message
    assert any("not chosen" in line for line in timeline.unverified)


def test_a_stay_at_the_last_place_adds_the_night_and_day_two_starts_from_the_stay():
    timeline = overnight_trip(Lodging(1, "Villa A"))
    day_one = items(timeline)
    assert [i.kind for i in day_one][-2:] == ["visit", "overnight"]  # already there: no trip
    assert day_one[-1].label == "Overnight at Villa A"
    leg = items(timeline, "travel", day=2)[0].travel
    assert (leg.from_label, leg.to_label) == ("Villa A", "B")
    assert hhmm(items(timeline, "visit", day=2)[0].starts_at) == "08:30"
    assert check(timeline, "overnight_stay").status == "passed"


def test_a_stay_away_from_the_last_place_adds_the_evening_trip_there():
    # Day one ends at B (leg to the stay A: 20 minutes), the stay is at A.
    timeline = overnight_trip(
        Lodging(1, "Villa A"), order=(1, 2, 3), pin=(3, 2),
        leg_pairs=[(None, 1, 10, "supported"), (1, 2, 20, "supported"),
                   (2, 1, 20, "estimated"), (1, 3, 40, "estimated")])
    day_one = items(timeline)
    assert [i.kind for i in day_one][-3:] == ["visit", "travel", "overnight"]
    evening = day_one[-2]
    assert evening.label == "Travel to Villa A" and evening.duration_minutes == 20
    assert hhmm(day_one[-1].starts_at) == "11:05"
    morning = items(timeline, "travel", day=2)[0].travel
    assert (morning.from_label, morning.to_label, morning.minutes) == ("Villa A", "C", 40)
    assert hhmm(items(timeline, "visit", day=2)[0].starts_at) == "08:40"


def test_an_evening_trip_with_no_travel_time_stays_unknown_and_provisional():
    timeline = overnight_trip(
        Lodging(1, "Villa A"), order=(1, 2, 3), pin=(3, 2),
        leg_pairs=[(None, 1, 10, "supported"), (1, 2, 20, "supported"),
                   (1, 3, 40, "estimated")])  # no leg from B back to the stay
    evening = items(timeline, "travel")[-1]
    assert evening.label == "Travel to Villa A" and evening.duration_minutes is None
    assert evening.time_basis == "provisional"


def test_a_stay_at_the_first_place_of_day_two_needs_no_morning_trip():
    # Day one ends at B; the stay is at A, which is also the first visit of day two.
    timeline = overnight_trip(Lodging(1, "Villa A"), order=(2, 1), pin=(1, 2))
    morning = items(timeline, day=2)
    assert [i.kind for i in morning] == ["visit"]  # the group is already there
    assert morning[0].destination_id == 1 and hhmm(morning[0].starts_at) == "08:00"


def test_an_unclear_stay_is_not_guessed_and_the_reason_is_shown():
    timeline = overnight_trip(lodging_note="More than one stay is chosen.")
    night = items(timeline, "overnight")[0]
    assert night.label == "Overnight (place to stay not chosen)"
    assert "More than one stay is chosen." in night.notes
    assert check(timeline, "overnight_stay").message.startswith("More than one stay is chosen.")


def test_a_pin_that_skips_a_day_still_gives_every_night():
    timeline = build([stop(1, "A", activity_minutes=60)], [(None, 1, 10, "supported")],
                     day_count=3, departure_time=time(8), include_meals=False,
                     lodging=Lodging(1, "Villa A"), pins=[Pin(1, day=3)])
    assert [i.kind for i in items(timeline, day=1)] == ["depart", "overnight"]
    assert [i.kind for i in items(timeline, day=2)] == ["overnight"]
    assert [i.kind for i in items(timeline, day=3)][-1] == "visit"


def test_a_day_trip_has_no_night_and_no_stay_check():
    timeline = build([stop()], [(None, 1, 30, "supported")], departure_time=time(8))
    assert items(timeline, "overnight") == []
    assert not any(c.id == "overnight_stay" for c in timeline.checks)
