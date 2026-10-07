// Core logic: turn SDOT blockface records into answers to
//   1. "What are the parking rules where I am?"     -> describeHere()
//   2. "Where's the nearest place I can park?"       -> findParking()
// Each answer includes structured data plus a `speech` string written to be
// read aloud by Siri or ChatGPT voice.

import { PARKING_CATEGORIES_LAYER, RPZ_ZONES_LAYER, queryNear } from './arcgis.js';
import { compassDirection, distanceToPaths } from './geo.js';
import { formatClock, formatLimit, parseClock, parsePeakHours, seattleTime } from './schedule.js';

const DAY_TYPES = ['WKD', 'SAT', 'SUN'];

const BLOCKFACE_FIELDS = [
  'UNITDESC', 'SIDE', 'PARKING_CATEGORY', 'PARKING_TIME_LIMIT', 'RPZ_ZONE', 'PEAK_HOUR',
  'PAIDAREA', 'PARKING_SPACES',
  ...DAY_TYPES.flatMap((d) => [`START_TIME_${d}`, `END_TIME_${d}`]),
  ...DAY_TYPES.flatMap((d) => [1, 2, 3].flatMap((i) => [`${d}_RATE${i}`, `${d}_START${i}`, `${d}_END${i}`])),
];

const RPZ_FIELDS = ['RPZ_ZONE', 'NAME', 'INEFFECT'];

export const HERE_RADIUS_M = 60;
export const DEFAULT_SEARCH_RADIUS_M = 500;
export const MAX_SEARCH_RADIUS_M = 1500;

// ---------------------------------------------------------------------------
// Formatting

const SIDE_NAMES = {
  N: 'north', S: 'south', E: 'east', W: 'west',
  NE: 'northeast', NW: 'northwest', SE: 'southeast', SW: 'southwest',
};

const STREET_WORDS = {
  N: 'North', S: 'South', E: 'East', W: 'West',
  NE: 'Northeast', NW: 'Northwest', SE: 'Southeast', SW: 'Southwest',
  ST: 'Street', AVE: 'Avenue', PL: 'Place', BLVD: 'Boulevard', DR: 'Drive', RD: 'Road',
  CT: 'Court', AL: 'Alley', LN: 'Lane', PKWY: 'Parkway', TER: 'Terrace', HWY: 'Highway', CIR: 'Circle',
  BETWEEN: 'between', AND: 'and',
};

/** "BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST" -> "Broadway East between East Olive Way and East Thomas Street" */
export function formatStreet(unitdesc) {
  if (!unitdesc) return 'an unnamed block';
  return unitdesc
    .trim()
    .split(/\s+/)
    .map((w) => STREET_WORDS[w] ?? (/^\d/.test(w) ? w.toLowerCase() : w[0] + w.slice(1).toLowerCase()))
    .join(' ');
}

function formatRate(rate) {
  return `$${rate.toFixed(2)} an hour`;
}

/** Spoken distance in US units, e.g. "about 300 feet", "about 0.4 miles". */
export function formatDistance(meters) {
  const feet = meters * 3.28084;
  if (feet < 75) return 'right here';
  if (feet < 1000) return `about ${Math.round(feet / 50) * 50} feet`;
  return `about ${(feet / 5280).toFixed(1)} miles`;
}

// ---------------------------------------------------------------------------
// Rules for one blockface

function enforcementHours(a, now) {
  const d = now.dayType.toUpperCase();
  const start = parseClock(a[`START_TIME_${d}`]);
  const end = parseClock(a[`END_TIME_${d}`]);
  return start == null || end == null ? null : { start, end: end === 0 ? 1440 : end };
}

function currentRate(a, now) {
  const d = now.dayType.toUpperCase();
  for (const i of [1, 2, 3]) {
    const rate = a[`${d}_RATE${i}`];
    const start = a[`${d}_START${i}`];
    const end = a[`${d}_END${i}`]; // inclusive minute
    if (rate != null && start != null && end != null && now.minutes >= start && now.minutes <= end) return rate;
  }
  return null;
}

