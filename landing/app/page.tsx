import Link from 'next/link';

import { StoreBadges } from '@/components/StoreBadges';
import { WaitlistForm } from '@/components/WaitlistForm';
import { site } from '@/lib/site';

/**
 * The landing page.
 *
 * Written for someone who has never heard of this and is deciding in about eight seconds
 * whether it is for them. Order: the feeling they already have, then what we do about it,
 * then the mechanism, then the promises. The technical story -- ClickHouse, embeddings, the
 * matcher -- is genuinely interesting and lives entirely in /deck. Here it would answer a
 * question this visitor has not asked.
 *
 * There is no hero illustration, on purpose. The first pass had a diagram of a table with
 * six labelled seats and it was decoration pretending to be information: it restated the
 * headline in a less clear form and delayed the one action the page wants. The hero is now
 * the sentence and the input, and the page's memorable object is the question card further
 * down -- which is real product output rather than a picture of a concept.
 */

/** A real sequence, which is the only reason it is numbered. */
const STEPS = [
  {
    title: 'Tell us what you like.',
    body:
      'Pick your interests and tell us what you could talk about for hours. That is what '
      + 'we use to find your people.',
  },
  {
    title: 'Meet your group.',
    body:
      'We pair you with four to six like-minded people who are free on the same evening. '
      + 'Everyone arrives solo.',
  },
  {
    title: 'Choose a public place.',
    body:
      'Your private group chat opens with a few venue options. Vote anonymously and pick '
      + 'the place that feels right.',
  },
  {
    title: 'Show up together.',
    body:
      'We remind you before the meetup and tell you exactly where to find the group. No '
      + 'awkward searching, no walking in alone.',
  },
];

/** Stated as promises rather than features, because each is a thing we refuse to build. */
const REFUSALS = [
  {
    title: 'No swiping',
    body: 'You are here to meet people, not judge a wall of profiles.',
  },
  {
    title: 'Not a dating app',
    body: 'The match is based on shared interests, not appearance.',
  },
  {
    title: 'Everyone comes alone',
    body: 'Nobody is the outsider joining somebody else’s friend group.',
  },
  {
    title: 'Built for real life',
    body: 'The goal is to get you out of the app and around a real table.',
  },
];

