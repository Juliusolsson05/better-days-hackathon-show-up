# Make production structurally real-only

Issue: #45

## Plan

1. Make the production app receive a real repository from its entrypoint instead of choosing a
   backend at runtime.
2. Remove reference-only phases, routes, and demo controls from the production router and state.
3. Move static review UI behind a separate explicit entrypoint that is never imported by
   production.
4. Fail closed on missing production configuration and make production telemetry privacy-safe.
5. Add source-boundary and behavior tests, run the full Flutter gate, and open a stacked PR on the
   production-lifecycle branch.

## Acceptance criteria

- Production cannot construct `MockRepository` or route to `ProductShell`.
- Reference fixtures remain available only through `main_reference.dart`.
- `Phase.home`, `referenceUiPreview`, and release demo controls disappear from production state.
- Missing Supabase configuration aborts before `runApp`.
- Production Sentry sends no default PII, screenshot, or view hierarchy.