/**
 * Evaluate a blockface's rules at a given Seattle-local time.
 *
 * @param {object} a SDOT Parking_Categories attributes
 * @param {{dayType: string, isWeekday: boolean, minutes: number}} now from seattleTime()
 * @param {{permitZone?: string}} [opts] the caller's RPZ permit zone, if any
 */
export function evaluateBlockface(a, now, { permitZone } = {}) {
  const r = {
    street: formatStreet(a.UNITDESC),
    side: SIDE_NAMES[a.SIDE] ?? null,
    category: a.PARKING_CATEGORY ?? 'Unknown',
    canParkNow: false,
    freeNow: true,
    ratePerHour: null,
    timeLimitMinutes: null,
    rpzZone: a.RPZ_ZONE ?? null,
    peakHourNoParking: a.PEAK_HOUR ?? null,
    spaces: a.PARKING_SPACES ?? null,
    summary: '',
    notes: [],
  };

  const limit = a.PARKING_TIME_LIMIT || null;

  switch (r.category) {
    case 'No Parking Allowed':
      r.summary = 'no parking';
      break;

    case 'Carpool Parking':
      r.summary = 'carpool permit parking only';
      break;

    case 'Paid Parking': {
      const hours = enforcementHours(a, now);
      r.canParkNow = true;
      if (!hours) {
        r.summary = 'paid parking area, but free today';
      } else if (now.minutes >= hours.start && now.minutes < hours.end) {
        const rate = currentRate(a, now);
        r.freeNow = !rate;
        r.ratePerHour = rate || null;
        r.timeLimitMinutes = limit;
        r.summary = [
          rate ? `paid, ${formatRate(rate)} until ${formatClock(hours.end)}` : `paid parking until ${formatClock(hours.end)}`,
          limit && `${formatLimit(limit)} limit`,
        ].filter(Boolean).join(', ');
      } else if (now.minutes < hours.start) {
        r.timeLimitMinutes = hours.start - now.minutes;
        r.summary = `free until ${formatClock(hours.start)}, then paid`;
      } else {
        r.summary = `free now, paid parking ended at ${formatClock(hours.end)}`;
      }
      if (a.PAIDAREA) r.notes.push(`Paid area: ${a.PAIDAREA}`);
      break;
    }

    case 'Time Limited Parking':
      r.canParkNow = true;
      r.timeLimitMinutes = limit;
      r.summary = limit ? `free, ${formatLimit(limit)} limit` : 'free, time limited';
      r.notes.push('Check the posted sign for the hours the time limit applies.');
      break;

    case 'Restricted Parking Zone': {
      r.canParkNow = true;
      const zone = a.RPZ_ZONE ? `zone ${a.RPZ_ZONE}` : 'a restricted parking zone';
      if (permitZone && a.RPZ_ZONE && String(permitZone) === String(a.RPZ_ZONE)) {
        r.summary = `free with your ${zone} permit, no time limit`;
        break;
      }
      const hours = enforcementHours(a, now);
      if (hours && !(now.minutes >= hours.start && now.minutes < hours.end)) {
        r.summary = `free, ${zone} permit rules not in effect right now`;
        if (now.minutes < hours.start) r.timeLimitMinutes = hours.start - now.minutes + (limit ?? 0);
      } else {
        r.timeLimitMinutes = limit ?? 120;
        r.summary = `free, ${formatLimit(r.timeLimitMinutes)} limit without a ${zone} permit`;
        if (!limit) r.notes.push('Visitor time limit not in the city data; 2 hours is typical, check the sign.');
        if (hours) r.summary += ` until ${formatClock(hours.end)}`;
      }
      break;
    }

    case 'Unrestricted Parking':
      r.canParkNow = true;
      r.summary = 'free, no posted time limit';
      r.notes.push("Seattle's 72-hour rule still applies.");
      break;

    default:
      r.summary = `${r.category.toLowerCase()}`;
  }

  // Weekday peak-hour (rush hour) tow-away restrictions override everything.
  const peaks = now.isWeekday ? parsePeakHours(a.PEAK_HOUR) : [];
  const active = peaks.find(([s, e]) => now.minutes >= s && now.minutes < e);
  const upcoming = peaks.filter(([s]) => s > now.minutes).sort((x, y) => x[0] - y[0])[0];
  if (active) {
    r.canParkNow = false;
    r.summary = `no parking right now, rush-hour tow-away zone until ${formatClock(active[1])}`;
  } else if (upcoming && r.canParkNow) {
    const minutesLeft = upcoming[0] - now.minutes;
    r.timeLimitMinutes = r.timeLimitMinutes == null ? minutesLeft : Math.min(r.timeLimitMinutes, minutesLeft);
    if (minutesLeft <= 180) r.summary += `, but it becomes a tow-away zone at ${formatClock(upcoming[0])}`;
  }
  if (a.PEAK_HOUR) r.notes.push(`No parking ${a.PEAK_HOUR} on weekdays (peak-hour tow-away).`);

  return r;
}