export default function Home() {
  return (
    <div className="mx-auto max-w-6xl px-6 sm:px-8">
      <header className="sticky top-0 z-20 -mx-6 flex items-center justify-between bg-canvas/95 px-6 py-4 backdrop-blur sm:-mx-8 sm:px-8">
        <span className="display text-2xl">{site.name}</span>
        <Link href="/deck" className="text-sm font-semibold transition-colors hover:text-ink-deep">
          The pitch
        </Link>
      </header>

      {/* ---- Hero ------------------------------------------------------------------ */}
      <section className="band band-sage py-16 sm:py-24">
        <div className="max-w-5xl">
        <p className="eyebrow rise inline-flex rounded-full bg-primary-pale px-4 py-2 text-ink-deep" style={{ animationDelay: '0.05s' }}>
          Small groups · real places · no swiping
        </p>
        <h1
          className="display rise mt-8 max-w-4xl text-5xl sm:text-6xl lg:text-7xl"
          style={{ animationDelay: '0.15s' }}
        >
          A safe place to meet <span className="text-ink-deep">like-minded people.</span>
        </h1>
        <p
          className="rise mt-10 max-w-2xl text-xl leading-8 text-body"
          style={{ animationDelay: '0.28s' }}
        >
          Automatically paired with a small group of brand-new faces who are into the same
          things you are. Everyone comes alone.
        </p>

        {/* The form is the hero's call to action rather than a button that scrolls to one.
            Every screen between someone and the single thing you want them to do loses a
            share of them, and that includes a scroll. */}
        <div className="rise mt-10" style={{ animationDelay: '0.4s' }}>
          <WaitlistForm />
        </div>

        <div className="rise mt-10" style={{ animationDelay: '0.5s' }}>
          <StoreBadges />
        </div>
        </div>
      </section>

      {/* ---- The problem ----------------------------------------------------------- */}
      <section className="py-20 sm:py-28">
        <h2 className="display max-w-4xl text-5xl sm:text-6xl">
          Meeting new people should not feel like dating.
        </h2>
        <p className="mt-8 max-w-2xl text-xl leading-8 text-body">
          Endless profiles, forced small talk, and wondering whether you belong make meeting
          people feel harder than it should. Show Up removes the audition. We create a small
          group around shared interests and give everyone the same simple plan: arrive solo,
          meet somewhere public, and start from common ground.
        </p>
      </section>

      {/* ---- How it works ---------------------------------------------------------- */}
      <section className="band band-sage py-20 sm:py-28">
        <p className="eyebrow">How it works</p>
        <ol className="mt-12 grid gap-6 sm:grid-cols-2">
          {STEPS.map((step, i) => (
            <li key={step.title} className="rounded-3xl bg-canvas p-6 sm:p-8">
              <span className="display text-4xl text-ink-deep">
                {String(i + 1).padStart(2, '0')}
              </span>
              <h3 className="display mt-3 text-2xl">{step.title}</h3>
              <p className="mt-4 leading-6 text-body">{step.body}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* ---- The assigned question ------------------------------------------------- */}
      <section className="py-20 sm:py-28">
        <div className="grid items-center gap-14 lg:grid-cols-2">
          <div>
            <p className="eyebrow">The bit that does the work</p>
            <h2 className="display mt-6 text-4xl sm:text-5xl">
              Never get stuck wondering what to say.
            </h2>
            <p className="mt-8 max-w-lg text-lg leading-7 text-body">
              Before the meetup, everyone gets one thoughtful question to ask one person in
              the group. It turns the hardest first minute into an easy conversation — and
              makes sure every person is included.
            </p>
          </div>

          {/* Real product output, not an illustration of it: this is the shape the app
              actually delivers. Tilted a degree because a perfectly square card reads as a
              UI panel rather than as something handed to you. */}
          <div className="rounded-3xl bg-primary-pale p-8 sm:p-10">
            <p className="eyebrow text-ink-deep">Just for you</p>
            <p className="display mt-5 text-2xl leading-snug sm:text-[1.75rem]">
              Ask Tom which record changed the way he listens to music — and why.
            </p>
            <p className="mt-6 text-sm text-body">
              Nobody else can see this, and everyone has one.
            </p>
          </div>
        </div>
      </section>

      {/* ---- Refusals -------------------------------------------------------------- */}
      <section className="band band-dark py-20 text-canvas sm:py-28">
        <h2 className="display max-w-2xl text-4xl sm:text-5xl">
          Designed to feel safe, simple, and human.
        </h2>
        <ul className="mt-12 grid gap-6 sm:grid-cols-2">
          {REFUSALS.map((item) => (
            <li key={item.title} className="rounded-3xl bg-canvas/10 p-6">
              <h3 className="text-2xl font-semibold text-primary">{item.title}</h3>
              <p className="mt-3 leading-6 text-canvas-soft">{item.body}</p>
            </li>
          ))}
        </ul>
      </section>

      {/* ---- The ending ------------------------------------------------------------ */}
      <section className="py-20 sm:py-28">
        <h2 className="display max-w-3xl text-4xl sm:text-5xl">
          Leave with people you actually want to see again.
        </h2>
        <p className="mt-8 max-w-2xl text-lg leading-7 text-body">
          After the meetup, choose who you would like to stay in touch with. Contact details
          are shared only when the choice is mutual, and nobody is told when it is not. No
          pressure, no awkward rejection — just a private way to continue a real connection.
        </p>
      </section>

      {/* ---- Waitlist -------------------------------------------------------------- */}
      <section
        id="waitlist"
        className="band band-green scroll-mt-8 py-20 sm:py-28"
      >
        <h2 className="display max-w-3xl text-4xl sm:text-5xl">Meet your people in {site.city}.</h2>
        <p className="mt-6 max-w-lg text-lg leading-7 text-body">
          Join the waitlist and we will let you know when a new group is forming near you.
        </p>
        <div className="mt-10">
          <WaitlistForm />
        </div>
        <div className="mt-12">
          <StoreBadges />
        </div>
      </section>

      <footer className="band band-dark flex flex-col gap-3 py-12 text-canvas-soft sm:flex-row sm:items-center sm:justify-between">
        <p className="text-sm">
          {site.name} · {site.city}
        </p>
        <Link href="/deck" className="text-sm font-semibold transition-colors hover:text-primary">
          The pitch
        </Link>
      </footer>
    </div>
  );
}
