"""Find pier-to-pier boat connections between Davao's island groups.

Roads never cross water. When two consecutive stops are on different island
groups (mainland, Samal, Talikud, ...), the route drives to a departure pier,
takes one or more boat links, and drives on from the arrival pier. This module
chooses those piers with Dijkstra over a small graph:

- the start stop connects by road to every pier on its island group,
- piers on the same island group connect to each other by road,
- each active sea link connects its two piers (both ways when bidirectional),
- every pier on the end stop's island group connects by road to the end stop.

Road costs here are straight-line estimates; the real road legs are routed
later. They only need to rank piers sensibly.
"""

import heapq
from dataclasses import dataclass
from decimal import Decimal
from math import asin, cos, radians, sin, sqrt

from app.features.sea_links.models import MAINLAND

EARTH_RADIUS_KM = 6371.0
# Roads are longer than the straight line; ~1.35 suits Davao's road network.
ROAD_DETOUR_FACTOR = 1.35
PLANNING_ROAD_SPEED_KMH = 40.0
# Extra minutes when a private car must be left at a passenger-only pier.
PASSENGER_ONLY_PENALTY_MINUTES = 60.0
# Extra cost per crossing so stop ordering keeps island stops together.
CROSSING_ORDER_PENALTY_MINUTES = 30.0
UNREACHABLE = 1e9


@dataclass(frozen=True)
class PlannerPort:
    port_id: int
    name: str
    lat: float
    lng: float
    island_group: str
    verified: bool = False


@dataclass(frozen=True)
class PlannerLink:
    link_id: int
    from_port_id: int
    to_port_id: int
    vessel_type: str
    allows_private_vehicle: bool
    crossing_minutes: int
    typical_wait_minutes: int
    bidirectional: bool = True
    schedule_text: str | None = None
    fare_passenger: Decimal | None = None
    fare_vehicle: Decimal | None = None
    geometry_polyline: str | None = None
    verified: bool = False


@dataclass(frozen=True)
class SeaHop:
    """One boat ride, already oriented in the direction of travel."""

    link: PlannerLink
    board: PlannerPort
    land: PlannerPort
    # True when the link's stored geometry runs land -> board and must be reversed.
    reversed_geometry: bool = False


@dataclass(frozen=True)
class SeaPath:
    hops: list[SeaHop]
    cost_minutes: float


@dataclass(frozen=True)
class PlannerPoint:
    lat: float
    lng: float
    island_group: str | None

    @property
    def group(self) -> str:
        return self.island_group or MAINLAND


class SeaNetwork:
    def __init__(self, ports: list[PlannerPort], links: list[PlannerLink]) -> None:
        self.ports = {port.port_id: port for port in ports}
        self.links = [
            link for link in links
            if link.from_port_id in self.ports and link.to_port_id in self.ports
        ]

    @property
    def is_empty(self) -> bool:
        return not self.links

    def find_path(
        self, start: PlannerPoint, end: PlannerPoint, *, driving: bool,
    ) -> SeaPath | None:
        """Cheapest boat connection between two points on different island groups."""
        if start.group == end.group:
            return SeaPath(hops=[], cost_minutes=0.0)

        start_node, end_node = "start", "end"
        # adjacency: node -> list of (next_node, cost, hop or None)
        edges: dict[object, list[tuple[object, float, SeaHop | None]]] = {}

        def add(a, b, cost, hop=None) -> None:
            edges.setdefault(a, []).append((b, cost, hop))

        ports = list(self.ports.values())
        for port in ports:
            if port.island_group == start.group:
                add(start_node, port.port_id, road_minutes(start, port))
            if port.island_group == end.group:
                add(port.port_id, end_node, road_minutes(port, end))
            for other in ports:
                if other.port_id != port.port_id and other.island_group == port.island_group:
                    add(port.port_id, other.port_id, road_minutes(port, other))

        for link in self.links:
            board, land = self.ports[link.from_port_id], self.ports[link.to_port_id]
            cost = float(link.crossing_minutes + link.typical_wait_minutes)
            if driving and not link.allows_private_vehicle:
                cost += PASSENGER_ONLY_PENALTY_MINUTES
            add(board.port_id, land.port_id, cost, SeaHop(link=link, board=board, land=land))
            if link.bidirectional:
                add(land.port_id, board.port_id, cost, SeaHop(
                    link=link, board=land, land=board, reversed_geometry=True,
                ))

        best: dict[object, float] = {start_node: 0.0}
        previous: dict[object, tuple[object, SeaHop | None]] = {}
        queue: list[tuple[float, int, object]] = [(0.0, 0, start_node)]
        counter = 1
        while queue:
            cost, _, node = heapq.heappop(queue)
            if node == end_node:
                break
            if cost > best.get(node, UNREACHABLE):
                continue
            for next_node, step_cost, hop in edges.get(node, []):
                candidate = cost + step_cost
                if candidate < best.get(next_node, UNREACHABLE):
                    best[next_node] = candidate
                    previous[next_node] = (node, hop)
                    heapq.heappush(queue, (candidate, counter, next_node))
                    counter += 1

        if end_node not in best:
            return None
        hops: list[SeaHop] = []
        node: object = end_node
        while node != start_node:
            node, hop = previous[node]
            if hop is not None:
                hops.append(hop)
        hops.reverse()
        if not hops:
            return None
        return SeaPath(hops=hops, cost_minutes=best[end_node])

    def order_costs(self, points: list[PlannerPoint], *, driving: bool) -> list[list[float]]:
        """Planning minutes between every pair, including boat connections."""
        costs = []
        for start in points:
            row = []
            for end in points:
                if start is end:
                    row.append(0.0)
                elif start.group == end.group:
                    row.append(road_minutes(start, end))
                else:
                    path = self.find_path(start, end, driving=driving)
                    row.append(
                        UNREACHABLE if path is None
                        else path.cost_minutes + CROSSING_ORDER_PENALTY_MINUTES * len(path.hops)
                    )
            costs.append(row)
        return costs


def haversine_km(a, b) -> float:
    lat_1, lat_2 = radians(a.lat), radians(b.lat)
    delta_lat = radians(b.lat - a.lat)
    delta_lng = radians(b.lng - a.lng)
    value = sin(delta_lat / 2) ** 2 + cos(lat_1) * cos(lat_2) * sin(delta_lng / 2) ** 2
    return 2 * EARTH_RADIUS_KM * asin(sqrt(value))


def road_minutes(a, b) -> float:
    return haversine_km(a, b) * ROAD_DETOUR_FACTOR / PLANNING_ROAD_SPEED_KMH * 60.0
