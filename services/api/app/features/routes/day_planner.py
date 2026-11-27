"""Adaptive multi-stop route cost matrix and Linear-Partition day planner."""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Literal, Sequence

from app.features.routes.ordering import (
    EXACT_ORDER_MAX_STOPS,
    exact_order,
    nearest_neighbor_two_opt,
)
from app.features.routes.sea_planner import (
    CROSSING_ORDER_PENALTY_MINUTES,
    ROAD_DETOUR_FACTOR,
    UNREACHABLE,
    PlannerPoint,
    SeaNetwork,
    SeaPath,
    haversine_km,
    road_minutes,
)

TIE_TOLERANCE = 1e-6

TripPace = Literal["relaxed", "balanced", "packed"]

PACE_HOURS: dict[str, float] = {
    "relaxed": 6.0,
    "balanced": 8.0,
    "packed": 10.0,
}

STAY_HOURS: dict[str, float] = {
    "short": 1.5,
    "half_day": 4.0,
    "full_day": 7.0,
    "overnight": 8.0,
    "multi_day": 8.0,
}


def normalize_stay_duration_key(raw: str | None) -> str:
    """Map raw destination stay strings into the 5 canonical duration buckets."""
    cleaned = (raw or "").strip().lower().replace("-", "_").replace(" ", "_")
    if not cleaned:
        return "half_day"
    if "multi" in cleaned:
        return "multi_day"
    if "overnight" in cleaned:
        return "overnight"
    if cleaned == "full" or "full_day" in cleaned or cleaned == "fullday":
        return "full_day"
    if cleaned == "half" or "half_day" in cleaned or cleaned == "halfday":
        return "half_day"
    if cleaned.startswith("short") or "1_2_hour" in cleaned:
        return "short"
    return "half_day"


def stay_hours_for_type(raw: str | None) -> float:
    return STAY_HOURS[normalize_stay_duration_key(raw)]


def stay_forces_day_end(raw: str | None) -> bool:
    return normalize_stay_duration_key(raw) in {"overnight", "multi_day"}


def normalize_island_group(raw: str | None) -> str:
    cleaned = (raw or "").strip().lower()
    if not cleaned or cleaned == "davao_mainland":
        return "mainland"
    return cleaned


def road_distance_km(a: PlannerPoint, b: PlannerPoint) -> float:
    return haversine_km(a, b) * ROAD_DETOUR_FACTOR


@dataclass(frozen=True)
class StopPlanInput:
    destination_id: int | None
    name: str
    lat: float
    lng: float
    island_group: str | None = None
    stay_duration_type: str | None = "half_day"
    must_visit: bool = True

    @property
    def point(self) -> PlannerPoint:
        return PlannerPoint(self.lat, self.lng, self.island_group)

    @property
    def normalized_island(self) -> str:
        return normalize_island_group(self.island_group)

    @property
    def normalized_stay_type(self) -> str:
        return normalize_stay_duration_key(self.stay_duration_type)

    @property
    def visit_hours(self) -> float:
        return stay_hours_for_type(self.stay_duration_type)

    @property
    def forces_day_end(self) -> bool:
        return stay_forces_day_end(self.stay_duration_type)


@dataclass(frozen=True)
class CostMatrix:
    ordering_costs: list[list[float]]
    transit_minutes: list[list[float]]
    distance_km: list[list[float]]
    sea_paths: list[list[SeaPath | None]]
    unconnected_islands: list[str]
    cost_source: str


@dataclass(frozen=True)
class PlannedDayBlock:
    day_number: int
    stops: list[StopPlanInput]
    visit_hours: float
    transit_hours: float
    total_hours: float
    is_continuation_day: bool = False
    continuation_of_name: str | None = None
    is_overloaded: bool = False
    overload_warning: str | None = None


@dataclass(frozen=True)
class PlanSavingsSummary:
    baseline_distance_km: float
    optimized_distance_km: float
    distance_saved_km: float
    distance_saved_percent: float
    baseline_transit_minutes: float
    optimized_transit_minutes: float
    minutes_saved: float


