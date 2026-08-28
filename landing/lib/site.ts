/**
 * Everything about the site that changes when the domain does.
 *
 * The domain is not bought yet. Keeping it in one constant means attaching the real one
 * later is a single edit rather than a hunt through metadata, canonical URLs and the
 * OpenGraph block -- which is exactly the kind of thing that gets half-done and ships with
 * a stale hostname in the social preview.
 */
export const site = {
  name: 'Show Up',
  /** Replace once the domain is registered. Used for canonical and OpenGraph URLs. */
  url: 'https://showup.example',
  tagline: 'You go alone. So does everyone else.',
  description:
    'Show Up puts you at a table with four to six people who care about the same things '
    + 'you do. Everyone came alone. Nobody is the odd one out.',
  city: 'San Francisco',
} as const;
