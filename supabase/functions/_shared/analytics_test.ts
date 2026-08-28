import { assert, assertFalse } from "jsr:@std/assert@1";

import { COHESION_QUERY } from "./analytics.ts";

Deno.test("cohesion counts formed groups rather than per-member formation events", () => {
  // run-matching emits group_formed once for every member because those rows also feed each
  // person's funnel. A six-person group therefore creates six event rows by design. The
  // dashboard labels this aggregate as groups, so count() inflates the chart by 4-6x and makes
  // the stage metric confidently wrong even though both the emitter and query succeed.
  assert(COHESION_QUERY.includes("uniqExact(group_id) AS n"));
  assertFalse(COHESION_QUERY.includes("count() AS n"));
});
