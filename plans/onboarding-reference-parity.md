# Restore onboarding parity with the approved reference

Issue: #25

## Problem

The Flutter onboarding flow does not visually or behaviorally match the pinned approved mock in
`refernce/`. Because onboarding is the first product surface, this mismatch makes the merged UI
rewrite look absent even though the later reference shell is present.

## Plan

1. Render every onboarding step from the pinned reference at the authoritative 390 px phone width
   and record the hierarchy, copy, spacing, typography, colors, control states, and transitions.
2. Render the equivalent Flutter states at iPhone dimensions and identify the concrete deltas.
3. Rebuild the Flutter onboarding presentation against the existing `AppState` submission contract,
   keeping backend behavior unchanged while matching the approved reference.
4. Add focused widget coverage for the navigation and interaction contracts that caused the visible
   regression.
5. Run formatting, analysis, tests, and side-by-side visual verification; then build and install the
   corrected release on the connected iPhone.
6. Update Issue #25 and open a reviewable PR with the evidence, verification, and remaining limits.

## Acceptance criteria

- All three onboarding steps reproduce the pinned reference's visible hierarchy and copy at 390 px.
- Back, continue, skip, selection, and completion behavior match the reference without bypassing the
  existing profile-submission boundary.
- The implementation remains usable with keyboard and safe-area insets on the physical iPhone.
- Automated tests protect the step sequence and submission behavior.
- The final release build is visually checked and installed on the connected device.
