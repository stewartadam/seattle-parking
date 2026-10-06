import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describeHere, evaluateBlockface, findParking, formatDistance, formatStreet } from '../src/parking.js';

const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));

// Serves recorded City of Seattle responses (14th Ave E & E Republican, Capitol Hill).
function fakeFetch(url) {
  const body = url.includes('Restricted_Parking_Zone_Areas')
    ? fixture('capitol-hill-rpz.json')
    : fixture('capitol-hill-blockfaces.json');
  return Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
}

const weekday = (minutes) => ({ weekday: 'Tue', dayType: 'wkd', isWeekday: true, minutes });

const paid = {
  UNITDESC: 'BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST',
  SIDE: 'W',
  PARKING_CATEGORY: 'Paid Parking',
  PARKING_TIME_LIMIT: 120,
  START_TIME_WKD: '08AM',
  END_TIME_WKD: '10PM',
  WKD_RATE1: 1, WKD_START1: 480, WKD_END1: 659,
  WKD_RATE2: 2.5, WKD_START2: 660, WKD_END2: 1319,
};

test('formatStreet expands abbreviations for speech', () => {
  assert.equal(formatStreet(paid.UNITDESC), 'Broadway East between East Olive Way and East Thomas Street');
  assert.equal(formatStreet('11TH AVE NE BETWEEN NE 45TH ST AND NE 47TH ST'), '11th Avenue Northeast between Northeast 45th Street and Northeast 47th Street');
});

test('formatDistance uses feet then miles', () => {
  assert.equal(formatDistance(10), 'right here');
  assert.equal(formatDistance(90), 'about 300 feet');
  assert.equal(formatDistance(800), 'about 0.5 miles');
});

test('paid parking reports the current rate and limit', () => {
  const r = evaluateBlockface(paid, weekday(12 * 60));
  assert.equal(r.canParkNow, true);
  assert.equal(r.freeNow, false);
  assert.equal(r.ratePerHour, 2.5);
  assert.equal(r.timeLimitMinutes, 120);
  assert.equal(r.summary, 'paid, $2.50 an hour until 10 PM, 2-hour limit');
  assert.equal(r.side, 'west');
});

test('paid parking is free outside enforcement hours', () => {
  assert.equal(evaluateBlockface(paid, weekday(23 * 60)).summary, 'free now, paid parking ended at 10 PM');
  const early = evaluateBlockface(paid, weekday(7 * 60));
  assert.equal(early.summary, 'free until 8 AM, then paid');
  assert.equal(early.freeNow, true);
  assert.equal(early.timeLimitMinutes, 60);
  const sunday = evaluateBlockface(paid, { weekday: 'Sun', dayType: 'sun', isWeekday: false, minutes: 720 });
  assert.equal(sunday.summary, 'paid parking area, but free today');
});

test('peak-hour tow-away overrides other rules on weekdays only', () => {
  const a = { ...paid, PEAK_HOUR: '4-6PM' };
  const rush = evaluateBlockface(a, weekday(17 * 60));
  assert.equal(rush.canParkNow, false);
  assert.match(rush.summary, /tow-away zone until 6 PM/);

  const before = evaluateBlockface(a, weekday(15 * 60));
  assert.equal(before.canParkNow, true);
  assert.equal(before.timeLimitMinutes, 60);
  assert.match(before.summary, /becomes a tow-away zone at 4 PM/);

  const saturday = evaluateBlockface(a, { weekday: 'Sat', dayType: 'sat', isWeekday: false, minutes: 17 * 60 });
  assert.equal(saturday.canParkNow, true);
});

test('RPZ blocks honour a matching permit', () => {
  const a = { UNITDESC: '14TH AVE E BETWEEN E REPUBLICAN ST AND E MERCER ST', SIDE: 'E', PARKING_CATEGORY: 'Restricted Parking Zone', RPZ_ZONE: '4', PARKING_TIME_LIMIT: 120 };
  assert.equal(evaluateBlockface(a, weekday(600)).summary, 'free, 2-hour limit without a zone 4 permit');
  const withPermit = evaluateBlockface(a, weekday(600), { permitZone: '4' });
  assert.equal(withPermit.timeLimitMinutes, null);
  assert.equal(withPermit.summary, 'free with your zone 4 permit, no time limit');
});

test('no-parking blocks are never suggested', () => {
  assert.equal(evaluateBlockface({ PARKING_CATEGORY: 'No Parking Allowed' }, weekday(600)).canParkNow, false);
});

test('describeHere summarises the street and RPZ zone', async () => {
  const result = await describeHere({ lat: 47.6239, lon: -122.3145, date: new Date('2026-10-06T17:00:00Z'), fetchImpl: fakeFetch });
  assert.match(result.speech, /^You're on 14th Avenue East between East Republican Street and East Mercer Street\./);
  assert.match(result.speech, /Restricted Parking Zone 4, Capitol Hill/);
  assert.ok(result.blockfaces.length >= 1);
  assert.equal(result.rpzZone.zone, '4');
});

test('findParking returns legal spots sorted by distance and respects filters', async () => {
  const date = new Date('2026-10-06T17:00:00Z'); // Tuesday 10 AM
  const result = await findParking({ lat: 47.6239, lon: -122.3145, limit: 5, date, fetchImpl: fakeFetch });
  assert.ok(result.results.length > 0);
  assert.ok(result.results.every((r) => r.canParkNow));
  const distances = result.results.map((r) => r.distanceMeters);
  assert.deepEqual(distances, [...distances].sort((a, b) => a - b));
  assert.match(result.speech, /^The closest spot is/);
  assert.match(result.results[0].mapsUrl, /^https:\/\/maps\.apple\.com\/\?daddr=/);

  const long = await findParking({ lat: 47.6239, lon: -122.3145, minMinutes: 240, date, fetchImpl: fakeFetch });
  assert.ok(long.results.every((r) => r.timeLimitMinutes == null || r.timeLimitMinutes >= 240));
});
