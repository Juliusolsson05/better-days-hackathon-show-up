# Port the approved UI mock to Flutter

Issue: #25

## Source of truth

The Git submodule at `refernce/` will pin the exact mock commit. Its rendered mobile
experience is authoritative for UI hierarchy, visual styling, screen transitions, labels,
and interaction placement. The existing Flutter repositories and `AppState` remain
authoritative for authentication, profile submission, group data, voting, messages,
attendance, reflection, and mutual contacts.

This separation matters: copying React state into Flutter would produce a convincing dead
prototype, while retaining the old Flutter navigation would fail the request for a 1x1 UX
port. The implementation must translate mock intent onto existing production boundaries.

## Reference rules to measure and preserve

1. The visible phone canvas is 390px wide, full-height, with a sage background and subtle
   grain. Content uses 20px horizontal gutters except chat, which uses 16px.
2. Display copy uses the mock's serif hierarchy; body and controls use its compact sans
   hierarchy. Font family, size, weight, line height, and letter spacing are measured from
   the rendered reference rather than approximated from brand adjectives.
3. Cards use a black 1px outline and 16-24px radii. Elevation is subtle and reserved for
   tappable content. Primary controls are lime full pills.
4. Real member and venue photography carries visual hierarchy. Image aspect ratio,
   object-fit crop, overlay, border, and corner treatment must match the reference.
5. Navigation state is structural: onboarding has three internal steps; the product shell
   has Explore and My Groups tabs; each group has a hub before chat; info and post-meetup
   prompts use bottom sheets.
6. Every reference state must remain reachable from mock data without waiting for real
   time or a cloud backend.

## Route and component mapping

| Reference | Flutter destination |
|---|---|
| `Onboarding` steps 0-2 | rebuilt `OnboardingScreen`, preserving profile submission at completion |
| `Explore` | new Explore tab using mock meetup/table data |
| `MyGroups` | new My Groups tab using the current and historical group presentation |
| `GroupHub` | new group hub between list and chat |
| `GroupChat` | rebuilt chat chrome and message composition over `Repository.watchMessages` |
| `VenueVoteCard` | rebuilt vote message over current vote repository methods |
| venue detail route | Flutter venue-detail screen with reference photo composition and MapKit |
| member routes/cards | reference member cards and group members presentation, without adding a standalone global profile |
| `GroupInfoSheet` | modal Flutter bottom sheet with members and mutual contacts |
| `AssignedQuestionCard` | in-chat private assignment card/sheet using current assignment data |
| recap routes | rebuilt `AfterFlow` and contact result presentation |
| `TabBar` | persistent Flutter product shell navigation |

## Implementation sequence

1. Add the mock as the `refernce/` Git submodule and record its pinned commit.
2. Run the reference at 390px, capture every primary route/state, and record measurable
   values plus screenshot filenames. Rebuild-from-rules review must reproduce the same
   composition without relying on vague visual memory.
3. Import the pinned photography into Flutter's asset bundle without modifying the
   submodule. Establish fonts, palette, type, shapes, and shared image/card primitives.
4. Rebuild onboarding and the persistent product shell, then route Explore, My Groups,
   and Group Hub against existing Flutter state.
5. Rebuild chat, voting, question, info, members, venue, and recap surfaces.
6. Add navigation and rendering tests that protect the new UX contracts. Preserve tests
   for backend gating and map fallback where still applicable.
7. Render Flutter reference states at iPhone dimensions and compare against the mock.
   Iterate on hierarchy, spacing, type, crop, and component states before device build.
8. Run analyzer/tests, review the complete diff, push a fully documented PR, and install a
   release build on the connected iPhone. Do not merge without explicit approval.

## Risks and constraints

- The mock uses Fraunces and Karla but does not currently vendor font files. Exact font
  parity requires bundling pinned font assets or choosing a measured system fallback. This
  decision must be made before tuning text metrics because font substitution changes every
  wrap and vertical rhythm.
- The mock includes navigation and historical-group concepts beyond current `Phase`. These
  belong in presentation state unless a durable backend contract already exists; this UI
  port must not invent schema work.
- Flutter platform views cannot be pixel-identical to a static web image. MapKit remains
  native, while its container, surrounding details, and navigation match the reference.
- The submodule path intentionally preserves the user-provided spelling `refernce/`.
