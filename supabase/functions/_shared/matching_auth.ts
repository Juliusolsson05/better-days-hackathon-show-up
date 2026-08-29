export interface MatchingAuthInput {
  authorization: string;
  operatorSecret: string;
  serviceRoleKey?: string;
  anonKey?: string;
  matchingJobSecret?: string;
}

/**
 * Cron may authenticate as the service role inside the trusted backend. Browser operators use the
 * public anon JWT plus a narrow matching-only secret; the service-role key must never cross into
 * localStorage or any other browser surface.
 */
export function canInvokeMatching(input: MatchingAuthInput): boolean {
  if (
    input.serviceRoleKey &&
    input.authorization === `Bearer ${input.serviceRoleKey}`
  ) return true;

  return Boolean(
    input.anonKey &&
      input.matchingJobSecret &&
      input.matchingJobSecret.length >= 32 &&
      input.authorization === `Bearer ${input.anonKey}` &&
      input.operatorSecret === input.matchingJobSecret,
  );
}