@dataclass(frozen=True)
class RouteDayPlanResult:
    ordered_stops: list[StopPlanInput]
    days: list[PlannedDayBlock]
    suggested_days: int
    order_method: str
    cost_source: str
    savings_vs_input: PlanSavingsSummary
    warnings: list[str]
    skipped_stops: list[StopPlanInput] = field(default_factory=list)


def _sea_path_totals(
    start: PlannerPoint,
    end: PlannerPoint,
    path: SeaPath,
) -> tuple[float, float]:
    road_km = 0.0
    road_min = 0.0
    sea_km = 0.0
    sea_min = 0.0
    cursor = start
    for hop in path.hops:
        board_pt = PlannerPoint(hop.board.lat, hop.board.lng, hop.board.island_group)
        land_pt = PlannerPoint(hop.land.lat, hop.land.lng, hop.land.island_group)
        road_km += road_distance_km(cursor, board_pt)
        road_min += road_minutes(cursor, board_pt)
        sea_km += haversine_km(board_pt, land_pt)
        sea_min += float(hop.link.crossing_minutes + hop.link.typical_wait_minutes)
        cursor = land_pt
    road_km += road_distance_km(cursor, end)
    road_min += road_minutes(cursor, end)
    return road_km + sea_km, road_min + sea_min


def build_cost_matrix(
    points: Sequence[PlannerPoint],
    *,
    network: SeaNetwork,
    driving: bool = True,
    override_transit_minutes: Sequence[Sequence[float | None]] | None = None,
    override_distance_km: Sequence[Sequence[float | None]] | None = None,
    cost_source: str = "haversine",
) -> CostMatrix:
    n = len(points)
    ordering = [[0.0] * n for _ in range(n)]
    transit = [[0.0] * n for _ in range(n)]
    distances = [[0.0] * n for _ in range(n)]
    sea_paths: list[list[SeaPath | None]] = [[None] * n for _ in range(n)]
    unconnected: set[str] = set()
    used_override = False

    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            a, b = points[i], points[j]
            group_a = normalize_island_group(a.island_group)
            group_b = normalize_island_group(b.island_group)

            if group_a == group_b:
                ov_min = (
                    override_transit_minutes[i][j]
                    if override_transit_minutes is not None
                    and i < len(override_transit_minutes)
                    and j < len(override_transit_minutes[i])
                    else None
                )
                ov_km = (
                    override_distance_km[i][j]
                    if override_distance_km is not None
                    and i < len(override_distance_km)
                    and j < len(override_distance_km[i])
                    else None
                )
                if ov_min is not None and math.isfinite(ov_min) and ov_min > 0:
                    mins = float(ov_min)
                    used_override = True
                else:
                    mins = road_minutes(a, b)
                km = (
                    float(ov_km)
                    if ov_km is not None and math.isfinite(ov_km) and ov_km >= 0
                    else road_distance_km(a, b)
                )
                ordering[i][j] = mins
                transit[i][j] = mins
                distances[i][j] = km
                continue

            path = network.find_path(a, b, driving=driving)
            sea_paths[i][j] = path
            if path is None:
                if group_a != "mainland":
                    unconnected.add(group_a)
                if group_b != "mainland":
                    unconnected.add(group_b)
                ordering[i][j] = UNREACHABLE
                transit[i][j] = road_minutes(a, b) + CROSSING_ORDER_PENALTY_MINUTES
                distances[i][j] = road_distance_km(a, b)
            else:
                total_km, total_min = _sea_path_totals(a, b, path)
                ordering[i][j] = total_min + CROSSING_ORDER_PENALTY_MINUTES
                transit[i][j] = total_min
                distances[i][j] = total_km

    return CostMatrix(
        ordering_costs=ordering,
        transit_minutes=transit,
        distance_km=distances,
        sea_paths=sea_paths,
        unconnected_islands=sorted(unconnected),
        cost_source=cost_source if used_override else "haversine",
    )


