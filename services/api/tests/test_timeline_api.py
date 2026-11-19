"""POST /planning/timeline: the adapter from trip state and catalog to the timeline engine."""

from datetime import datetime, time, timezone
from decimal import Decimal
from types import SimpleNamespace as N

from app.features.planning.schemas import PlanningState
from app.features.planning.timeline import CostInfo, build_timeline, TimelineInput, StopInfo
from app.features.planning.timeline_service import describe_changes, stop_costs
from tests.test_phase5_ai_itineraries import admin_headers, create_destination

URL = "/api/v1/planning/timeline"


def price(audience="adult", amount="100", unit="per_person", age_min=None, age_max=None,
          item="entrance"):
    return N(item=item, audience=audience, amount=Decimal(amount), unit=unit,
             age_min=age_min, age_max=age_max)


def place(verified=True, estimated_cost=None, entrance_fee=None):
    return N(fees_verified_at=datetime(2026, 11, 1, tzinfo=timezone.utc) if verified else None,
             estimated_cost=estimated_cost, entrance_fee=entrance_fee)


def state(**fields):
    return PlanningState.model_validate(fields)


# --- prices become costs for the group --------------------------------------------------


def test_entrance_is_priced_for_adults_and_children_by_their_band():
    prices = [price(), price("child", "50", age_min=4, age_max=12)]
    costs = stop_costs(place(), prices,
                       state(traveler_count=4, adult_count=2, child_ages=[5, 9]))
    # One line for the adults and one per child age, each from its own band.
    assert [(c.amount, c.status) for c in costs] == [
        (Decimal("200"), "known"), (Decimal("50"), "known"), (Decimal("50"), "known")]
    assert "2 adult(s)" in costs[0].label and "aged 5" in costs[1].label


def test_an_unverified_price_is_an_estimate_and_a_group_price_is_charged_once():
    costs = stop_costs(place(verified=False), [price("everyone", "500", "per_group")],
                       state(traveler_count=4))
    assert costs[0].amount == Decimal("500") and costs[0].status == "estimated"


def test_a_child_with_no_matching_price_is_unknown_not_free():
    costs = stop_costs(place(), [price()],
                       state(traveler_count=2, adult_count=1, child_ages=[6]))
    assert costs[1].amount is None and costs[1].status == "unknown"
    assert "aged 6" in costs[1].label


def test_without_structured_prices_the_catalog_estimate_or_unknown_is_used():
    est = stop_costs(place(estimated_cost=Decimal("250")), [], state(traveler_count=2))
    assert est[0].amount == Decimal("250") and est[0].scope == "per_person"
    assert est[0].status == "estimated"
    text_only = stop_costs(place(entrance_fee="PHP 150 per person"), [], state(traveler_count=2))
    assert text_only[0].amount is None and "listed only as text" in text_only[0].label
    nothing = stop_costs(place(), [], state(traveler_count=2))
    assert nothing[0].amount is None and nothing[0].status == "unknown"


def test_no_group_size_means_the_entrance_cost_is_unknown():
    costs = stop_costs(place(), [price()], state())
    assert costs[0].amount is None and "group size" in costs[0].label


# --- what changed -----------------------------------------------------------------------


def _timeline(departure, *, days=1):
    stops = [StopInfo(1, "Eden", activity_minutes=60), StopInfo(2, "Museo", activity_minutes=60)]
    from app.features.planning.timeline import LegInfo
    legs = {(None, 1): LegInfo(30, "supported"), (1, 2): LegInfo(20, "supported")}
    return build_timeline(TimelineInput(stops=stops, legs=legs, departure_time=departure,
                                        day_count=days, include_meals=False))


def test_a_revision_lists_what_moved_in_plain_words():
    earlier, later = _timeline(time(8)), _timeline(time(9))
    assert describe_changes(earlier, later) == [
        "Eden now starts at 9:30 AM, not 8:30 AM.",
        "Museo now starts at 11:05 AM, not 10:05 AM.",
    ]
    assert describe_changes(earlier, earlier) == []


def test_added_removed_and_day_moves_are_described():
    one = _timeline(time(8))
    only_eden = build_timeline(TimelineInput(
        stops=[StopInfo(1, "Eden", activity_minutes=60)],
        legs={}, departure_time=time(8), include_meals=False))
    assert "Museo was removed." in describe_changes(one, only_eden)
    assert any("Museo was added" in c for c in describe_changes(only_eden, one))


# --- the endpoint -----------------------------------------------------------------------


