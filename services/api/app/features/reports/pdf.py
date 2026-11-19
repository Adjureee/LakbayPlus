from io import BytesIO
from html import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import CondPageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from app.features.destinations.hours import clock_text
from app.features.reports.schemas import TripReportSummaryResponse


def build_trip_report_pdf(report: TripReportSummaryResponse) -> bytes:
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        rightMargin=0.7 * inch,
        leftMargin=0.7 * inch,
        topMargin=0.6 * inch,
        bottomMargin=0.6 * inch,
    )
    styles = getSampleStyleSheet()
    story = [
        Paragraph(f"Lakbay Trip Report: {_pdf_text(report.trip.title)}", styles["Title"]),
        Paragraph(f"Generated at: {report.generated_at.isoformat()}", styles["Normal"]),
        Spacer(1, 12),
    ]

    _add_trip_overview(story, report, styles)
    _add_destinations(story, report, styles)
    if report.timeline is not None:
        _add_timeline(story, report, styles)
    else:
        _add_itinerary(story, report, styles)
    _add_tasks(story, report, styles)
    _add_route(story, report, styles)
    _add_expenses(story, report, styles)
    _add_members(story, report, styles)

    doc.build(story)
    return buffer.getvalue()


def _add_heading(story: list, text: str, styles) -> None:
    story.extend([Spacer(1, 10), Paragraph(text, styles["Heading2"]), Spacer(1, 4)])


