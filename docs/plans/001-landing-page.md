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

**Signature: heavy editorial type.** The original table illustration repeated the hero in a
less clear form and consumed the space where signup should be, so it was removed after visual
review. The brand moment is now one compact, very heavy headline paired directly with the
waitlist form. The assigned-question card becomes the memorable object because it is genuine
product output rather than a decorative diagram.

**Palette — lime, sage, white, ink.** A Wise-inspired surface system alternates pale sage
bands and white content, with near-black used for one polarity-flipped trust section and the
footer. Lime is the sole identity colour and is reserved for primary action and emphasis;
introducing another accent would weaken the conversion signature.

| Token | Value | Role |
|---|---|---|
| `primary` | `#9FE870` | primary action and identity |
| `primary-pale` | `#E2F6D5` | supportive cards and badges |
| `canvas-soft` | `#E8EBE6` | hero and alternating bands |
| `canvas` | `#FFFFFF` | content and cards |
| `ink` | `#0E0F0C` | display copy and dark surfaces |
| `body` | `#454745` | readable secondary copy |

**Type.** Wise Sans is proprietary, so Inter performs both roles honestly: weight 900 for
brand statements and 400/600 for utility and body. The role separation matters more than
adding a lookalike font with its own personality. Space Mono remains only for the one
technical scoring formula in the deck.

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