// ---------------------------------------------------------------------------
// Queries

async function nearbyBlockfaces(origin, radiusMeters, fetchImpl) {
  const features = await queryNear(
    PARKING_CATEGORIES_LAYER,
    { ...origin, radiusMeters, outFields: BLOCKFACE_FIELDS },
    fetchImpl,
  );
  return features
    .map((f) => ({ attributes: f.attributes, ...distanceToPaths(origin, f.geometry?.paths) }))
    .filter((f) => Number.isFinite(f.distance))
    .sort((x, y) => x.distance - y.distance);
}

async function rpzZoneAt(origin, fetchImpl) {
  const [zone] = await queryNear(
    RPZ_ZONES_LAYER,
    { ...origin, radiusMeters: 0, outFields: RPZ_FIELDS, returnGeometry: false },
    fetchImpl,
  );
  if (!zone) return null;
  const { RPZ_ZONE, NAME, INEFFECT } = zone.attributes;
  return { zone: RPZ_ZONE, name: NAME, inEffect: INEFFECT?.replace(/\s+/g, ' ').trim() ?? null };
}

function capitalize(s) {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

/**
 * Parking rules at the caller's location.
 */
export async function describeHere({ lat, lon, permitZone, date = new Date(), fetchImpl = fetch }) {
  const origin = { lat, lon };
  const now = seattleTime(date);
  const [blockfaces, rpz] = await Promise.all([
    nearbyBlockfaces(origin, HERE_RADIUS_M, fetchImpl),
    rpzZoneAt(origin, fetchImpl),
  ]);

  // GPS is only good to ~10–20 m, so report the closest block plus anything
  // nearly as close (typically the other side of the street, or a corner).
  const nearest = blockfaces[0]?.distance ?? Infinity;
  const here = blockfaces.filter((b) => b.distance <= nearest + 20).slice(0, 4).map((b) => ({
    ...evaluateBlockface(b.attributes, now, { permitZone }),
    distanceMeters: Math.round(b.distance),
  }));

  const speech = [];
  if (!here.length) {
    speech.push("I couldn't find any city parking data for the street you're on. You may be off-street or outside Seattle.");
  } else {
    const byStreet = Map.groupBy(here, (b) => b.street);
    const streets = [...byStreet.keys()];
    speech.push(streets.length === 1 ? `You're on ${streets[0]}.` : `You're near ${streets.join(', and ')}.`);
    for (const [street, sides] of byStreet) {
      const prefix = streets.length > 1 ? `On ${street}, ` : '';
      const summaries = new Set(sides.map((s) => s.summary));
      if (sides.length > 1 && summaries.size === 1) {
        speech.push(`${prefix}${prefix ? 'both' : 'Both'} sides: ${sides[0].summary}.`);
      } else {
        for (const s of sides) {
          const label = s.side ? `${s.side} side` : 'this side';
          speech.push(`${prefix}${prefix ? label : capitalize(label)}: ${s.summary}.`);
        }
      }
    }
  }
  if (rpz) {
    const name = rpz.name ? `, ${rpz.name}` : '';
    speech.push(`You're inside Restricted Parking Zone ${rpz.zone}${name}${rpz.inEffect ? `, in effect ${rpz.inEffect}` : ''}.`);
  }

  return {
    location: origin,
    seattleTime: { weekday: now.weekday, time: formatClock(now.minutes) },
    rpzZone: rpz,
    blockfaces: here,
    speech: speech.join(' '),
  };
}

/**
 * Nearest blockfaces where the caller can legally park right now.
 *
 * @param {object} p
 * @param {number} [p.radiusMeters] search radius (default 500 m, max 1500 m)
 * @param {number} [p.limit] number of results (default 3)
 * @param {number} [p.minMinutes] only places where you can stay at least this long
 * @param {boolean} [p.freeOnly] skip places that cost money right now
 * @param {string} [p.permitZone] the caller's RPZ permit zone, if any
 */
export async function findParking({
  lat, lon, radiusMeters = DEFAULT_SEARCH_RADIUS_M, limit = 3, minMinutes, freeOnly = false,
  permitZone, date = new Date(), fetchImpl = fetch,
}) {
  const origin = { lat, lon };
  const now = seattleTime(date);
  const radius = Math.min(Math.max(radiusMeters, 50), MAX_SEARCH_RADIUS_M);
  const blockfaces = await nearbyBlockfaces(origin, radius, fetchImpl);

  const seen = new Set();
  const results = [];
  for (const b of blockfaces) {
    const r = evaluateBlockface(b.attributes, now, { permitZone });
    if (!r.canParkNow) continue;
    if (freeOnly && !r.freeNow) continue;
    if (minMinutes && r.timeLimitMinutes != null && r.timeLimitMinutes < minMinutes) continue;
    // Both sides of a block usually share rules; keep the closer one.
    const key = `${r.street}|${r.summary}`;
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({
      ...r,
      distanceMeters: Math.round(b.distance),
      direction: formatDistance(b.distance) === 'right here' ? null : compassDirection(origin, b.point),
      point: { lat: +b.point.lat.toFixed(6), lon: +b.point.lon.toFixed(6) },
      mapsUrl: `https://maps.apple.com/?daddr=${b.point.lat.toFixed(6)},${b.point.lon.toFixed(6)}&dirflg=w`,
    });
    if (results.length >= limit) break;
  }

  const speech = [];
  if (!results.length) {
    speech.push(
      `I couldn't find any street parking you can use right now within ${formatDistance(radius).replace('about ', '')}` +
        `${blockfaces.length ? ' that matches' : ''}. Try a wider search or a parking garage.`,
    );
  } else {
    // Results are sorted by distance, so both sides of one block are usually
    // adjacent; speak them as one sentence instead of repeating the street.
    const groups = [];
    for (const r of results) {
      const last = groups.at(-1);
      if (last && last[0].street === r.street) last.push(r);
      else groups.push([r]);
    }
    groups.forEach((group, i) => {
      const [first] = group;
      const where = first.direction ? `${formatDistance(first.distanceMeters)} ${first.direction}` : 'right here';
      const lead = i === 0 ? 'The closest spot is' : i === 1 ? 'Next is' : 'Or';
      if (group.length === 1) {
        const side = first.side ? `, ${first.side} side` : '';
        speech.push(`${lead} ${where}, on ${first.street}${side}: ${first.summary}.`);
      } else {
        const sides = group.map((r) => `${r.side ? `${r.side} side` : 'one side'}, ${r.summary}`).join('; ');
        speech.push(`${lead} ${where}, on ${first.street}: ${sides}.`);
      }
    });
  }

  return {
    location: origin,
    seattleTime: { weekday: now.weekday, time: formatClock(now.minutes) },
    searchRadiusMeters: radius,
    results,
    speech: speech.join(' '),
  };
}
