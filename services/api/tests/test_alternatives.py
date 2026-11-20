"""Alternatives for a place that does not work: pure functions on fixed data."""

from datetime import date, time
from types import SimpleNamespace as N

from app.features.planning.alternatives import PlaceProfile, find_alternatives
from app.features.planning.timeline import (
    HoursInfo,
    LegInfo,
    Lodging,
    StopInfo,
    TimelineInput,
    build_timeline,
)

THU = date(2026, 11, 19)  # weekday 3
KM = 1 / 111.0  # degrees of latitude per km


def weekly(*rows):
    return [N(weekday=d, opens_at=o, closes_at=c, is_closed=cl, last_admission_at=None)
            for d, o, c, cl in rows]


CLOSED_THU = weekly((3, None, None, True))
OPEN_THU = weekly((3, time(9), time(17), False))


def place(destination_id, name, km_north=0.0, *, hours=None, category="park", vibes="calm",
          activities="walking", status="open", min_age=None, **fields) -> PlaceProfile:
    stop = StopInfo(
        destination_id, name, operating_status=status, in_region=True,
        hours=HoursInfo(weekly=hours or []), typical_visit_min_minutes=60,
        typical_visit_max_minutes=60, min_age=min_age,
    )
    return PlaceProfile(
        stop, lat=7.0 + km_north * KM, lng=125.6, category=category, vibes=vibes,
        activities=activities, **fields)


def trip(profiles, **fields):
    stops = [p.stop for p in profiles]
    legs = {}
    previous = None
    for p in profiles:
        legs[(previous, p.stop.destination_id)] = LegInfo(15, "estimated")
        previous = p.stop.destination_id
    return TimelineInput(stops=stops, legs=legs, start_date=THU,
                         departure_time=time(9), **fields)


def run(profiles, pool, **kw):
    inp = trip(profiles, **kw.pop("inp", {}))
    by_id = {p.stop.destination_id: p for p in profiles}
    return find_alternatives(inp, by_id, pool, **kw)


def closed_place():
    return place(1, "Falls", 0.0, hours=CLOSED_THU)


# --- what is offered --------------------------------------------------------------------


def test_a_closed_place_gets_a_tested_alternative_open_that_day():
    sets = run([closed_place(), place(2, "Museum", 2.0, category="museum")],
               [place(10, "Garden", 3.0, hours=OPEN_THU)])
    assert [s.destination_id for s in sets] == [1]
    (option,) = sets[0].options
    assert option.destination_id == 10
    assert option.distance_km == 3.0
    assert option.reasons[0] == "Same kind of place"
    assert "3.0 km from Falls" in option.reasons
    assert "Open Thursday 9:00 AM to 5:00 PM" in option.reasons
    assert option.unverified == []
    visited = [i.destination_id for d in option.timeline.days for i in d.items
               if i.kind == "visit"]
    assert visited == [10, 2]  # same position, the other place untouched
    assert option.timeline.conflicts == []


def test_a_candidate_closed_that_day_or_recorded_closed_is_not_offered():
    sets = run([closed_place()], [
        place(10, "Shut Thursday", 1.0, hours=CLOSED_THU),
        place(11, "Closed for good", 1.0, hours=OPEN_THU, status="permanently_closed"),
        place(12, "Fine", 4.0, hours=OPEN_THU),
    ])
    assert [o.destination_id for o in sets[0].options] == [12]


def test_places_already_in_the_trip_are_never_offered():
    inside = place(2, "Museum", 1.0, hours=OPEN_THU)
    sets = run([closed_place(), inside], [inside])
    assert sets[0].options == []


def test_nothing_that_survives_gives_an_empty_list_not_a_guess():
    sets = run([closed_place()], [place(10, "Shut", 1.0, hours=CLOSED_THU)])
    assert sets[0].options == []
    assert sets[0].problems  # the place is still reported as a problem


def test_a_trip_with_no_problem_gets_nothing():
    ok = place(1, "Falls", 0.0, hours=OPEN_THU)
    assert run([ok], [place(10, "Garden", 1.0, hours=OPEN_THU)]) == []


# --- missing facts are not passes -------------------------------------------------------


def test_unknown_hours_are_offered_lower_and_named():
    sets = run([closed_place()], [
        place(10, "Unknown", 1.0),  # no hours recorded, nearer
        place(11, "Known", 4.0, hours=OPEN_THU),
    ])
    options = sets[0].options
    assert [o.destination_id for o in options] == [11, 10]
    assert "Opening hours are not confirmed." in options[1].unverified
    assert not any(r.startswith("Open ") for r in options[1].reasons)