def _add_trip_overview(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Trip Overview", styles)
    trip = report.trip
    data = [
        ["Status", trip.status],
        ["Dates", _date_range(trip.start_date, trip.end_date)],
        ["Traveler count", str(trip.traveler_count)],
        ["Total budget", _money(trip.total_budget)],
        ["Estimated total cost", _money(trip.estimated_total_cost)],
    ]

    if trip.description:
        data.append(["Description", trip.description])
    if trip.notes:
        data.append(["Notes", trip.notes])

    _add_key_value_table(story, data)


def _add_destinations(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Destinations", styles)

    if not report.destinations:
        story.append(Paragraph("No destinations were saved for this trip.", styles["Normal"]))
        return

    data = [["Order", "Destination"]]
    data.extend(
        [str(destination.stop_order), destination.name]
        for destination in report.destinations
    )
    _add_table(story, data)


def _add_itinerary(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Itinerary Schedule", styles)

    if not report.itinerary_days:
        story.append(Paragraph("No itinerary schedule was saved for this trip.", styles["Normal"]))
        return

    for day in report.itinerary_days:
        story.append(Paragraph(f"Day {day.day_number}: {_pdf_text(day.title)}", styles["Heading3"]))
        if day.summary:
            story.append(Paragraph(_pdf_text(day.summary), styles["Normal"]))

        if not day.activities:
            story.append(Paragraph("No activities listed.", styles["Normal"]))
            continue

        data = [["Order", "Time", "Activity", "Estimated Cost"]]
        data.extend(
            [
                str(activity.activity_order),
                activity.time or "",
                activity.title,
                _money(activity.estimated_cost),
            ]
            for activity in day.activities
        )
        _add_table(story, data)


def _add_route(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Route Summary", styles)

    if report.route is None:
        story.append(Paragraph("No saved route summary is available.", styles["Normal"]))
        return

    route = report.route
    data = [
        ["Travel mode", route.travel_mode],
        ["Provider", route.route_provider],
        ["Estimated", "Yes" if route.is_estimated else "No"],
        ["Total distance", f"{route.total_distance_km} km"],
        ["Total duration", f"{route.total_duration_minutes} minutes"],
    ]
    _add_key_value_table(story, data)

    if route.stops:
        stops = [["Order", "Stop"]]
        stops.extend([str(stop.order), stop.name] for stop in route.stops)
        _add_table(story, stops)


def _add_tasks(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Group Tasks", styles)
    if not report.tasks:
        story.append(Paragraph("No group tasks were saved for this trip.", styles["Normal"]))
        return

    data = [["Task", "Status", "Due Date"]]
    data.extend(
        [task.title, task.status.title(), task.due_date.isoformat() if task.due_date else ""]
        for task in report.tasks
    )
    _add_table(story, data)


def _add_expenses(story: list, report: TripReportSummaryResponse, styles) -> None:
    story.append(CondPageBreak(2 * inch))
    _add_heading(story, "Costs And Contributions", styles)
    expenses = report.expenses
    _add_key_value_table(
        story,
        [
            ["Total budget", _money(expenses.total_budget)],
            ["Total spent", _money(expenses.total_spent)],
            ["Remaining budget", _money(expenses.remaining_budget)],
            ["Over budget amount", _money(expenses.over_budget_amount)],
            ["Over budget", "Yes" if expenses.is_over_budget else "No"],
        ],
    )

    if expenses.category_breakdown:
        data = [["Category", "Total"]]
        data.extend(
            [item.category.title(), _money(item.total)]
            for item in expenses.category_breakdown
        )
        _add_table(story, data)

    if expenses.member_balances:
        balances = [["Member", "Paid", "Share", "Net"]]
        balances.extend(
            [
                balance.full_name,
                _money(balance.paid_total),
                _money(balance.share_total),
                _money(balance.net_balance),
            ]
            for balance in expenses.member_balances
        )
        _add_table(story, balances)


def _add_members(story: list, report: TripReportSummaryResponse, styles) -> None:
    _add_heading(story, "Trip Members", styles)
    data = [["Name", "Email", "Role", "Status"]]
    data.extend(
        [member.full_name, str(member.email), member.role, member.status]
        for member in report.members
    )
    _add_table(story, data)


def _add_key_value_table(story: list, data: list[list[str]]) -> None:
    _add_table(story, data, header=False)


def _add_table(story: list, data, *, header: bool = True) -> None:
    table = Table(data, hAlign="LEFT", repeatRows=1 if header else 0)
    table.setStyle(
        TableStyle(
            [
                ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
                ("BACKGROUND", (0, 0), (-1, 0), colors.whitesmoke if header else colors.white),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold" if header else "Helvetica"),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    story.extend([table, Spacer(1, 8)])


def _date_range(start_date, end_date) -> str:
    if start_date and end_date:
        return f"{start_date.isoformat()} to {end_date.isoformat()}"
    if start_date:
        return start_date.isoformat()
    if end_date:
        return f"Until {end_date.isoformat()}"
    return "Not set"


def _money(value) -> str:
    return f"PHP {value:.2f}"


def _pdf_text(value: str) -> str:
    return escape(value, quote=False)


# ---- the itinerary timeline -------------------------------------------------------------
# Everything here says how far to trust it: every time carries its label, a cost nobody
# knows prints as unknown (never free), a check that could not be confirmed prints as such,
# and an incomplete budget never prints a remaining amount. Helvetica has no peso sign, so
# amounts are written as "PHP", and text it cannot draw is replaced.

_BASIS_LABELS = {
    "confirmed": "Confirmed", "estimated": "Estimated",
    "provisional": "Provisional", "unknown": "Unknown",
}
_BASIS_MEANINGS = {
    "confirmed": "fixed by the traveler or by recorded opening hours",
    "estimated": "calculated from recorded or estimated durations and travel times",
    "provisional": "depends on a planning default or on a leg with no travel time",
    "unknown": "not known",
}
_CHECK_TITLES = {
    "chronological_order": "Order of the day", "selected_places": "Selected places",
    "travel_date": "Travel date", "geographic_scope": "Inside the Davao Region",
    "operating_status": "Open at all", "opening_hours": "Opening hours",
    "travel_times": "Travel times", "visit_durations": "Visit lengths",
    "return_deadline": "Return deadline", "activity_suitability": "Suitable for children",
    "budget_arithmetic": "Costs add up",
}
_CHECK_RESULTS = {"passed": "Passed", "failed": "Failed", "cannot_verify": "Can't verify"}


def _plain(value) -> str:
    """Text for a Paragraph: markup escaped and anything the PDF font cannot draw replaced."""
    text = str(value).replace("\u20b1", "PHP ").replace("\u2011", "-")
    text = text.encode("cp1252", "replace").decode("cp1252")
    return escape(text, quote=False)


def _php(value) -> str:
    return f"PHP {value:,.2f}"


def _clock(value) -> str:
    return clock_text(value) if value is not None else ""


def _length(minutes: int | None) -> str | None:
    if minutes is None:
        return None
    if minutes < 60:
        return f"{minutes} min"
    hours, rest = divmod(minutes, 60)
    return f"{hours} h" if rest == 0 else f"{hours} h {rest} min"


def _small(styles):
    from reportlab.lib.styles import ParagraphStyle

    return ParagraphStyle("TimelineSmall", parent=styles["Normal"], fontSize=8.5, leading=10.5)


def _add_timeline(story: list, report: TripReportSummaryResponse, styles) -> None:
    saved = report.timeline
    timeline = saved.timeline
    small = _small(styles)
    _add_heading(story, f"Itinerary Timeline (revision {saved.revision})", styles)
    story.append(Paragraph(
        _plain(
            f"Saved {saved.saved_at:%Y-%m-%d}. Built from Lakbay's records. Anything marked "
            "Estimated, Provisional or Unknown has not been confirmed: check opening hours, "
            "prices and travel times before you go."
        ), small))
    story.append(Spacer(1, 4))
    story.append(Paragraph(
        "<b>" + _plain(
            "Nothing we can check conflicts with the selected places." if timeline.feasible
            else "Some places do not fit yet: see the problems below."
        ) + "</b>", styles["Normal"]))
    if timeline.unverified:
        story.append(Paragraph(_plain(
            f"{len(timeline.unverified)} detail(s) could not be confirmed, so the times that "
            "depend on them are provisional."), small))
    for line in saved.changes:
        story.append(Paragraph(_plain(f"Revision note: {line}"), small))

    story.append(Spacer(1, 6))
    story.append(Paragraph("<b>How to read the times</b>", styles["Normal"]))
    for key, label in _BASIS_LABELS.items():
        story.append(Paragraph(_plain(f"{label}: {_BASIS_MEANINGS[key]}"), small))

    if timeline.conflicts:
        _add_heading(story, "Places That Do Not Fit", styles)
        for conflict in timeline.conflicts:
            story.append(Paragraph(_plain(f"- {conflict.message}"), styles["Normal"]))
        story.append(Paragraph(
            "Nothing has been removed. The traveler can choose which places to keep, change "
            "the time window, or change another limit.", small))

    pinned = {pin.destination_id: pin for pin in timeline.pins}
    for day in timeline.days:
        title = f"Day {day.day}" + (f" ({day.date})" if day.date else "")
        story.append(Paragraph(_plain(title), styles["Heading3"]))
        rows = [["Time", "What", "Trust", "Details"]]
        for item in day.items:
            when = _clock(item.starts_at)
            if item.ends_at is not None and item.ends_at != item.starts_at:
                when = f"{when} to {_clock(item.ends_at)}"
            what = item.label
            length = _length(item.duration_minutes)
            if length:
                what += f" ({length})"
            elif item.kind == "travel":
                what += " (travel time unknown)"
            if item.destination_id in pinned and item.kind == "visit":
                what += " [pinned]"
            details: list[str] = []
            if item.travel is not None:
                how = {"supported": "route-based", "estimated": "estimated from straight-line "
                       "distance"}.get(item.travel.basis, "no travel time available")
                details.append(
                    f"From {item.travel.from_label} to {item.travel.to_label}: "
                    f"{_length(item.travel.minutes) or 'unknown time'} ({how})")
            if item.booking:
                details.append(f"Booking: {item.booking}")
            for cost in item.costs:
                amount = "unknown" if cost.amount is None else _php(cost.amount) + (
                    " per person" if cost.scope == "per_person" else "")
                status = "" if cost.status == "known" else f" ({cost.status})"
                included = f", included in {cost.included_in}" if cost.included_in else ""
                details.append(f"Cost - {cost.label}: {amount}{status}{included}")
            details.extend(f"Note: {note}" for note in item.notes)
            rows.append([
                Paragraph(_plain(when or "time unknown"), small),
                Paragraph(_plain(what), small),
                Paragraph(_plain(_BASIS_LABELS.get(item.time_basis, item.time_basis)), small),
                Paragraph("<br/>".join(_plain(d) for d in details), small),
            ])
        table = Table(rows, colWidths=[0.95 * inch, 1.9 * inch, 0.8 * inch, 3.3 * inch],
                      hAlign="LEFT", repeatRows=1)
        table.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
            ("BACKGROUND", (0, 0), (-1, 0), colors.whitesmoke),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 4), ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ]))
        story.extend([table, Spacer(1, 8)])

    _add_heading(story, "Timeline Checks", styles)
    story.append(Paragraph("A check we cannot confirm is never counted as passed.", small))
    checks = [["Check", "Result", "Note"]]
    checks.extend(
        [
            Paragraph(_plain(_CHECK_TITLES.get(check.id, check.id)), small),
            Paragraph(_plain(_CHECK_RESULTS.get(check.status, check.status)), small),
            Paragraph(_plain(check.message), small),
        ]
        for check in timeline.checks
    )
    table = Table(checks, colWidths=[1.7 * inch, 1.0 * inch, 4.25 * inch], hAlign="LEFT",
                  repeatRows=1)
    table.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.25, colors.lightgrey),
        ("BACKGROUND", (0, 0), (-1, 0), colors.whitesmoke),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    story.extend([table, Spacer(1, 8)])

    _add_heading(story, "Timeline Costs", styles)
    budget = timeline.budget
    verdict = {
        "fits_known_costs": "Within the budget, with every cost known.",
        "over_budget": "The costs we know already pass the budget.",
    }.get(budget.fit, "We cannot say yet whether it fits the budget.")
    cost_rows = [
        ["Known", _php(budget.known_total)],
        ["Estimated", _php(budget.estimated_total)],
        ["Subtotal", _php(budget.subtotal)],
    ]
    if budget.total_budget is not None:
        cost_rows.append(["Budget", _php(budget.total_budget)])
    if budget.remaining is not None:
        cost_rows.append(["Remaining", _php(budget.remaining)])
    _add_key_value_table(story, cost_rows)
    story.append(Paragraph("<b>" + _plain(verdict) + "</b>", styles["Normal"]))
    for heading, entries in (
        ("Unknown costs (not in the subtotal):", budget.unknown),
        ("Estimates with no recorded basis (not used to judge the budget):", budget.unbased),
        ("To complete the estimate:", budget.to_complete),
    ):
        if entries:
            story.append(Paragraph(_plain(heading), small))
            story.extend(Paragraph(_plain(f"- {entry}"), small) for entry in entries)
    for note in budget.notes:
        story.append(Paragraph(_plain(note), small))
    if timeline.assumptions:
        story.append(Paragraph("<b>Planning defaults</b>", small))
        story.extend(Paragraph(_plain(f"- {text}"), small) for text in timeline.assumptions)
