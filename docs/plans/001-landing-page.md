# Landing page and pitch deck

Fixes #12

## Outcome

A public site at `landing/`, deployed to Vercel, that explains Show Up to a prospective
user in one screen and captures a waitlist email — plus a pitch deck at `/deck` that lives
in version control rather than in a Keynote file on somebody's laptop.

## Why one app and not two

The landing page and the deck say the same things to different audiences at different
speeds. Sharing a repo means they share the palette, the type scale, and the copy — so the
deck cannot drift into describing a product the landing page no longer claims. Vercel
deploys one project with `landing/` as its root directory; the Flutter app and the
Supabase/ClickHouse layers are untouched by the build.

## Design direction

The risk worth taking here is refusing to look like an app landing page, because the
product is explicitly not a marketplace and should not borrow a marketplace's visual
language. No screenshots of the UI, no phone mockups, no faces — the product deliberately
has no face photos, and a landing page full of stock portraits would contradict the pitch
on sight.

**Signature: the table.** The hero is a table with six seats that fill one at a time as
the page loads. Each seat carries an interest rather than a name or a face — `climbing`,
`records`, `sourdough` — because that is genuinely what the matcher groups on. One seat
reads `you`. The caption is the thesis: everyone here came alone. This renders the product
in one object, and it is the only place the design spends any boldness.

**Palette — candlelight, not dark mode.** The app's warm near-black and terracotta already
imply a lit room at night; the waiting screen is literally a candle. Pushing that further
separates it from the generic dark-background-plus-bright-accent look: warm-black ground,
ember and amber as two warm lights, and cream rather than pure white for text, because pure
white reads as UI chrome and cream reads as lamplight.

| Token | Value | Role |
|---|---|---|
| `ink` | `#12100E` | the room |
| `surface` | `#1C1815` | raised panels, the tabletop |
| `ember` | `#E8734A` | primary accent, carried over from the app |
| `amber` | `#F0B27A` | secondary warm light |
| `cream` | `#F2E9DE` | body text |
| `smoke` | `#8A7F76` | secondary text |

**Type.** Fraunces for display — a warm serif with a wonk axis, so it reads handmade rather
than corporate, and it is not the Playfair/Instrument Serif pairing that every AI-generated
page arrives at. Instrument Sans for body. Space Mono, used sparingly at small sizes, for
eyebrow labels and the deck's figures, borrowing the register of a reservation card.

**Structure.** Sections are not numbered except where the content is genuinely a sequence
(how it works), because numbering something that is not ordered is decoration pretending to
be information.

## Plan

1. Scaffold Next.js (App Router, TypeScript, Tailwind v4) in `landing/`, with the design
   tokens defined once in `globals.css` and consumed everywhere.
2. Build the landing route: hero table, the problem, how it works, the assigned question,
   what the product refuses to do, the mutual-contact ending, waitlist.
3. Build the deck route: slide-per-viewport, keyboard navigable, degrading to a scrollable
   document when JavaScript does not run.
4. Waitlist route handler inserting into a `waitlist` table via the anon key. Write the
   migration; do not apply it. The form reports an honest error while the table is absent.
5. Verify: production build, a pass at 320px, keyboard-only navigation of the deck.

## Non-goals

- Applying the migration to the shared remote Supabase project. That is a deliberate,
  separate step and another branch explicitly forbids doing it from a feature branch.
- Buying or attaching the domain. Site metadata reads from one constant in `lib/site.ts`
  so the swap is a one-line change once the name exists.
- Any change to `app/`, `supabase/functions/`, or `clickhouse/`.
