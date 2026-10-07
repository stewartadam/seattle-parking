import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatClock, formatLimit, parseClock, parsePeakHours, seattleTime } from '../src/schedule.js';

test('parseClock handles SDOT clock strings', () => {
  assert.equal(parseClock('08AM'), 480);
  assert.equal(parseClock('10PM'), 1320);
  assert.equal(parseClock('12AM'), 0);
  assert.equal(parseClock('12PM'), 720);
  assert.equal(parseClock('8:30AM'), 510);
  assert.equal(parseClock(null), null);
  assert.equal(parseClock('nonsense'), null);
});

test('parsePeakHours splits multiple windows', () => {
  assert.deepEqual(parsePeakHours('7-9AM'), [[420, 540]]);
  assert.deepEqual(parsePeakHours('7-9AM 4-6PM'), [[420, 540], [960, 1080]]);
  assert.deepEqual(parsePeakHours('11-1PM'), [[660, 780]]);
  assert.deepEqual(parsePeakHours(null), []);
});

test('formatClock and formatLimit read naturally', () => {
  assert.equal(formatClock(480), '8 AM');
  assert.equal(formatClock(1290), '9:30 PM');
  assert.equal(formatClock(720), 'noon');
  assert.equal(formatClock(1440), 'midnight');
  assert.equal(formatLimit(120), '2-hour');
  assert.equal(formatLimit(30), '30-minute');
  assert.equal(formatLimit(90), '1.5-hour');
});

test('seattleTime converts to Pacific time and day type', () => {
  // 2026-10-06T08:00Z is Tuesday 1:00 AM PDT.
  assert.deepEqual(seattleTime(new Date('2026-10-06T08:00:00Z')), { weekday: 'Tue', dayType: 'wkd', isWeekday: true, minutes: 60 });
  // 2026-10-11T19:30Z is Sunday 12:30 PM PDT.
  assert.equal(seattleTime(new Date('2026-10-11T19:30:00Z')).dayType, 'sun');
});
