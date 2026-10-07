// Time helpers. All parking rules are evaluated in Seattle local time.

const TZ = 'America/Los_Angeles';

/**
 * Seattle-local view of a Date: day type used by SDOT's schedule columns
 * ("wkd" Mon–Fri, "sat", "sun"), whether it's a weekday, and minutes since
 * midnight.
 */
export function seattleTime(date = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: TZ,
      weekday: 'short',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(date)
      .map((p) => [p.type, p.value]),
  );
  const weekday = parts.weekday; // "Mon", "Tue", ...
  const dayType = weekday === 'Sat' ? 'sat' : weekday === 'Sun' ? 'sun' : 'wkd';
  return {
    weekday,
    dayType,
    isWeekday: dayType === 'wkd',
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
  };
}

/** Parse SDOT clock strings like "08AM", "10PM", "8:30AM" into minutes since midnight. */
export function parseClock(text) {
  if (!text) return null;
  const m = /^\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)\s*$/i.exec(text);
  if (!m) return null;
  let hour = Number(m[1]) % 12;
  if (m[3].toUpperCase() === 'PM') hour += 12;
  return hour * 60 + Number(m[2] ?? 0);
}

/**
 * Parse peak-hour descriptions like "7-9AM", "4-6PM" or "7-9AM 4-6PM" into
 * [startMinutes, endMinutes) windows.
 */
export function parsePeakHours(text) {
  if (!text) return [];
  const windows = [];
  const re = /(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s*-\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)/gi;
  for (const m of text.matchAll(re)) {
    const endMer = m[6].toUpperCase();
    const end = parseClock(`${m[4]}:${m[5] ?? '00'}${endMer}`);
    let start = parseClock(`${m[1]}:${m[2] ?? '00'}${(m[3] ?? endMer).toUpperCase()}`);
    // "11-1PM" style ranges cross noon; the start is really AM.
    if (!m[3] && start > end) start -= 12 * 60;
    windows.push([start, end]);
  }
  return windows;
}

/** Format minutes since midnight as spoken time, e.g. 480 -> "8 AM", 1290 -> "9:30 PM". */
export function formatClock(minutes) {
  const m = ((minutes % 1440) + 1440) % 1440;
  const h24 = Math.floor(m / 60);
  const min = m % 60;
  if (h24 === 0 && min === 0) return 'midnight';
  if (h24 === 12 && min === 0) return 'noon';
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  const mer = h24 < 12 ? 'AM' : 'PM';
  return min ? `${h12}:${String(min).padStart(2, '0')} ${mer}` : `${h12} ${mer}`;
}

/** Format a time limit for use before a noun: "2-hour", "30-minute", "1.5-hour". */
export function formatLimit(minutes) {
  if (minutes < 60) return `${minutes}-minute`;
  const hours = minutes / 60;
  return `${Number.isInteger(hours) ? hours : hours.toFixed(1)}-hour`;
}
