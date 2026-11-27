"""Structured opening hours: reading, validation, the admin API and what the AI is told."""

from datetime import date, datetime, time, timezone
from types import SimpleNamespace as N

import pytest
from pydantic import ValidationError

from app.features.ai.rag import _destination_document
from app.features.destinations.data_quality import data_quality
from app.features.destinations.hours import hours_on, hours_summary, listed_opening
from app.features.destinations.schemas import DestinationHoursUpdate
from tests.test_ai_rag import destination as fake_place
from tests.test_phase5_ai_itineraries import admin_headers, create_destination, user_headers


def _row(day, opens=time(8), closes=time(17), closed=False):
    return N(weekday=day, is_closed=closed, opens_at=None if closed else opens,
             closes_at=None if closed else closes)


WEEK = [*[_row(d) for d in range(5)], _row(5, closes=time(12)), _row(6, closed=True)]


# --- reading ---------------------------------------------------------------------------


def test_summary_joins_days_that_share_hours():
    assert hours_summary(None, WEEK) == (
        "Mon to Fri 8:00 AM to 5:00 PM; Sat 8:00 AM to 12:00 PM; Sun closed"
    )


def test_summary_for_special_cases():
    assert hours_summary(True, []) == "Open 24 hours"
    assert hours_summary(None, []) is None  # unknown, never "closed"
    split = [_row(0, closes=time(12)), _row(0, opens=time(13), closes=time(17))]
    assert hours_summary(None, split) == "Mon 8:00 AM to 12:00 PM and 1:00 PM to 5:00 PM"


def test_an_exception_wins_over_the_weekly_schedule():
    wed = date(2026, 11, 18)
    holiday = N(starts_on=date(2026, 11, 18), ends_on=date(2026, 11, 19), is_closed=True,
                opens_at=None, closes_at=None, reason="Holiday")
    assert hours_on(wed, None, WEEK) == ("open", [(time(8), time(17))])
    assert hours_on(wed, None, WEEK, [holiday]) == ("closed", [])
    assert hours_on(date(2026, 11, 22), None, WEEK)[0] == "closed"  # a Sunday
    assert hours_on(wed, None, [])[0] == "unknown"
    assert hours_on(wed, True, [])[0] == "open_24_hours"


def test_data_quality_needs_structured_hours_and_a_recent_check():
    now = datetime(2026, 11, 18, tzinfo=timezone.utc)
    fresh = datetime(2026, 6, 1, tzinfo=timezone.utc)
    old = datetime(2025, 6, 1, tzinfo=timezone.utc)
    assert data_quality(True, False, fresh, now=now) == "supported"
    assert data_quality(True, False, old, now=now) == "estimated"
    assert data_quality(True, False, None, now=now) == "estimated"
    assert data_quality(False, True, fresh, now=now) == "estimated"  # text only
    assert data_quality(False, False, fresh, now=now) == "unknown"


# --- validation ------------------------------------------------------------------------


def _update(**fields):
    return DestinationHoursUpdate.model_validate(fields)


def test_windows_must_make_sense():
    with pytest.raises(ValidationError):
        _update(weekly=[{"weekday": 0, "opens_at": "17:00", "closes_at": "08:00"}])
    with pytest.raises(ValidationError):
        _update(weekly=[{"weekday": 0}])  # open day without times
    with pytest.raises(ValidationError):
        _update(weekly=[{"weekday": 0, "is_closed": True, "opens_at": "08:00"}])
    with pytest.raises(ValidationError):
        _update(weekly=[{"weekday": 7, "is_closed": True}])
    with pytest.raises(ValidationError):  # last admission after closing
        _update(weekly=[{"weekday": 0, "opens_at": "08:00", "closes_at": "17:00",
                         "last_admission_at": "18:00"}])


def test_a_day_cannot_overlap_itself_or_be_closed_and_open():
    with pytest.raises(ValidationError):
        _update(weekly=[
            {"weekday": 0, "opens_at": "08:00", "closes_at": "13:00"},
            {"weekday": 0, "opens_at": "12:00", "closes_at": "17:00"},
        ])
    with pytest.raises(ValidationError):
        _update(weekly=[
            {"weekday": 0, "is_closed": True},
            {"weekday": 0, "opens_at": "08:00", "closes_at": "17:00"},
        ])
    # A lunch break is fine.
    _update(weekly=[
        {"weekday": 0, "opens_at": "08:00", "closes_at": "12:00"},
        {"weekday": 0, "opens_at": "13:00", "closes_at": "17:00"},
    ])


