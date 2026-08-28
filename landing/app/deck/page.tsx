import type { Metadata } from 'next';
import Link from 'next/link';

import { Deck, Slide } from '@/components/deck/Deck';
import { site } from '@/lib/site';

export const metadata: Metadata = {
  title: 'The pitch',
  description: `Why ${site.name} exists, how the matching works, and what we can measure.`,
};

/**
 * The pitch deck.
 *
 * Lives as a route rather than a Keynote file so it is in version control, shares the
 * landing page's palette and type, and can be sent as a link. The rule it follows: every
 * slide makes one claim. A slide making two claims is two slides, because the audience is
 * reading it while listening to you and can only do one at a time.
 *
 * The middle third is deliberately technical. The product thesis is easy to nod along to
 * and hard to believe; the three problems in slides 7-9 are what make it credible that this
 * was actually built rather than described.
 */

const FAILURES = [
  {
    heading: 'Choice is the tax',
    body: 'Browsing people is work that feels like judging and being judged. Most people bounce before they meet anyone.',
  },
  {
    heading: 'Photos make it romantic',
    body: 'The moment faces are on screen the product reads as dating, and the population self-selects accordingly.',
  },
  {
    heading: 'Messaging is a trap',
    body: 'Chat becomes the product instead of the doorway. People text for weeks and never meet.',
  },
];