def _optimize_with_optional_anchor(
    costs: Sequence[Sequence[float]],
    *,
    fixed_start: bool,
    roundtrip: bool,
    has_origin: bool,
    locked_second_index: int | None,
) -> list[int]:
    n = len(costs)
    if n <= 1:
        return list(range(n))

    if has_origin and locked_second_index is not None and n >= 2:
        # Collapse origin (0) + locked_second into a single fixed anchor node 0*.
        remaining = [idx for idx in range(1, n) if idx != locked_second_index]
        sub_nodes = [locked_second_index, *remaining]
        m = len(sub_nodes)
        contracted = [[0.0] * m for _ in range(m)]
        for r in range(m):
            for c in range(m):
                if r == c:
                    continue
                src = sub_nodes[r]
                dst = 0 if c == 0 else sub_nodes[c]
                contracted[r][c] = costs[src][dst]
        solver = exact_order if m <= EXACT_ORDER_MAX_STOPS else nearest_neighbor_two_opt
        sub_order = solver(contracted, fixed_start=True, roundtrip=roundtrip)
        return [0, *(sub_nodes[idx] for idx in sub_order)]

    solver = exact_order if n <= EXACT_ORDER_MAX_STOPS else nearest_neighbor_two_opt
    return solver(costs, fixed_start=fixed_start, roundtrip=roundtrip)


def _allocate_extra_days(stops: Sequence[StopPlanInput], extra_count: int) -> list[int]:
    s = len(stops)
    extra = [0] * s

    def base_priority(i: int) -> float:
        score = {
            "multi_day": 6.0,
            "overnight": 4.0,
            "full_day": 2.0,
            "half_day": 1.0,
        }.get(stops[i].normalized_stay_type, 0.5)
        if i == s - 1:
            score += 0.2
        return score

    for _ in range(extra_count):
        best_idx = 0
        best_score = -math.inf
        for i in range(s):
            cand = base_priority(i) - extra[i] * 2.0
            if cand > best_score + TIE_TOLERANCE:
                best_score = cand
                best_idx = i
        extra[best_idx] += 1
    return extra


