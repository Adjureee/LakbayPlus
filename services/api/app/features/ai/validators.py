import json
import math
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from pydantic import ValidationError

from app.features.ai.schemas import AIItineraryOption
from app.features.routes.sea_planner import PlannerPoint, haversine_km


class AIOutputValidationError(Exception):
    def __init__(self, message: str, *, details: list[str] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or []


class AIOutputInvalidJsonError(AIOutputValidationError):
    """Raised when the model output could not be parsed as valid structured JSON."""


@dataclass(frozen=True)
class AIItineraryCatalog:
    destination_ids: set[int]
    accommodation_ids: set[int]
    transportation_ids: set[int]
    total_budget: Decimal
    day_count: int
    minimum_option_count: int
    required_destination_ids: set[int] | None = None
    required_accommodation_ids: set[int] | None = None
    required_transportation_ids: set[int] | None = None
    accommodation_destination_ids: dict[int, int] | None = None
    transportation_destination_ids: dict[int, int] | None = None
    route_destination_order: tuple[int, ...] | None = None
    destination_coords: dict[int, tuple[float, float]] | None = None
    destination_island_groups: dict[int, str] | None = None
    max_same_day_jump_km: float = 140.0


def parse_and_validate_itinerary_output(
    *,
    content: str,
    catalog: AIItineraryCatalog,
) -> list[AIItineraryOption]:
    payload = _parse_json_payload(content)
    raw_options = payload.get("options")

    if not isinstance(raw_options, list):
        raise AIOutputInvalidJsonError("AI output must contain an options list.")

    if len(raw_options) < catalog.minimum_option_count:
        raise AIOutputValidationError(
            "AI output did not include enough itinerary options.",
            details=[
                f"Expected at least {catalog.minimum_option_count} options.",
                f"Received {len(raw_options)} options.",
            ],
        )

    options: list[AIItineraryOption] = []
    errors: list[str] = []

    for index, raw_option in enumerate(raw_options, start=1):
        try:
            option = AIItineraryOption.model_validate(raw_option)
            _validate_option(option=option, catalog=catalog)
        except (ValidationError, AIOutputValidationError) as exc:
            errors.append(f"Option {index}: {exc}")
            continue

        options.append(option)

    if errors:
        raise AIOutputValidationError(
            "AI output failed itinerary validation.",
            details=errors,
        )

    if len(options) < catalog.minimum_option_count:
        raise AIOutputValidationError(
            "AI output did not include enough valid itinerary options.",
            details=[f"Valid options: {len(options)}"],
        )

    if len({option.option_number for option in options}) != len(options):
        raise AIOutputValidationError("Itinerary option numbers must be unique.")

    return options


def _parse_json_payload(content: str) -> dict[str, Any]:
    cleaned = _unwrap_markdown_json(content.strip())

    start = cleaned.find("{")
    if start == -1:
        raise AIOutputInvalidJsonError("AI output was not valid JSON.")

    end = cleaned.rfind("}")
    if end > start:
        try:
            payload = json.loads(cleaned[start : end + 1])
            if not isinstance(payload, dict):
                raise AIOutputInvalidJsonError("AI output root must be a JSON object.")
            return payload
        except json.JSONDecodeError:
            pass

    repaired = _repair_truncated_json(cleaned[start:])
    if repaired is not None:
        return repaired

    raise AIOutputInvalidJsonError("AI output was not valid JSON.")


def _unwrap_markdown_json(value: str) -> str:
    if value.startswith("```"):
        return _strip_code_fence(value)
    fence_start = value.find("```")
    if fence_start != -1:
        inner = _strip_code_fence(value[fence_start:])
        if "{" in inner:
            return inner
    return value


def _repair_truncated_json(snippet: str) -> dict[str, Any] | None:
    """Close truncated strings, trim incomplete trailing tokens, and close open brackets."""
    in_string = False
    escaped = False
    stack: list[str] = []
    last_complete_comma = -1
    last_complete_stack: list[str] = []

    for idx, ch in enumerate(snippet):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_string:
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            stack.append("}")
        elif ch == "[":
            stack.append("]")
        elif ch in ("}", "]"):
            if not stack or stack[-1] != ch:
                return None
            stack.pop()
            if not stack:
                break
        elif ch == ",":
            last_complete_comma = idx
            last_complete_stack = list(stack)

    candidates: list[tuple[str, list[str]]] = []
    base = snippet.rstrip()
    if in_string:
        if escaped:
            base = base[:-1]
        candidates.append((base + '"', list(stack)))
    else:
        trimmed = base.rstrip(",")
        if trimmed.endswith(":"):
            trimmed += "null"
        candidates.append((trimmed, list(stack)))

    if last_complete_comma != -1:
        candidates.append((snippet[:last_complete_comma], last_complete_stack))

    for prefix, open_closers in candidates:
        candidate = prefix.rstrip().rstrip(",") + "".join(reversed(open_closers))
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def _strip_code_fence(value: str) -> str:
    lines = value.splitlines()

    if lines and lines[0].startswith("```"):
        lines = lines[1:]

    if lines and lines[-1].startswith("```"):
        lines = lines[:-1]

    return "\n".join(lines).strip()


def _validate_option(*, option: AIItineraryOption, catalog: AIItineraryCatalog) -> None:
    if len(option.days) != catalog.day_count:
        raise AIOutputValidationError(
            f"Expected exactly {catalog.day_count} day(s), got {len(option.days)}."
        )

    expected_days = set(range(1, catalog.day_count + 1))
    actual_days = {day.day for day in option.days}

    if actual_days != expected_days:
        raise AIOutputValidationError("Itinerary day numbers are incomplete or invalid.")

    if option.estimated_total_cost > catalog.total_budget:
        raise AIOutputValidationError("Itinerary option exceeds the requested budget.")

    if option.is_over_budget:
        raise AIOutputValidationError("Itinerary option is marked over budget.")

    activity_total = sum(
        (activity.estimated_cost for day in option.days for activity in day.activities),
        Decimal("0.00"),
    )
    if option.estimated_total_cost != activity_total:
        raise AIOutputValidationError(
            "Itinerary total must equal the sum of its activity costs."
        )

    for day in option.days:
        for activity in day.activities:
            _validate_activity_ids(activity=activity, catalog=catalog)

    activities = [activity for day in option.days for activity in day.activities]
    for field, required in (
        ("destination_id", catalog.required_destination_ids),
        ("accommodation_id", catalog.required_accommodation_ids),
        ("transportation_id", catalog.required_transportation_ids),
    ):
        if required is not None:
            actual = {getattr(activity, field) for activity in activities if getattr(activity, field) is not None}
            if actual != required:
                raise AIOutputValidationError(
                    f"Every option must use exactly the selected {field} values: {sorted(required)}."
                )

    if catalog.route_destination_order is not None:
        visits: list[int] = []
        for day in sorted(option.days, key=lambda item: item.day):
            for activity in day.activities:
                destination_id = activity.destination_id
                if destination_id is not None and (not visits or visits[-1] != destination_id):
                    visits.append(destination_id)
        if tuple(visits) != catalog.route_destination_order:
            raise AIOutputValidationError(
                "Itinerary destination visits must follow the calculated route order. "
                f"Expected {list(catalog.route_destination_order)}, got {visits}."
            )

    _validate_geo_consistency(option=option, catalog=catalog)


def _validate_geo_consistency(
    *,
    option: AIItineraryOption,
    catalog: AIItineraryCatalog,
) -> None:
    sorted_days = sorted(option.days, key=lambda item: item.day)

    if catalog.destination_coords is not None:
        for day in sorted_days:
            for activity in day.activities:
                dest_id = activity.destination_id
                if dest_id is None:
                    continue
                coords = catalog.destination_coords.get(dest_id)
                if coords is None:
                    raise AIOutputValidationError(
                        f"Destination {dest_id} is missing verified map coordinates."
                    )
                lat, lng = coords
                if (
                    not math.isfinite(lat)
                    or not math.isfinite(lng)
                    or not (-90.0 <= lat <= 90.0)
                    or not (-180.0 <= lng <= 180.0)
                ):
                    raise AIOutputValidationError(
                        f"Destination {dest_id} has invalid map coordinates."
                    )

    if catalog.route_destination_order is not None:
        return

    if catalog.destination_island_groups is not None:
        seen_islands: set[str] = set()
        current_island: str | None = None
        for day in sorted_days:
            for activity in day.activities:
                dest_id = activity.destination_id
                if dest_id is None:
                    continue
                island = catalog.destination_island_groups.get(dest_id, "mainland")
                if island != current_island:
                    if island in seen_islands:
                        raise AIOutputValidationError(
                            f"Itinerary backtracks across island groups by revisiting '{island}'."
                        )
                    seen_islands.add(island)
                    current_island = island

    if (
        catalog.destination_coords is not None
        and catalog.day_count >= 2
        and len(catalog.destination_ids) >= 2
    ):
        for day in sorted_days:
            day_dest_ids: list[int] = []
            for activity in day.activities:
                dest_id = activity.destination_id
                if dest_id is not None and (not day_dest_ids or day_dest_ids[-1] != dest_id):
                    day_dest_ids.append(dest_id)
            for prev_id, next_id in zip(day_dest_ids, day_dest_ids[1:]):
                lat1, lng1 = catalog.destination_coords[prev_id]
                lat2, lng2 = catalog.destination_coords[next_id]
                dist_km = haversine_km(
                    PlannerPoint(lat1, lng1, None),
                    PlannerPoint(lat2, lng2, None),
                )
                if dist_km > catalog.max_same_day_jump_km:
                    raise AIOutputValidationError(
                        f"Day {day.day} combines stops {dist_km:.1f} km apart "
                        f"(destination {prev_id} to {next_id}), exceeding "
                        f"{catalog.max_same_day_jump_km:.0f} km same-day limit."
                    )


def _validate_activity_ids(*, activity, catalog: AIItineraryCatalog) -> None:
    if (
        activity.destination_id is not None
        and activity.destination_id not in catalog.destination_ids
    ):
        raise AIOutputValidationError(
            f"Unknown destination_id {activity.destination_id}."
        )

    if (
        activity.accommodation_id is not None
        and activity.accommodation_id not in catalog.accommodation_ids
    ):
        raise AIOutputValidationError(
            f"Unknown accommodation_id {activity.accommodation_id}."
        )

    if (
        activity.transportation_id is not None
        and activity.transportation_id not in catalog.transportation_ids
    ):
        raise AIOutputValidationError(
            f"Unknown transportation_id {activity.transportation_id}."
        )

    for field, linked_destinations in (
        ("accommodation_id", catalog.accommodation_destination_ids),
        ("transportation_id", catalog.transportation_destination_ids),
    ):
        rate_id = getattr(activity, field)
        if (
            linked_destinations is not None and rate_id is not None
            and activity.destination_id is not None
            and linked_destinations.get(rate_id) != activity.destination_id
        ):
            raise AIOutputValidationError(
                f"{field} {rate_id} does not belong to destination_id {activity.destination_id}."
            )
