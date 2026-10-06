// Small planar geometry helpers. Distances are computed in a local
// equirectangular projection around the query point, which is accurate to
// well under a meter at the few-kilometer scale this tool works at.

const M_PER_DEG_LAT = 110_540;
const M_PER_DEG_LON_AT_EQUATOR = 111_320;

/** Project lat/lon to local x/y meters around an origin. */
export function toLocal(origin, lat, lon) {
  const kx = M_PER_DEG_LON_AT_EQUATOR * Math.cos((origin.lat * Math.PI) / 180);
  return { x: (lon - origin.lon) * kx, y: (lat - origin.lat) * M_PER_DEG_LAT };
}

/** Inverse of toLocal. */
export function fromLocal(origin, x, y) {
  const kx = M_PER_DEG_LON_AT_EQUATOR * Math.cos((origin.lat * Math.PI) / 180);
  return { lat: origin.lat + y / M_PER_DEG_LAT, lon: origin.lon + x / kx };
}

/**
 * Distance in meters from `origin` to the closest point on a polyline given as
 * ArcGIS `paths` ([[ [lon, lat], ... ], ...]). Returns the distance and the
 * closest point (lat/lon).
 */
export function distanceToPaths(origin, paths) {
  let best = { distance: Infinity, point: null };
  for (const path of paths ?? []) {
    for (let i = 0; i < path.length; i++) {
      const a = toLocal(origin, path[i][1], path[i][0]);
      const b = i + 1 < path.length ? toLocal(origin, path[i + 1][1], path[i + 1][0]) : a;
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const len2 = dx * dx + dy * dy;
      // Origin is (0, 0) in local coordinates.
      const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, -(a.x * dx + a.y * dy) / len2));
      const px = a.x + t * dx;
      const py = a.y + t * dy;
      const d = Math.hypot(px, py);
      if (d < best.distance) best = { distance: d, point: fromLocal(origin, px, py) };
    }
  }
  return best;
}

const COMPASS = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'];

/** Compass direction (e.g. "northeast") from origin to a point. */
export function compassDirection(origin, point) {
  const { x, y } = toLocal(origin, point.lat, point.lon);
  const bearing = ((Math.atan2(x, y) * 180) / Math.PI + 360) % 360;
  return COMPASS[Math.round(bearing / 45) % 8];
}