def test_24_hours_excludes_a_weekly_schedule_and_exceptions_need_a_range():
    with pytest.raises(ValidationError):
        _update(open_24_hours=True, weekly=[{"weekday": 0, "is_closed": True}])
    with pytest.raises(ValidationError):
        _update(exceptions=[{"starts_on": "2026-12-25", "ends_on": "2026-12-24",
                             "is_closed": True}])
    with pytest.raises(ValidationError):
        _update(hours_source_url="not a url")


# --- the admin API ---------------------------------------------------------------------

PAYLOAD = {
    "hours_source_url": "https://example.com/park",
    "hours_verified_at": "2026-11-01T00:00:00+08:00",
    "weekly": [
        *({"weekday": d, "opens_at": "08:00:00", "closes_at": "17:00:00"} for d in range(5)),
        {"weekday": 5, "opens_at": "08:00:00", "closes_at": "12:00:00"},
        {"weekday": 6, "is_closed": True},
    ],
    "exceptions": [{"starts_on": "2026-12-25", "ends_on": "2026-12-25", "is_closed": True,
                    "reason": "Christmas"}],
}


def test_an_admin_saves_and_anyone_reads_the_hours(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/hours"

    empty = client.get(url)
    assert empty.status_code == 200
    assert empty.json()["summary"] is None and empty.json()["weekly"] == []

    saved = client.put(url, headers=admin, json=PAYLOAD)
    assert saved.status_code == 200, saved.text
    body = saved.json()
    assert body["summary"].startswith("Mon to Fri 8:00 AM to 5:00 PM")
    assert body["exceptions"][0]["reason"] == "Christmas"
    assert body["data_quality"] in {"supported", "estimated"}

    assert client.get(url).json()["summary"] == body["summary"]

    # A second save replaces everything: no leftovers from the first.
    again = client.put(url, headers=admin, json={"open_24_hours": True})
    assert again.status_code == 200
    assert again.json()["summary"] == "Open 24 hours"
    assert again.json()["weekly"] == [] and again.json()["exceptions"] == []


def test_only_an_admin_can_change_hours_and_bad_input_is_refused(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/hours"

    assert client.put(url, json=PAYLOAD).status_code in {401, 403}
    assert client.put(url, headers=user_headers(client), json=PAYLOAD).status_code == 403
    bad = {"weekly": [{"weekday": 0, "opens_at": "17:00:00", "closes_at": "08:00:00"}]}
    assert client.put(url, headers=admin, json=bad).status_code == 422
    assert client.get("/api/v1/destinations/999999/hours").status_code == 404
    assert client.put("/api/v1/destinations/999999/hours", headers=admin,
                      json=PAYLOAD).status_code == 404


# --- what the AI is told ---------------------------------------------------------------


def test_the_ai_record_carries_structured_hours_with_their_trust_level():
    place = fake_place(1, "Eden Nature Park", "Davao City")
    with_hours = _destination_document(place, weekly_hours=WEEK_ROWS())
    facts = with_hours.payload
    assert facts["opening_hours"].startswith("Mon to Fri 8:00 AM to 5:00 PM")
    assert facts["hours_data_quality"] == "estimated"  # no verified date yet
    assert "8:00 AM" in with_hours.text

    without = _destination_document(place).payload
    assert without.get("opening_hours") is None  # empty facts are left out
    assert without["hours_data_quality"] == "unknown"


def WEEK_ROWS():
    return [N(destination_id=1, **{k: getattr(r, k) for k in ("weekday", "is_closed",
             "opens_at", "closes_at")}) for r in WEEK]


# --- listed_opening: the opening time in free text, only when it is clear ---------------

@pytest.mark.parametrize(("text", "expected"), [
    ("10:00 AM - 5:00 PM", time(10, 0)),
    ("8:00 AM to 8:00 PM.", time(8, 0)),
    ("Daily, 7:00 AM–5:00 PM", time(7, 0)),
    ("Mo-Su 08:00-17:30", time(8, 0)),
    ("Day tour 10:00-18:00", time(10, 0)),
    ("05:00 AM - 10:00 PM daily", time(5, 0)),
    ("10:30 AM - 11:30 PM", time(10, 30)),
])
def test_a_clear_daily_window_gives_its_opening_time(text, expected) -> None:
    assert listed_opening(text) == expected


@pytest.mark.parametrize("text", [
    None, "", "24/7", "Daytime visits", "Open daily",
    "Mo-Sa 10:00-16:00, Su off", "Confirm current hours 9:00 AM - 5:00 PM",
    "2:00 PM - 12:00 PM.", "Open Dec 5-10", "8-5", "10:00 AM - 5:00",
    "Sat 8:00 AM - 12:00 PM; Mon to Fri 10:00 AM - 5:00 PM",
])
def test_unclear_text_gives_nothing(text) -> None:
    assert listed_opening(text) is None