export default function DeckPage() {
  return (
    <Deck>
      {/* 1 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">{site.city}</p>
        <h1 className="display mt-8 text-6xl sm:text-8xl">{site.name}</h1>
        <p className="display mt-6 text-3xl text-ink-deep sm:text-5xl">{site.tagline}</p>
        <p className="mt-12 max-w-xl text-lg text-muted">
          Small groups of solo attendees, matched on what they actually care about, meeting
          in person.
        </p>
      </Slide>

      {/* 2 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">The problem</p>
        <h2 className="display mt-8 max-w-4xl text-5xl sm:text-7xl">
          People skip the things they want to do because going alone feels awkward.
        </h2>
        <p className="mt-10 max-w-2xl text-xl text-muted">
          The barrier is not lack of interest and it is not lack of options. It is the
          discomfort of walking in by yourself.
        </p>
      </Slide>

      {/* 3 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">Why the existing shape fails</p>
        <h2 className="display mt-8 text-4xl sm:text-6xl">
          Everything built at this problem is a marketplace.
        </h2>
        <p className="mt-6 max-w-2xl text-lg text-muted">
          Profiles, photos, browsing, choosing, matching, messaging. That shape has three
          failure modes.
        </p>
        <div className="mt-14 grid gap-10 sm:grid-cols-3">
          {FAILURES.map((f, i) => (
            <div key={f.heading} className="rounded-3xl bg-canvas-soft p-6">
              <span className="display text-2xl text-ink-deep">
                {String(i + 1).padStart(2, '0')}
              </span>
              <h3 className="display mt-3 text-2xl">{f.heading}</h3>
              <p className="mt-3 leading-relaxed text-muted">{f.body}</p>
            </div>
          ))}
        </div>
      </Slide>

      {/* 4 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">What we built</p>
        <h2 className="display mt-8 max-w-4xl text-5xl sm:text-7xl">
          We removed all three. You are assigned to a table.
        </h2>
        <p className="mt-10 max-w-2xl text-xl text-muted">
          No browsing, no picking, no face photos. Four to six people who came alone. The
          only decision you make is{' '}
          <span className="text-ink">attend or don&rsquo;t</span>.
        </p>
      </Slide>

      {/* 5 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">The mechanic</p>
        <h2 className="display mt-8 text-4xl sm:text-6xl">
          Everyone gets one question and one person to ask it to.
        </h2>
        <div className="mt-12 max-w-3xl rounded-3xl bg-primary-pale p-8 sm:p-10">
          <p className="eyebrow text-ink-deep">Just for you</p>
          <p className="display mt-5 text-2xl leading-snug sm:text-3xl">
            Ask Tom what the first record was that made him care about how something was
            mixed, rather than what it was.
          </p>
        </div>
        <p className="mt-10 max-w-2xl text-lg text-muted">
          Matching guarantees every member is somebody&rsquo;s target, so nobody is left
          out. Open-ended small talk becomes one concrete task.
        </p>
      </Slide>

      {/* 6 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">How matching works</p>
        <h2 className="display mt-8 text-4xl sm:text-6xl">
          Two models, because neither works alone.
        </h2>
        <div className="mt-14 grid gap-12 sm:grid-cols-2">
          <div className="border-t border-ink/15 pt-5">
            <p className="eyebrow">Voyage · 256 dims</p>
            <h3 className="display mt-3 text-3xl">Recall</h3>
            <p className="mt-3 leading-relaxed text-muted">
              The embedding finds the topic neighbourhood — everyone in the general area of
              what you care about.
            </p>
          </div>
          <div className="rounded-3xl bg-primary-pale p-6">
            <p className="eyebrow text-ink-deep">Claude · structured tags</p>
            <h3 className="display mt-3 text-3xl">Precision</h3>
            <p className="mt-3 leading-relaxed text-muted">
              Extracted stance and energy narrow that neighbourhood to people who would
              actually enjoy each other.
            </p>
          </div>
        </div>
      </Slide>

      {/* 7 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">Problem one</p>
        <h2 className="display mt-8 max-w-4xl text-4xl sm:text-6xl">
          Raw embeddings make everyone look identical.
        </h2>
        <p className="mt-10 max-w-2xl text-lg leading-relaxed text-muted">
          Embedding models are anisotropic: every vector points into the same narrow cone.
          Any two profiles score about 0.85, unrelated ones score 0.84, and the ranking
          degenerates into noise. Nothing errors — the groups just quietly stop meaning
          anything.
        </p>
        <p className="display mt-12 text-3xl text-ink-deep sm:text-4xl">
          Fix: subtract the population centroid at write time.
        </p>
        <p className="mt-6 max-w-2xl text-muted">
          Now we measure how you differ from the typical user of this app, not from the
          average of all English text.
        </p>
      </Slide>

      {/* 8 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">Problem two</p>
        <h2 className="display mt-8 max-w-4xl text-4xl sm:text-6xl">
          Embeddings cannot tell a stance from its opposite.
        </h2>
        <div className="mt-12 grid max-w-3xl gap-4">
          <p className="rounded-3xl bg-canvas-soft px-6 py-5 text-lg">
            &ldquo;I love hunting, I go every fall with my dad.&rdquo;
          </p>
          <p className="rounded-3xl bg-canvas-soft px-6 py-5 text-lg">
            &ldquo;I&rsquo;m vegan and I think hunting is barbaric.&rdquo;
          </p>
        </div>
        <p className="mt-10 max-w-2xl text-lg leading-relaxed text-muted">
          These embed almost identically — embeddings capture what you are talking about,
          not what you think about it. A pure-vector matcher seats them together and reports
          an excellent match.
        </p>
        <p className="display mt-10 text-3xl text-ink-deep sm:text-4xl">
          Fix: extract stance separately and filter on it.
        </p>
      </Slide>

      {/* 9 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">Problem three</p>
        <h2 className="display mt-8 max-w-4xl text-4xl sm:text-6xl">
          Averaging a group returns the blandest bar in the city.
        </h2>
        <p className="mt-10 max-w-2xl text-lg leading-relaxed text-muted">
          The obvious way to pick a venue is to average the group into one vector and find
          its nearest match. But averaging degrades exactly when a group is diverse — and we
          diversify groups on purpose — and a centroid in high dimensions is a hub, nearest
          to almost everything. Every group gets the same three venues. It looks like a
          caching bug.
        </p>
        <p className="display mt-12 text-3xl text-ink-deep sm:text-4xl">
          Fix: score per member, then combine the scores.
        </p>
        <p className="mt-6 max-w-2xl font-mono text-sm text-muted">
          score = 0.5 · mean(similarity) + 0.5 · min(similarity)
        </p>
        <p className="mt-6 max-w-2xl text-muted">
          The min term is the product promise in arithmetic: a venue that delights four
          people and bores two loses to one that suits all six.
        </p>
      </Slide>

      {/* 10 --------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">Architecture</p>
        <h2 className="display mt-8 text-4xl sm:text-6xl">Two databases, on purpose.</h2>
        <div className="mt-14 grid gap-12 sm:grid-cols-2">
          <div className="border-t border-ink/15 pt-5">
            <p className="eyebrow">Postgres</p>
            <h3 className="display mt-3 text-3xl">Correct right now</h3>
            <p className="mt-3 leading-relaxed text-muted">
              Users, groups, chat, RSVPs, contact exchange. Read one row at a time. Every
              product privacy rule is a row-level security policy, so the database enforces
              it rather than the client.
            </p>
          </div>
          <div className="rounded-3xl bg-primary-pale p-6">
            <p className="eyebrow text-ink-deep">ClickHouse</p>
            <h3 className="display mt-3 text-3xl">Scanned in bulk</h3>
            <p className="mt-3 leading-relaxed text-muted">
              Matching is a full-population sweep that touches every row and has to stay
              fast as a city grows. No vector index — brute force returns in tens of
              milliseconds and there is no index to misconfigure.
            </p>
          </div>
        </div>
      </Slide>

      {/* 11 --------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">What we can answer</p>
        <h2 className="display mt-8 max-w-4xl text-5xl sm:text-7xl">
          Which reminder actually moves someone from deciding to doing?
        </h2>
        <p className="mt-10 max-w-2xl text-lg leading-relaxed text-muted">
          Notified, RSVP&rsquo;d, attended, exchanged numbers — sliced by how tightly the
          group was matched. One funnel query over the event stream.
        </p>
        <p className="mt-8 max-w-2xl text-lg leading-relaxed text-muted">
          That is not an app metric. It is a measurable claim about what actually produces
          friendship, and it cannot be answered without the analytical half.
        </p>
      </Slide>

      {/* 12 --------------------------------------------------------------------- */}
      <Slide>
        <h2 className="display max-w-4xl text-5xl sm:text-7xl">
          The endpoint is six people leaving with each other&rsquo;s numbers and never
          opening the app again.
        </h2>
        <p className="mt-10 max-w-2xl text-xl text-muted">
          We treat that as success, and we measure it.
        </p>
        <Link
          href="/"
          className="mt-14 inline-block rounded-3xl bg-primary px-7 py-3.5 font-semibold text-ink transition-colors hover:bg-primary-active"
        >
          {site.name}
        </Link>
      </Slide>
    </Deck>
  );
}
