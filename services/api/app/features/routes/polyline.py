"""Google encoded polyline (precision 5), as returned by OSRM and Mapbox."""


def decode_polyline5(encoded: str) -> list[tuple[float, float]]:
    """Returns (lat, lng) points."""
    points: list[tuple[float, float]] = []
    index = lat = lng = 0
    length = len(encoded)
    while index < length:
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                if index >= length:
                    raise ValueError("Truncated encoded polyline.")
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lng += deltas[1]
        points.append((lat / 1e5, lng / 1e5))
    return points


def encode_polyline5(points: list[tuple[float, float]]) -> str:
    """Encodes (lat, lng) points."""
    output: list[str] = []
    previous_lat = previous_lng = 0
    for lat, lng in points:
        current_lat = round(lat * 1e5)
        current_lng = round(lng * 1e5)
        for delta in (current_lat - previous_lat, current_lng - previous_lng):
            value = ~(delta << 1) if delta < 0 else delta << 1
            while value >= 0x20:
                output.append(chr((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            output.append(chr(value + 63))
        previous_lat, previous_lng = current_lat, current_lng
    return "".join(output)


def join_polylines5(encoded_parts: list[str]) -> str:
    """Joins consecutive polylines, dropping a repeated joint point."""
    points: list[tuple[float, float]] = []
    for part in encoded_parts:
        decoded = decode_polyline5(part)
        if points and decoded and points[-1] == decoded[0]:
            decoded = decoded[1:]
        points.extend(decoded)
    return encode_polyline5(points)
