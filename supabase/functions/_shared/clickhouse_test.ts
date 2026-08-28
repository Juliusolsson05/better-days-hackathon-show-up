import { assertEquals, assertThrows } from "jsr:@std/assert@1";

// This static import is the regression test's most important assertion. CI deliberately does not
// provide production ClickHouse credentials; eager module-level validation would throw before
// Deno can register either this test or an Edge Function's authentication handler.
import { resolveClickHouseConfig } from "./clickhouse.ts";

Deno.test("resolves ClickHouse credentials only when a caller asks for them", () => {
  const values: Record<string, string> = {
    CLICKHOUSE_URL: "https://clickhouse.example.test",
    CLICKHOUSE_USER: "test-user",
    CLICKHOUSE_PASSWORD: "test-password",
  };

  assertEquals(resolveClickHouseConfig((key) => values[key]), {
    url: values.CLICKHOUSE_URL,
    user: values.CLICKHOUSE_USER,
    password: values.CLICKHOUSE_PASSWORD,
  });
});

Deno.test("missing-secret errors name the repair target without exposing values", () => {
  assertThrows(
    () => resolveClickHouseConfig(() => undefined),
    Error,
    "missing secret CLICKHOUSE_URL",
  );
});
