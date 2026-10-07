// Shared request handling for both the REST API and the MCP tools: resolve a
// location (lat/lon or a spoken address) and run the query.

import { geocode } from './geocode.js';
import { describeHere, findParking } from './parking.js';

export class UserError extends Error {}

async function resolveLocation({ lat, lon, address }, fetchImpl) {
  if (lat != null && lon != null) {
    const la = Number(lat);
    const lo = Number(lon);
    if (!Number.isFinite(la) || !Number.isFinite(lo) || Math.abs(la) > 90 || Math.abs(lo) > 180) {
      throw new UserError('lat and lon must be valid coordinates');
    }
    return { lat: la, lon: lo };
  }
  if (address) {
    const hit = await geocode(String(address), fetchImpl);
    if (!hit) throw new UserError(`I couldn't find "${address}" in Seattle.`);
    return hit;
  }
  throw new UserError('Provide lat and lon, or an address.');
}

function withMatched(result, loc) {
  if (!loc.matched) return result;
  return { ...result, location: { ...result.location, matched: loc.matched }, speech: `Near ${loc.matched}: ${result.speech}` };
}

export async function parkingRulesHere(args, fetchImpl = fetch) {
  const loc = await resolveLocation(args, fetchImpl);
  const result = await describeHere({ ...loc, permitZone: args.permitZone || undefined, fetchImpl });
  return withMatched(result, loc);
}

export async function nearestParking(args, fetchImpl = fetch) {
  const loc = await resolveLocation(args, fetchImpl);
  const num = (v) => (v == null || v === '' ? undefined : Number(v));
  const result = await findParking({
    ...loc,
    radiusMeters: num(args.radiusMeters),
    limit: Math.min(num(args.limit) ?? 3, 10),
    minMinutes: num(args.minMinutes),
    freeOnly: args.freeOnly === true || args.freeOnly === 'true' || args.freeOnly === '1',
    permitZone: args.permitZone || undefined,
    fetchImpl,
  });
  return withMatched(result, loc);
}
