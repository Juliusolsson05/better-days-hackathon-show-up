import { assertEquals } from "jsr:@std/assert@1";
import { canInvokeMatching } from "./matching_auth.ts";

const env = {
  serviceRoleKey: "service-role-secret",
  anonKey: "public-anon-jwt",
  matchingJobSecret: "a-narrow-operator-secret-over-32-chars",
};

Deno.test("trusted cron can invoke matching with the service credential", () => {
  assertEquals(
    canInvokeMatching({
      ...env,
      authorization: "Bearer service-role-secret",
      operatorSecret: "",
    }),
    true,
  );
});

Deno.test("browser operator needs both public JWT and narrow job secret", () => {
  assertEquals(
    canInvokeMatching({
      ...env,
      authorization: "Bearer public-anon-jwt",
      operatorSecret: "a-narrow-operator-secret-over-32-chars",
    }),
    true,
  );
  assertEquals(
    canInvokeMatching({
      ...env,
      authorization: "Bearer public-anon-jwt",
      operatorSecret: "wrong",
    }),
    false,
  );
});

Deno.test("a matching secret cannot replace the gateway JWT", () => {
  assertEquals(
    canInvokeMatching({
      ...env,
      authorization: "Bearer a-narrow-operator-secret-over-32-chars",
      operatorSecret: "a-narrow-operator-secret-over-32-chars",
    }),
    false,
  );
});
