// Event instants derived from product-local schedule names.
//
// The edge runtime uses UTC, while "Friday evening" is a wall-clock promise in San Francisco.
// Adding a hard-coded seven hours works only during daylight saving time and silently moves every
// winter meetup to 6pm. This conversion asks Intl for the actual IANA timezone offset at the
// target date, so DST changes are data rather than application branches.

const SLOT = {
  fri_eve: { weekday: 5, hour: 19 },
  sat_day: { weekday: 6, hour: 13 },
  sat_eve: { weekday: 6, hour: 19 },
  sun_day: { weekday: 0, hour: 13 },
} as const;

export function nextSlot(
  slot: string,
  now = new Date(),
  timeZone = 'America/Los_Angeles',
): string {
  const desired = SLOT[slot as keyof typeof SLOT];
  if (!desired) throw new Error(`unknown availability slot: ${slot}`);

  const localNow = localParts(now, timeZone);
  const nominalToday = Date.UTC(localNow.year, localNow.month - 1, localNow.day);
  const currentWeekday = new Date(nominalToday).getUTCDay();
  const daysAhead = (desired.weekday - currentWeekday + 7) % 7;
  let nominalTarget = new Date(nominalToday + daysAhead * 86_400_000);
  let candidate = localWallClockToUtc(
    nominalTarget.getUTCFullYear(),
    nominalTarget.getUTCMonth() + 1,
    nominalTarget.getUTCDate(),
    desired.hour,
    timeZone,
  );

  // "Next Friday" means the upcoming occurrence, never a timestamp earlier in the same day.
  // Recompute seven days later instead of adding 168 real hours: a DST transition can make a
  // local week 167 or 169 hours while the promised wall-clock hour remains unchanged.
  if (candidate.getTime() <= now.getTime()) {
    nominalTarget = new Date(nominalTarget.getTime() + 7 * 86_400_000);
    candidate = localWallClockToUtc(
      nominalTarget.getUTCFullYear(),
      nominalTarget.getUTCMonth() + 1,
      nominalTarget.getUTCDate(),
      desired.hour,
      timeZone,
    );
  }

  return candidate.toISOString();
}

function localWallClockToUtc(
  year: number,
  month: number,
  day: number,
  hour: number,
  timeZone: string,
): Date {
  const desiredAsUtc = Date.UTC(year, month - 1, day, hour);
  let guess = desiredAsUtc;

  // Formatting a guessed instant tells us what wall clock that instant represents. Correct the
  // delta and repeat because the first guess can fall on the opposite side of a DST boundary.
  for (let i = 0; i < 3; i++) {
    const actual = localParts(new Date(guess), timeZone);
    const actualAsUtc = Date.UTC(
      actual.year,
      actual.month - 1,
      actual.day,
      actual.hour,
      actual.minute,
    );
    const correction = desiredAsUtc - actualAsUtc;
    guess += correction;
    if (correction === 0) break;
  }
  return new Date(guess);
}

function localParts(at: Date, timeZone: string) {
  const fields = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(at);
  const value = (name: Intl.DateTimeFormatPartTypes) =>
    Number(fields.find((part) => part.type === name)?.value);
  return {
    year: value('year'),
    month: value('month'),
    day: value('day'),
    hour: value('hour'),
    minute: value('minute'),
  };
}