def _linear_partition(
    ordered_stops: Sequence[StopPlanInput],
    *,
    days: int,
    leg_transit_hours: Sequence[float],
    origin_transit_hours: float = 0.0,
    return_transit_hours: float = 0.0,
) -> list[tuple[int, int]]:
    s = len(ordered_stops)
    if days >= s:
        return [(i, i) for i in range(s)]
    if days <= 1:
        return [(0, s - 1)]

    prefix_visit = [0.0] * (s + 1)
    prefix_leg = [0.0] * (s + 1)
    for i in range(s):
        prefix_visit[i + 1] = prefix_visit[i] + ordered_stops[i].visit_hours
        if i > 0:
            prefix_leg[i + 1] = prefix_leg[i] + leg_transit_hours[i - 1]

    def block_load(start: int, end: int) -> float:
        load = prefix_visit[end + 1] - prefix_visit[start]
        load += origin_transit_hours if start == 0 else leg_transit_hours[start - 1]
        load += prefix_leg[end + 1] - prefix_leg[start + 1]
        if end == s - 1:
            load += return_transit_hours
        return load

    def block_violations(start: int, end: int) -> int:
        overnight_viols = sum(
            1 for i in range(start, end) if ordered_stops[i].forces_day_end
        )
        island_switches = sum(
            1
            for i in range(start, end)
            if ordered_stops[i].normalized_island != ordered_stops[i + 1].normalized_island
        )
        return overnight_viols * 10 + island_switches

    total_load = prefix_visit[s] + prefix_leg[s] + origin_transit_hours + return_transit_hours
    mean_load = total_load / days

    big = 1 << 20
    dp_viol = [[big] * (s + 1) for _ in range(days + 1)]
    dp_max = [[math.inf] * (s + 1) for _ in range(days + 1)]
    dp_viol[0][0] = 0
    dp_max[0][0] = 0.0

    for k in range(1, days + 1):
        for p in range(k, s + 1):
            for cut in range(k - 1, p):
                if dp_viol[k - 1][cut] >= big:
                    continue
                viol = dp_viol[k - 1][cut] + block_violations(cut, p - 1)
                load = block_load(cut, p - 1)
                max_load = max(dp_max[k - 1][cut], load)
                if viol < dp_viol[k][p] or (
                    viol == dp_viol[k][p] and max_load < dp_max[k][p] - TIE_TOLERANCE
                ):
                    dp_viol[k][p] = viol
                    dp_max[k][p] = max_load

    target_viol = dp_viol[days][s]
    target_max = dp_max[days][s] + TIE_TOLERANCE

    dp_sq_viol = [[big] * (s + 1) for _ in range(days + 1)]
    dp_sq = [[math.inf] * (s + 1) for _ in range(days + 1)]
    parent_cut = [[-1] * (s + 1) for _ in range(days + 1)]
    dp_sq_viol[0][0] = 0
    dp_sq[0][0] = 0.0

    for k in range(1, days + 1):
        for p in range(k, s + 1):
            for cut in range(k - 1, p):
                if dp_sq_viol[k - 1][cut] >= big:
                    continue
                load = block_load(cut, p - 1)
                if load > target_max:
                    continue
                viol = dp_sq_viol[k - 1][cut] + block_violations(cut, p - 1)
                if viol > target_viol:
                    continue
                sq = dp_sq[k - 1][cut] + (load - mean_load) ** 2
                if viol < dp_sq_viol[k][p] or (
                    viol == dp_sq_viol[k][p] and sq < dp_sq[k][p] - TIE_TOLERANCE
                ):
                    dp_sq_viol[k][p] = viol
                    dp_sq[k][p] = sq
                    parent_cut[k][p] = cut

    ranges: list[tuple[int, int]] = []
    cur_p = s
    for k in range(days, 0, -1):
        cut = parent_cut[k][cur_p]
        if cut < 0:
            return [(i, i) for i in range(days - 1)] + [(days - 1, s - 1)]
        ranges.append((cut, cur_p - 1))
        cur_p = cut
    ranges.reverse()
    return ranges


