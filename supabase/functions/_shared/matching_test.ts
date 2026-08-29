import { assertEquals } from "jsr:@std/assert@1";
import {
  blockedPairKey,
  haveBlockedRelationship,
  haveOpposingStances,
  normalizeStance,
  normalizeStanceTags,
  opposingStances,
} from "./matching.ts";

Deno.test("normalizes Claude-like stance spellings without touching interests", () => {
  assertEquals(normalizeStance(" stance: Heavy-Drinking "), "heavy_drinking");
  assertEquals(normalizeStance("VEGANISM"), "vegan");
  assertEquals(
    normalizeStanceTags(["food", " Stance: Veganism ", "stance:VEGAN"]),
    ["stance:vegan"],
  );
});

Deno.test("expands conflicts symmetrically regardless of which profile is the seed", () => {
  assertEquals(
    haveOpposingStances(["stance:vegetarian"], ["stance:Hunting"]),
    true,
  );
  assertEquals(
    haveOpposingStances(["stance:hunting"], ["stance:Vegetarianism"]),
    true,
  );
  assertEquals(
    haveOpposingStances(["stance:bar crawling"], ["stance:SOBRIETY"]),
    true,
  );
  assertEquals(
    haveOpposingStances(["stance:sober"], ["stance:Bar Crawling"]),
    true,
  );
});

Deno.test("returns the canonical blocked tags used by the ClickHouse fast path", () => {
  assertEquals(opposingStances(["stance: Veganism"]), [
    "stance:bbq",
    "stance:hunting",
    "stance:meat_eating",
    "stance:steakhouse",
  ]);
});

Deno.test("a one-way block excludes the pair in either matching order", () => {
  const pairs = new Set([blockedPairKey("user-b", "user-a")]);
  assertEquals(haveBlockedRelationship(pairs, "user-a", "user-b"), true);
  assertEquals(haveBlockedRelationship(pairs, "user-b", "user-a"), true);
  assertEquals(haveBlockedRelationship(pairs, "user-a", "user-c"), false);
});

Deno.test("does not infer a conflict from ordinary topic tags", () => {
  assertEquals(haveOpposingStances(["vegan"], ["hunting"]), false);
  assertEquals(haveOpposingStances(["stance:vegan"], ["hiking"]), false);
});
