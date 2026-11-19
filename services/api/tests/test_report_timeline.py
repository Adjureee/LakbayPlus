"""The saved itinerary timeline in the trip report (summary and PDF)."""

from reportlab import rl_config

from tests.test_phase7_trips import (
    DESTINATION_A,
    DESTINATION_B,
    admin_headers,
    create_destination,
    create_trip,
    user_headers,
)
from tests.test_trip_timeline import _restore, _save, _state


def _trip_with_places(client, *, name_a="Report Stop A"):
    admin = admin_headers(client)
    a = create_destination(client, admin, {**DESTINATION_A, "name": name_a})["destination_id"]
    b = create_destination(client, admin, DESTINATION_B)["destination_id"]
    owner = user_headers(client, email="report-timeline-owner@example.com")
    return owner, create_trip(client, owner, [a, b])["trip_id"], a, b


def _pdf_text(client, owner, trip_id, monkeypatch) -> str:
    # Uncompressed streams, so the text the PDF draws can be searched.
    monkeypatch.setattr(rl_config, "pageCompression", 0)
    response = client.get(f"/api/v1/trips/{trip_id}/reports/pdf", headers=owner)
    assert response.status_code == 200 and response.content.startswith(b"%PDF")
    return response.content.decode("latin-1")


def test_a_trip_with_no_saved_timeline_keeps_the_plain_schedule(client, monkeypatch) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    summary = client.get(f"/api/v1/trips/{trip_id}/reports/summary", headers=owner).json()
    assert summary["timeline"] is None
    text = _pdf_text(client, owner, trip_id, monkeypatch)
    assert "Itinerary Schedule" in text and "Itinerary Timeline" not in text


def test_the_summary_carries_the_newest_saved_revision(client) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    _save(client, owner, trip_id, _state(a, b, departure_time="10:00:00"))
    summary = client.get(f"/api/v1/trips/{trip_id}/reports/summary", headers=owner).json()
    saved = summary["timeline"]
    assert saved["revision"] == 2 and saved["timeline"]["checks"]
    assert any("now starts at" in line for line in saved["changes"])
    visits = [i for d in saved["timeline"]["days"] for i in d["items"] if i["kind"] == "visit"]
    assert [v["destination_id"] for v in visits] == [a, b]


def test_the_pdf_replaces_the_plain_schedule_with_the_timeline(client, monkeypatch) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    text = _pdf_text(client, owner, trip_id, monkeypatch)

    # (PDF strings escape parentheses, so the heading is checked in two pieces.)
    assert "Itinerary Timeline" in text and "revision 1" in text
    assert "Itinerary Schedule" not in text
    # How far to trust each time, with the legend.
    assert "How to read the times" in text
    assert "Provisional: depends on a planning default" in text
    assert "Estimated" in text and "Confirmed" in text
    # The honest checks and costs.
    assert "Timeline Checks" in text
    assert "A check we cannot confirm is never counted as passed." in text
    assert "Can't verify" in text
    assert "Timeline Costs" in text
    assert "We cannot say yet whether it fits the budget." in text
    # Never invented for an incomplete budget (the expense section below has its own
    # "Remaining budget", so only the timeline's costs are looked at).
    costs = text.split("Timeline Costs")[1].split("Group Tasks")[0]
    assert "Remaining" not in costs
    assert "Built from Lakbay" in text  # the footer note on what is unconfirmed


def test_place_names_with_markup_and_the_peso_sign_do_not_break_the_pdf(
    client, monkeypatch,
) -> None:
    owner, trip_id, a, b = _trip_with_places(client, name_a="Cafe <b>Stop ₱ & Co")
    _save(client, owner, trip_id, _state(a, b))
    text = _pdf_text(client, owner, trip_id, monkeypatch)
    assert "Itinerary Timeline" in text
    assert "₱" not in text  # the peso sign is written as PHP


def test_a_member_can_read_the_timeline_report_but_an_outsider_cannot(client) -> None:
    from tests.invites import join_trip, login_headers

    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    user_headers(client, email="report-timeline-member@example.com")
    join_trip(client, headers=owner, trip_id=trip_id,
              email="report-timeline-member@example.com")
    member = login_headers(client, "report-timeline-member@example.com")
    url = f"/api/v1/trips/{trip_id}/reports/summary"
    assert client.get(url, headers=member).json()["timeline"]["revision"] == 1
    outsider = user_headers(client, email="report-timeline-outsider@example.com")
    assert client.get(url, headers=outsider).status_code == 404


# --- the revision log ----------------------------------------------------------------------


def test_the_summary_lists_every_saved_revision_oldest_first_with_who_and_what_moved(
    client,
) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    _save(client, owner, trip_id, _state(a, b, departure_time="10:00:00"))
    assert _restore(client, owner, trip_id, 1).status_code == 201
    log = client.get(f"/api/v1/trips/{trip_id}/reports/summary", headers=owner).json()[
        "revision_log"]
    assert [r["revision"] for r in log] == [1, 2, 3]
    assert log[0]["changes"] == [] and log[0]["saved_by"]
    assert any("now starts at" in c for c in log[1]["changes"])
    assert log[2]["changes"][0] == "Restored revision 1."  # a restore is a revision of its own
    assert all(isinstance(r["works"], bool) and r["unverified_count"] >= 0 for r in log)


def test_a_trip_with_no_timeline_has_an_empty_log(client) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    summary = client.get(f"/api/v1/trips/{trip_id}/reports/summary", headers=owner).json()
    assert summary["revision_log"] == []


def test_the_pdf_prints_the_revision_history_once_the_plan_was_revised(
    client, monkeypatch,
) -> None:
    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    # One version is already the timeline above: no history section yet.
    assert "Revision History" not in _pdf_text(client, owner, trip_id, monkeypatch)

    _save(client, owner, trip_id, _state(a, b, departure_time="10:00:00"))
    _restore(client, owner, trip_id, 1)
    text = _pdf_text(client, owner, trip_id, monkeypatch)
    assert "Revision History" in text
    assert "3 saved versions, oldest first" in text
    assert "Revision 1 - " in text and "Revision 2 - " in text and "Revision 3 - " in text
    assert text.index("Revision 1 - ") < text.index("Revision 2 - ") < text.index("Revision 3 - ")
    assert "- First version." in text
    assert "- Restored revision 1." in text
    assert "now starts at" in text  # what moved is in words


def test_a_long_list_of_changes_is_cut_with_a_count_not_dropped_silently(
    client, monkeypatch,
) -> None:
    from app.features.reports import pdf
    from app.features.reports.schemas import TripReportRevision

    owner, trip_id, a, b = _trip_with_places(client)
    _save(client, owner, trip_id, _state(a, b))
    _save(client, owner, trip_id, _state(a, b, departure_time="10:00:00"))
    summary = client.get(f"/api/v1/trips/{trip_id}/reports/summary", headers=owner).json()
    many = [f"Change number {n}." for n in range(1, 13)]
    summary["revision_log"][1]["changes"] = many
    from app.features.reports.schemas import TripReportSummaryResponse

    report = TripReportSummaryResponse.model_validate(summary)
    assert isinstance(report.revision_log[1], TripReportRevision)
    monkeypatch.setattr(rl_config, "pageCompression", 0)
    text = pdf.build_trip_report_pdf(report).decode("latin-1")
    assert "Change number 8." in text and "Change number 9." not in text
    assert "and 4 more." in text