def plan_days(
    ordered_stops: Sequence[StopPlanInput],
    *,
    days: int,
    pace: TripPace = "balanced",
    leg_transit_hours: Sequence[float],
    origin_transit_hours: float = 0.0,
    return_transit_hours: float = 0.0,
) -> tuple[list[PlannedDayBlock], list[str]]:
    s = len(ordered_stops)
    target_days = max(1, min(14, days))
    if s == 0:
        return [], []

    ranges = (
        [(i, i) for i in range(s)]
        if target_days >= s
        else _linear_partition(
            ordered_stops,
            days=target_days,
            leg_transit_hours=leg_transit_hours,
            origin_transit_hours=origin_transit_hours,
            return_transit_hours=return_transit_hours,
        )
    )
    extra_per_stop = (
        _allocate_extra_days(ordered_stops, target_days - s)
        if target_days > s
        else [0] * s
    )

    warnings: list[str] = []
    planned_days: list[PlannedDayBlock] = []
    budget = PACE_HOURS[pace]
    day_num = 1

    if target_days < s:
        violations = sum(
            1
            for start, end in ranges
            for i in range(start, end)
            if ordered_stops[i].forces_day_end
        )
        if violations > 0:
            suffix = "" if violations == 1 else "s"
            warnings.append(
                f"Too few days ({target_days}) to end each day after every overnight stop; "
                f"add {violations} more day{suffix} if you plan to stay overnight at each.",
            )

    for r_idx, (start, end) in enumerate(ranges):
        block_stops = list(ordered_stops[start : end + 1])
        is_final_range = r_idx == len(ranges) - 1
        extra_after = extra_per_stop[end] if (is_final_range and target_days > s) else 0
        include_return_now = return_transit_hours > 0 and is_final_range and extra_after == 0

        transit_h = origin_transit_hours if start == 0 else leg_transit_hours[start - 1]
        for i in range(start, end):
            transit_h += leg_transit_hours[i]
        if include_return_now:
            transit_h += return_transit_hours

        visit_h = sum(stop.visit_hours for stop in block_stops)
        total_h = visit_h + transit_h
        is_overloaded = total_h > budget + 0.5 and (len(block_stops) > 1 or total_h > budget + 1.0)
        overload_msg = None
        if is_overloaded:
            overload_msg = (
                f"Day {day_num} is {total_h:.1f} h ({pace} pace is {budget:.0f} h). Add a day?"
            )
            warnings.append(overload_msg)

        planned_days.append(
            PlannedDayBlock(
                day_number=day_num,
                stops=block_stops,
                visit_hours=visit_h,
                transit_hours=transit_h,
                total_hours=total_h,
                is_overloaded=is_overloaded,
                overload_warning=overload_msg,
            )
        )
        day_num += 1

        extra = extra_per_stop[end] if target_days > s else 0
        for e in range(extra):
            is_very_last = is_final_range and e == extra - 1
            cont_transit = return_transit_hours if (is_very_last and return_transit_hours > 0) else 0.0
            planned_days.append(
                PlannedDayBlock(
                    day_number=day_num,
                    stops=[],
                    visit_hours=0.0,
                    transit_hours=cont_transit,
                    total_hours=cont_transit,
                    is_continuation_day=True,
                    continuation_of_name=block_stops[-1].name,
                )
            )
            day_num += 1

    return planned_days, warnings


def compute_suggested_days(
    ordered_stops: Sequence[StopPlanInput],
    *,
    leg_transit_hours: Sequence[float],
    pace: TripPace = "balanced",
    origin_transit_hours: float = 0.0,
    return_transit_hours: float = 0.0,
) -> int:
    s = len(ordered_stops)
    if s == 0:
        return 1

    forced_boundaries = sum(1 for i in range(s - 1) if ordered_stops[i].forces_day_end)
    min_overnights = min(14, forced_boundaries + 1)
    extra_multi = sum(1 for stop in ordered_stops if stop.normalized_stay_type == "multi_day")
    budget = PACE_HOURS[pace]

    chosen = min(14, s)
    for d in range(min_overnights, min(14, s) + 1):
        day_blocks, _ = plan_days(
            ordered_stops,
            days=d,
            pace=pace,
            leg_transit_hours=leg_transit_hours,
            origin_transit_hours=origin_transit_hours,
            return_transit_hours=return_transit_hours,
        )
        if not any(len(day.stops) > 1 and day.total_hours > budget + 0.75 for day in day_blocks):
            chosen = d
            break

    return min(14, max(1, chosen + extra_multi))


def _measure_sequence(
    matrix: CostMatrix,
    point_indices: Sequence[int],
    *,
    has_origin: bool,
    roundtrip: bool,
) -> tuple[float, float]:
    if not point_indices:
        return 0.0, 0.0
    km = matrix.distance_km[0][point_indices[0]] if has_origin else 0.0
    mins = matrix.transit_minutes[0][point_indices[0]] if has_origin else 0.0
    for a, b in zip(point_indices, point_indices[1:]):
        km += matrix.distance_km[a][b]
        mins += matrix.transit_minutes[a][b]
    if roundtrip:
        anchor = 0 if has_origin else point_indices[0]
        last = point_indices[-1]
        if last != anchor:
            km += matrix.distance_km[last][anchor]
            mins += matrix.transit_minutes[last][anchor]
    return km, mins