def test_a_recorded_no_removes_a_candidate_but_a_missing_fact_only_names_the_gap():
    sets = run([closed_place()], [
        place(10, "Steps only", 1.0, hours=OPEN_THU, wheelchair_accessible=False),
        place(11, "Unrecorded", 2.0, hours=OPEN_THU),
        place(12, "Ramps", 3.0, hours=OPEN_THU, wheelchair_accessible=True),
    ], needs={"wheelchair"})
    options = {o.destination_id: o for o in sets[0].options}
    assert set(options) == {11, 12}
    assert "Wheelchair access is recorded" in options[12].reasons
    assert "Wheelchair access is not recorded" in options[11].unverified
    assert [o.destination_id for o in sets[0].options][0] == 12  # recorded access ranks first


# --- the swap is proven on the real itinerary -------------------------------------------


def test_a_candidate_that_breaks_the_return_deadline_is_rejected():
    # The second stop is long; a long candidate pushes the day past the deadline.
    long_stop = place(2, "Museum", 2.0)
    long_stop.stop.typical_visit_min_minutes = long_stop.stop.typical_visit_max_minutes = 120
    long_cand = place(10, "Long walk", 1.0, hours=OPEN_THU)
    long_cand.stop.typical_visit_min_minutes = long_cand.stop.typical_visit_max_minutes = 300
    short_cand = place(11, "Short walk", 2.0, hours=OPEN_THU)
    sets = run([closed_place(), long_stop], [long_cand, short_cand],
               inp={"return_deadline": time(15)})
    assert [o.destination_id for o in sets[0].options] == [11]


def test_a_swap_that_newly_fails_a_check_is_rejected():
    young = place(10, "Adults only", 1.0, hours=OPEN_THU, min_age=18)
    fine = place(11, "All ages", 2.0, hours=OPEN_THU)
    sets = run([closed_place()], [young, fine], inp={"child_ages": [6]})
    assert [o.destination_id for o in sets[0].options] == [11]


def test_the_failing_places_pin_is_dropped_with_it():
    from app.features.planning.timeline import Pin

    sets = run([closed_place()], [place(10, "Garden", 1.0, hours=OPEN_THU)],
               inp={"pins": [Pin(1, day=1)]})
    assert sets[0].options[0].timeline.pins == []


# --- how far, how many ------------------------------------------------------------------


def test_the_search_widens_once_when_few_survive_nearby():
    sets = run([closed_place()], [
        place(10, "Near", 5.0, hours=OPEN_THU),
        place(11, "Far", 20.0, hours=OPEN_THU),
        place(12, "Too far", 40.0, hours=OPEN_THU),
    ])
    assert sorted(o.destination_id for o in sets[0].options) == [10, 11]


def test_at_most_three_are_offered_and_the_wider_search_is_skipped_when_enough_are_near():
    pool = [place(10 + i, f"Near {i}", 1.0 + i, hours=OPEN_THU) for i in range(5)]
    pool.append(place(99, "Far", 25.0, hours=OPEN_THU))
    sets = run([closed_place()], pool)
    ids = [o.destination_id for o in sets[0].options]
    assert len(ids) == 3
    assert 99 not in ids


def test_a_closer_better_match_ranks_first():
    sets = run([closed_place()], [
        place(10, "Other kind", 1.0, hours=OPEN_THU, category="museum", vibes="busy",
              activities="shopping"),
        place(11, "Alike", 6.0, hours=OPEN_THU),
    ])
    assert [o.destination_id for o in sets[0].options] == [11, 10]


# --- what is never replaced -------------------------------------------------------------


def test_the_place_the_group_sleeps_at_is_never_replaced():
    inn = place(1, "Inn", 0.0, hours=CLOSED_THU)
    sets = run([inn], [place(10, "Garden", 1.0, hours=OPEN_THU)],
               inp={"lodging": Lodging(1, "The Inn"), "day_count": 2})
    assert sets == []


def test_the_original_itinerary_is_not_changed_by_the_search():
    inp = trip([closed_place(), place(2, "Museum", 2.0)])
    before = build_timeline(inp).model_dump()
    by_id = {s.destination_id: place(s.destination_id, s.name) for s in inp.stops}
    by_id[1] = closed_place()
    find_alternatives(inp, by_id, [place(10, "Garden", 1.0, hours=OPEN_THU)])
    assert [s.destination_id for s in inp.stops] == [1, 2]
    assert build_timeline(inp).model_dump() == before