def _places(client):
    admin = admin_headers(client)
    first = create_destination(
        client, headers=admin, name="Eden Nature Park", lat=7.15, lng=125.4,
        typical_visit_min_minutes=120, typical_visit_max_minutes=120)
    second = create_destination(
        client, headers=admin, name="Museo Davao", lat=7.07, lng=125.61,
        stay_duration_type="short")
    return admin, first["destination_id"], second["destination_id"]


def _items(body, kind=None, day=1):
    return [i for i in body["timeline"]["days"][day - 1]["items"]
            if kind is None or i["kind"] == kind]


def test_a_timeline_is_built_for_a_guest_and_keeps_the_picks_in_order(client) -> None:
    _, eden, museo = _places(client)
    response = client.post(URL, json={"state": {
        "destination_ids": [eden, museo], "traveler_count": 2, "day_count": 1,
        "departure_time": "08:00:00", "origin": {"label": "Davao City", "lat": 7.07, "lng": 125.6},
        "return_to_origin": True,
    }})
    assert response.status_code == 200, response.text
    body = response.json()
    visits = _items(body, "visit")
    assert [v["destination_id"] for v in visits] == [eden, museo]
    assert visits[0]["duration_basis"] == "recorded" and visits[0]["duration_minutes"] == 120
    # No route was requested, so legs are straight-line estimates and say so.
    travel = _items(body, "travel")
    assert travel and all(t["travel"]["basis"] == "estimated" for t in travel)
    checks = {c["id"]: c["status"] for c in body["timeline"]["checks"]}
    assert checks["selected_places"] == "passed"
    assert checks["travel_times"] == "cannot_verify"  # estimates are not route-based
    assert checks["opening_hours"] == "cannot_verify"
    assert body["route_status"] == "not_requested"
    assert body["changes"] == []


def test_a_place_that_is_no_longer_active_is_reported_not_dropped(client) -> None:
    _, eden, _ = _places(client)
    response = client.post(URL, json={"state": {"destination_ids": [eden, 999999]}})
    body = response.json()
    assert body["unavailable_destination_ids"] == [999999]
    assert body["timeline"]["feasible"] is False
    check = next(c for c in body["timeline"]["checks"] if c["id"] == "selected_places")
    assert check["status"] == "failed" and check["destination_ids"] == [999999]


def test_recorded_hours_decide_where_a_visit_starts(client) -> None:
    admin, eden, _ = _places(client)
    saved = client.put(f"/api/v1/destinations/{eden}/hours", headers=admin, json={
        "weekly": [{"weekday": d, "opens_at": "09:00:00", "closes_at": "17:00:00"}
                   for d in range(7)],
        "hours_verified_at": "2026-11-01T00:00:00+08:00",
    })
    assert saved.status_code == 200, saved.text
    body = client.post(URL, json={"state": {
        "destination_ids": [eden], "travel_start_date": "2026-11-20",
        "departure_time": "07:00:00",
        "origin": {"label": "Davao City", "lat": 7.15, "lng": 125.4},
    }}).json()
    visit = _items(body, "visit")[0]
    assert visit["starts_at"] == "09:00:00" and visit["time_basis"] == "confirmed"
    checks = {c["id"]: c["status"] for c in body["timeline"]["checks"]}
    assert checks["opening_hours"] == "passed" and checks["travel_date"] == "passed"


def test_recorded_prices_become_costs_and_the_budget_says_what_is_unknown(client) -> None:
    admin, eden, museo = _places(client)
    client.put(f"/api/v1/destinations/{eden}/prices", headers=admin, json={
        "prices": [{"item": "entrance", "audience": "adult", "amount": "100",
                    "unit": "per_person"}],
        "fees_verified_at": "2026-11-01T00:00:00+08:00"})
    client.patch(f"/api/v1/destinations/{museo}", headers=admin, json={"estimated_cost": None})
    body = client.post(URL, json={"state": {
        "destination_ids": [eden, museo], "traveler_count": 2, "adult_count": 2,
        "total_budget": "5000",
        "origin": {"label": "Davao City", "lat": 7.07, "lng": 125.6},
    }}).json()
    budget = body["timeline"]["budget"]
    assert Decimal(budget["known_total"]) == Decimal("200")
    assert not budget["complete"] and budget["remaining"] is None
    assert any("Entrance fee" in u for u in budget["unknown"])  # Museo has no price
    assert budget["fit"] == "undetermined"


