# Restyle the complete mobile flow

Issue: #19

## Design read

This is a native consumer meetup app for people who feel friction about arriving alone.
The interface should feel calm, direct, friendly, and unusually legible rather than like
a nightlife app or a generic dark-mode prototype. The supplied Wise-inspired language is
adapted, not copied: lime is the single action accent, sage is the page canvas, white is
the content surface, and warm near-black carries the hierarchy.

Design dials: variance 6, motion 3, density 4. Mobile product flows benefit from a little
editorial hierarchy, but predictable controls and low motion matter more than expressive
web composition here.

## Measured rules

1. Primary action color is `#9FE870`; it appears on enabled primary actions, selection
   emphasis, progress, and focus only.
   Test: no orange accent or unrelated saturated action color remains in product UI.
2. Page canvas is sage `#E8EBE6`; content cards are white `#FFFFFF`; pale green
   `#E2F6D5` is reserved for positive or selected surfaces.
   Test: cards remain visibly distinct without relying on shadows.
3. Default ink is `#0E0F0C`, body is `#454745`, muted copy is `#686B68` or darker where
   needed for accessible contrast.
   Test: no visible copy depends on white opacity from the old dark theme.
4. Cards use 24px corners, inputs use 12px corners, and action buttons are pill-shaped.
   Test: every custom container follows one of those three documented roles.
5. Screen headlines use a heavy system sans substitute at 32-40px where space allows;
   utility headings use 20-24px semibold; body remains 16px with a 1.45-1.5 line height.
   Test: no screen invents an isolated type scale outside the semantic theme.
6. Buttons are at least 48px tall and labels remain on one line.
   Test: every primary action meets the touch target and survives iPhone-width layout.
7. Motion is limited to feedback and state transitions already provided by Flutter.
   Test: no perpetual or decorative animation is introduced.

## Implementation

1. Replace the temporary theme with semantic color, spacing, shape, typography, and
   component tokens. Add small shared primitives only where they remove repeated visual
   decisions from feature screens.
2. Restyle the entry flow: authentication, onboarding, photo/avatar controls, interests,
   availability, loading, validation, and waiting state.
3. Restyle the core product surface: chat header/messages/composer, venue vote, group info,
   MapKit framing and directions, and the private-question sheet.
4. Restyle the post-meetup flow: progress, reflection, attendance, mutual contacts, empty
   state, and contact cards.
5. Add focused tests for the design-system contract and key render states. Run formatter,
   analyzer, tests, and diff checks.
6. Review every visible string and color reference, open a fully documented PR, and keep it
   unmerged until explicitly approved.
7. Build release mode, install it on the connected iPhone, and launch it for visual review.

## Constraints and risks

- Wise Sans is proprietary, so the implementation uses the iOS/system sans stack with
  heavy display weights. Adding a network font would make launch and offline demos less
  reliable for little gain.
- Apple Maps remains a native platform view. Its map styling is system-owned; only its
  frame and surrounding controls can be made token-consistent.
- Existing UI tests locate text and controls, so styling must not change product semantics
  merely to make tests convenient.
- The demo uses release builds on the physical iPhone. Visual review must happen after the
  complete flow passes the fast checks, not after every small styling edit.
