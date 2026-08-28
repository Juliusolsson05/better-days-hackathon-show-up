// Stance flags come from an LLM, not a controlled picker. The model generally emits terse
// snake_case values, but harmless wording changes such as "Heavy Drinking", "veganism", or
// an accidental repeated `stance:` prefix must not silently disable the safety filter. Keep
// canonicalization next to the conflict graph so every caller compares the same vocabulary.
const STANCE_ALIASES: Record<string, string> = {
  animal_rights_activist: "animal_rights",
  animal_rights_activism: "animal_rights",
  anti_religion: "militant_atheist",
  bar_crawling: "bar_crawl",
  drinking_heavily: "heavy_drinking",
  heavy_drinker: "heavy_drinking",
  meat_eater: "meat_eating",
  meat_lover: "meat_eating",
  religion: "religious",
  sobriety: "sober",
  sober_lifestyle: "sober",
  veganism: "vegan",
  vegetarianism: "vegetarian",
};

// Declare each incompatibility once and build both directions below. A hand-maintained map
// previously made `hunting -> vegetarian` unsafe in one seed order because the reverse edge
// did not exist; matching order is arbitrary, so conflict membership must be symmetric.
const CONFLICT_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ["vegan", "hunting"],
  ["vegan", "bbq"],
  ["vegan", "steakhouse"],
  ["vegan", "meat_eating"],
  ["vegetarian", "hunting"],
  ["animal_rights", "hunting"],
  ["sober", "heavy_drinking"],
  ["sober", "bar_crawl"],
  ["religious", "militant_atheist"],
];

const conflicts = new Map<string, Set<string>>();
for (const [left, right] of CONFLICT_PAIRS) {
  addConflict(left, right);
  addConflict(right, left);
}

function addConflict(from: string, to: string): void {
  const opposed = conflicts.get(from) ?? new Set<string>();
  opposed.add(to);
  conflicts.set(from, opposed);
}

/** Canonicalize either a raw Claude stance flag or an already-prefixed ClickHouse tag. */
export function normalizeStance(value: string): string {
  const normalized = value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toLowerCase()
    .replace(/^(?:stance\s*:\s*)+/, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return STANCE_ALIASES[normalized] ?? normalized;
}

/** Return only stance tags, in the exact canonical representation persisted by the API. */
export function normalizeStanceTags(tags: string[]): string[] {
  const normalized = new Set<string>();
  for (const tag of tags) {
    // Ordinary interest tags share this array. Treating every value as a stance would turn
    // interests such as "bbq" into political filters and incorrectly shrink the match pool.
    if (!/^\s*stance\s*:/i.test(tag)) continue;
    const stance = normalizeStance(tag);
    if (stance) normalized.add(`stance:${stance}`);
  }
  return [...normalized];
}

/** Expand the stances in a profile into every canonical stance it cannot be paired with. */
export function opposingStances(tags: string[]): string[] {
  const blocked = new Set<string>();
  for (const tag of normalizeStanceTags(tags)) {
    for (const opposed of conflicts.get(tag.slice("stance:".length)) ?? []) {
      blocked.add(`stance:${opposed}`);
    }
  }
  return [...blocked].sort();
}

/**
 * The ClickHouse predicate is a cheap canonical-tag fast path, but old rows and LLM wording
 * drift can still contain non-canonical values. This comparison is therefore the final
 * authority before a candidate joins a group.
 */
export function haveOpposingStances(left: string[], right: string[]): boolean {
  const blocked = new Set(opposingStances(left));
  return normalizeStanceTags(right).some((tag) => blocked.has(tag));
}