def test_a_revision_returns_what_changed_and_honours_pins(client) -> None:
    _, eden, museo = _places(client)
    base = {"destination_ids": [eden, museo], "day_count": 2, "departure_time": "08:00:00",
            "origin": {"label": "Davao City", "lat": 7.07, "lng": 125.6}}
    first = client.post(URL, json={"state": base}).json()
    revised = client.post(URL, json={
        "state": base, "previous": first["timeline"],
        "pins": [{"destination_id": museo, "day": 2, "starts_at": "10:00:00"}],
    }).json()
    museo_visit = _items(revised, "visit", day=2)[0]
    assert museo_visit["destination_id"] == museo and museo_visit["starts_at"] == "10:00:00"
    assert any("Museo Davao moved from day 1 to day 2" in c for c in revised["changes"])


def test_bad_input_is_refused(client) -> None:
    assert client.post(URL, json={"state": {"day_count": 0}}).status_code == 422
    assert client.post(URL, json={"pins": [{"destination_id": 1, "day": 99}]}).status_code == 422


# --- legs from a route result or straight-line estimates ---------------------------------


def _preview(legs=None):
    if legs is None:
        return N(route=N(status="not_requested", summary=None))
    summary = N(legs=legs, travel_mode="driving", arrival_points_verified=True)
    return N(route=N(status="calculated", summary=summary))


def _dest(destination_id, lat, lng, island=None):
    return N(destination_id=destination_id, lat=lat, lng=lng, island_group=island)


def test_route_legs_are_used_when_a_route_was_calculated():
    from app.features.planning.timeline_service import _legs

    legs = _legs(
        _preview([
            N(from_destination_id=None, to_destination_id=1, duration_minutes=30, is_estimated=False),
            N(from_destination_id=1, to_destination_id=None, duration_minutes=45, is_estimated=True),
        ]),
        [_dest(1, 7.2, 125.5)],
        state(origin={"label": "Davao City", "lat": 7.07, "lng": 125.6}, return_to_origin=True),
    )
    assert (legs[(None, 1)].minutes, legs[(None, 1)].basis) == (30, "supported")
    assert (legs[(1, None)].minutes, legs[(1, None)].basis) == (45, "estimated")
    assert legs[(None, 1)].route_verified is True


def test_without_a_route_legs_are_straight_line_estimates_except_for_islands():
    from app.features.planning.timeline_service import _legs

    origin = {"label": "Davao City", "lat": 7.07, "lng": 125.6}
    legs = _legs(_preview(), [_dest(1, 7.2, 125.5), _dest(2, 7.3, 125.7)],
                 state(origin=origin, return_to_origin=True))
    assert set(legs) == {(None, 1), (1, 2), (2, None)}
    assert all(leg.basis == "estimated" and leg.minutes > 0 for leg in legs.values())
    # A place on an island is reached by boat: no road-speed estimate is invented for it.
    island = _legs(_preview(), [_dest(1, 7.2, 125.5, island="samal")], state(origin=origin))
    assert island == {}
    # No coordinates, no estimate.
    assert _legs(_preview(), [_dest(1, 7.2, 125.5)], state()) == {}


# --- missing costs from the preview: costs become unknown lines, requests become prompts ---


def _missing(code, message="m", reference="x"):
    return N(code=code, message=message, reference_id=reference)


def test_preview_missing_costs_become_named_unknowns_or_prompts_not_instructions():
    from app.features.planning.timeline_service import _trip_costs

    preview = N(budget=N(lines=[], missing_costs=[
        _missing("trip_details_missing", "Provide night_count before completing the estimate."),
        _missing("trip_details_missing", "Provide night_count before completing the estimate."),
        _missing("transport_selection_missing"),
        _missing("transport_return_missing"),
        _missing("food_allowance_missing"),
        _missing("fuel_estimate_missing"),
        _missing("child_price_rule_missing"),
        _missing("destination_allowance_missing", reference="destination:5"),
    ]))
    costs, covered, prompts = _trip_costs(preview)
    assert [c.label for c in costs] == [
        "Transport (cost not set)", "Food (no allowance set)",
        "Fuel and vehicle expenses (not set)"]  # one line per kind, none an instruction
    assert all(c.amount is None and c.status == "unknown" for c in costs)
    assert prompts == ["Provide night_count before completing the estimate."]
    assert covered is None


def test_the_response_carries_the_pins_that_were_in_effect(client) -> None:
    _, eden, museo = _places(client)
    body = client.post(URL, json={
        "state": {"destination_ids": [eden, museo], "day_count": 2,
                  "departure_time": "08:00:00",
                  "origin": {"label": "Davao City", "lat": 7.07, "lng": 125.6}},
        "pins": [{"destination_id": museo, "day": 2, "starts_at": "10:00:00"}],
    }).json()
    assert body["timeline"]["pins"] == [
        {"destination_id": museo, "day": 2, "starts_at": "10:00:00"}]