def plan_multi_day_route(
    *,
    stops: Sequence[StopPlanInput],
    days: int,
    pace: TripPace = "balanced",
    origin: PlannerPoint | None = None,
    roundtrip: bool = False,
    locked_first_destination_id: int | None = None,
    preserve_first_destination: bool = False,
    driving: bool = True,
    prune_optional_to_fit: bool = False,
    network: SeaNetwork | None = None,
    override_by_pair: dict[tuple[int | None, int | None], tuple[float, float]] | None = None,
    override_transit_minutes: Sequence[Sequence[float | None]] | None = None,
    override_distance_km: Sequence[Sequence[float | None]] | None = None,
    cost_source: str = "haversine",
) -> RouteDayPlanResult:
    sea_net = network if network is not None else SeaNetwork([], [])
    if not stops:
        return RouteDayPlanResult(
            ordered_stops=[],
            days=[],
            suggested_days=1,
            order_method="requested",
            cost_source=cost_source,
            savings_vs_input=PlanSavingsSummary(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
            warnings=[],
        )

    effective_locked_id = locked_first_destination_id
    if effective_locked_id is None and preserve_first_destination:
        effective_locked_id = stops[0].destination_id

    active_stops = list(stops)
    skipped: list[StopPlanInput] = []

    def run_once(
        current: list[StopPlanInput],
        baseline_ref: list[StopPlanInput],
        *,
        ov_min=None,
        ov_km=None,
    ) -> RouteDayPlanResult:
        has_origin = origin is not None
        locked_idx = -1
        if effective_locked_id is not None:
            for idx, stop in enumerate(current):
                if stop.destination_id == effective_locked_id:
                    locked_idx = idx
                    break
        has_locked = locked_idx >= 0

        working = list(current)
        if not has_origin and has_locked and locked_idx != 0:
            working.insert(0, working.pop(locked_idx))

        points = ([origin] if origin is not None else []) + [s.point for s in working]
        if override_by_pair is not None and ov_min is None:
            keys: list[int | None] = ([None] if has_origin else []) + [
                s.destination_id for s in working
            ]
            m_len = len(keys)
            built_min: list[list[float | None]] = [[None] * m_len for _ in range(m_len)]
            built_km: list[list[float | None]] = [[None] * m_len for _ in range(m_len)]
            for r in range(m_len):
                for c in range(m_len):
                    if r == c:
                        continue
                    pair = override_by_pair.get((keys[r], keys[c]))
                    if pair is not None:
                        built_min[r][c] = pair[0]
                        built_km[r][c] = pair[1]
            ov_min = built_min
            ov_km = built_km
        matrix = build_cost_matrix(
            points,
            network=sea_net,
            driving=driving,
            override_transit_minutes=ov_min,
            override_distance_km=ov_km,
            cost_source=cost_source,
        )

        fixed_second = None
        if has_origin and has_locked:
            for idx, stop in enumerate(working):
                if stop.destination_id == effective_locked_id:
                    fixed_second = idx + 1
                    break

        optimized_indices = _optimize_with_optional_anchor(
            matrix.ordering_costs,
            fixed_start=has_origin or has_locked,
            roundtrip=roundtrip,
            has_origin=has_origin,
            locked_second_index=fixed_second,
        )
        stop_order = [idx for idx in optimized_indices if idx != 0] if has_origin else optimized_indices
        ordered = [working[idx - 1 if has_origin else idx] for idx in stop_order]

        baseline_points = [
            (working.index(s) + (1 if has_origin else 0)) for s in baseline_ref
        ]
        base_km, base_min = _measure_sequence(
            matrix, baseline_points, has_origin=has_origin, roundtrip=roundtrip,
        )
        opt_km, opt_min = _measure_sequence(
            matrix, stop_order, has_origin=has_origin, roundtrip=roundtrip,
        )

        leg_hours: list[float] = []
        used_sea = False
        for a, b in zip(stop_order, stop_order[1:]):
            leg_hours.append(matrix.transit_minutes[a][b] / 60.0)
            if matrix.sea_paths[a][b] and matrix.sea_paths[a][b].hops:
                used_sea = True
        origin_h = matrix.transit_minutes[0][stop_order[0]] / 60.0 if has_origin else 0.0
        if has_origin and matrix.sea_paths[0][stop_order[0]] and matrix.sea_paths[0][stop_order[0]].hops:
            used_sea = True

        return_h = 0.0
        if roundtrip:
            anchor = 0 if has_origin else stop_order[0]
            if stop_order[-1] != anchor:
                return_h = matrix.transit_minutes[stop_order[-1]][anchor] / 60.0
                if matrix.sea_paths[stop_order[-1]][anchor] and matrix.sea_paths[stop_order[-1]][anchor].hops:
                    used_sea = True

        suggested = compute_suggested_days(
            ordered,
            leg_transit_hours=leg_hours,
            pace=pace,
            origin_transit_hours=origin_h,
            return_transit_hours=return_h,
        )
        day_blocks, day_warnings = plan_days(
            ordered,
            days=days,
            pace=pace,
            leg_transit_hours=leg_hours,
            origin_transit_hours=origin_h,
            return_transit_hours=return_h,
        )

        warnings = [
            *(
                f"No ferry or pier link is mapped yet for {island}; sea travel is estimated."
                for island in matrix.unconnected_islands
            ),
            *day_warnings,
        ]
        if len(points) <= 2:
            method = "requested"
        elif used_sea:
            method = "island_aware"
        elif len(points) <= EXACT_ORDER_MAX_STOPS:
            method = "exact"
        else:
            method = "nearest_neighbor_2opt"

        saved_km = max(0.0, base_km - opt_km)
        saved_min = max(0.0, base_min - opt_min)
        saved_pct = (saved_km / base_km * 100.0) if base_km > 1e-6 else 0.0

        return RouteDayPlanResult(
            ordered_stops=ordered,
            days=day_blocks,
            suggested_days=suggested,
            order_method=method,
            cost_source=matrix.cost_source,
            savings_vs_input=PlanSavingsSummary(
                baseline_distance_km=round(base_km, 2),
                optimized_distance_km=round(opt_km, 2),
                distance_saved_km=round(saved_km, 2),
                distance_saved_percent=round(saved_pct, 1),
                baseline_transit_minutes=round(base_min, 1),
                optimized_transit_minutes=round(opt_min, 1),
                minutes_saved=round(saved_min, 1),
            ),
            warnings=warnings,
        )

    result = run_once(
        active_stops,
        active_stops,
        ov_min=override_transit_minutes,
        ov_km=override_distance_km,
    )
    if prune_optional_to_fit:
        total_budget = max(1, min(14, days)) * PACE_HOURS[pace] + 0.5
        while len(active_stops) > 1:
            overloaded = any(d.is_overloaded for d in result.days) or (
                sum(d.total_hours for d in result.days) > total_budget
            )
            if not overloaded:
                break
            candidates = [
                i
                for i, stop in enumerate(active_stops)
                if not stop.must_visit and stop.destination_id != effective_locked_id
            ]
            if not candidates:
                break
            avg_lat = sum(s.lat for s in active_stops) / len(active_stops)
            avg_lng = sum(s.lng for s in active_stops) / len(active_stops)
            centroid = PlannerPoint(avg_lat, avg_lng, None)
            worst_idx = max(
                candidates,
                key=lambda i: road_minutes(centroid, active_stops[i].point)
                + active_stops[i].visit_hours * 15.0,
            )
            skipped.append(active_stops.pop(worst_idx))
            result = run_once(active_stops, active_stops)

        if skipped:
            names = ", ".join(s.name for s in skipped)
            return RouteDayPlanResult(
                ordered_stops=result.ordered_stops,
                days=result.days,
                suggested_days=result.suggested_days,
                order_method=result.order_method,
                cost_source=result.cost_source,
                savings_vs_input=result.savings_vs_input,
                warnings=[
                    *result.warnings,
                    f"Skipped optional stops to fit {max(1, min(14, days))} days: {names}.",
                ],
                skipped_stops=skipped,
            )
    return result
