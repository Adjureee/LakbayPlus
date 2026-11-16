"""Turn a model's answer into commute steps an admin can review.

The model only drafts. Everything it returns is checked here, a draft is never
verified, and anything that does not fit is reported in `unclear` instead of
being kept or "fixed".
"""

from __future__ import annotations

import json
import re

from pydantic import ValidationError

from app.features.commute.schemas import CommuteRouteInput, CommuteStepInput

MAX_UNCLEAR = 12


def _strip_fence(content: str) -> str:
    value = content.strip()
    if value.startswith("```"):
        value = value.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return value


def _normalize_vehicle(value: object) -> str:
    return re.sub(r"[\s\-]+", "_", str(value or "").strip().lower())


def parse_commute_draft(content: str) -> tuple[list[CommuteRouteInput], list[str]] | None:
    """Routes and the notes about what was unclear, or None when the answer is not usable."""
    try:
        raw = json.loads(_strip_fence(content))
    except (TypeError, ValueError):
        return None
    if not isinstance(raw, dict) or not isinstance(raw.get("routes"), list):
        return None

    unclear: list[str] = [
        str(item).strip() for item in (raw.get("unclear") or []) if str(item).strip()
    ] if isinstance(raw.get("unclear"), list) else []

    routes: list[CommuteRouteInput] = []
    for route_index, route in enumerate(raw["routes"], start=1):
        if not isinstance(route, dict) or not isinstance(route.get("steps"), list):
            unclear.append(f"Route {route_index} had no steps, so it was left out.")
            continue
        steps: list[CommuteStepInput] = []
        for step_index, step in enumerate(route["steps"], start=1):
            if not isinstance(step, dict):
                unclear.append(f"Route {route_index}, step {step_index} was not readable.")
                continue
            candidate = {**step, "vehicle": _normalize_vehicle(step.get("vehicle"))}
            try:
                steps.append(CommuteStepInput.model_validate(candidate))
            except ValidationError:
                unclear.append(
                    f"Route {route_index}, step {step_index} "
                    f"({step.get('vehicle') or 'no vehicle'}) was not valid and was left out."
                )
        if not steps:
            unclear.append(f"Route {route_index} had no valid steps, so it was left out.")
            continue
        try:
            routes.append(CommuteRouteInput(
                start_area=route.get("start_area") if isinstance(route.get("start_area"), str) else None,
                steps=steps[:12],
                # A draft is never verified: a person confirms it first.
                is_verified=False,
            ))
        except ValidationError:
            unclear.append(f"Route {route_index} was not valid and was left out.")
    return routes, unclear[:MAX_UNCLEAR]
