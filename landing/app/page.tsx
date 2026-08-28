import Image from 'next/image';
import Link from 'next/link';

import { StoreBadges } from '@/components/StoreBadges';
import { WaitlistForm } from '@/components/WaitlistForm';
import { site } from '@/lib/site';

/**
 * The landing page.
 *
 * Written for someone who has never heard of this and is deciding in about eight seconds
 * whether it is for them. Order: the feeling they already have, then the objection plus
 * the mechanism in one beat, then the promises. The technical story -- ClickHouse,
 * embeddings, the matcher -- is genuinely interesting and lives entirely in /deck. Here
 * it would answer a question this visitor has not asked.
 *
 * The hero used to be copy-only. The first illustration we tried was a labelled diagram of
 * a table, and it failed because it restated the headline instead of proving it. The phone
 * mockup is different: it is a real product surface (group, chat, venue, members), so it
 * answers "what am I signing up for?" without competing with the waitlist form. Copy stays
 * first in the DOM so the CTA is still the first thing a keyboard or a narrow screen meets;
 * the image sits on the right on wide screens, where a second column is free.
 */

/**
 * Four beats of the same evening, not a numbered tutorial. They used to sit under a
 * "How it works" eyebrow, which made the page explain itself. The heading now carries
 * the objection those steps answer, so the sequence does not need a label or numerals
 * -- both would restate what the visitor can already see from the cards.
 */
const STEPS = [
  {
    title: "You tell us what you're into",
    body: "A few interests. That's all the matching needs.",
  },
  {
    title: 'We put you with four or five people',
    body: 'Small on purpose. Everyone came by themselves.',
  },
  {
    title: 'You talk before you meet',
    body: 'A group chat opens right away. You pick the place together.',
  },
  {
    title: 'You show up',
    body: 'We tell you where to go and who to look for. No scanning the room.',
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
        {/* Copy first, image second: the waitlist is still the action, and a stacked
            mobile layout would otherwise bury the form under a tall phone. The 7/5 split
            keeps the headline readable; an even split made the type wrap into a stack of
            short lines that no longer sounded like a sentence. */}
        <div className="grid items-center gap-12 lg:grid-cols-12 lg:gap-8">
          <div className="lg:col-span-7">
            <h1
              className="display rise max-w-4xl text-5xl sm:text-6xl lg:text-6xl xl:text-7xl"
              style={{ animationDelay: '0.15s' }}
            >
              We'll help you figure where to go and what to do.{' '}
              <span className="text-ink-deep">Just ShowUp!</span>
            </h1>
            <p
              className="rise mt-10 max-w-2xl text-xl leading-8 text-body"
              style={{ animationDelay: '0.28s' }}
            >
              4-6 people, one table, one evening. Everyone came alone, and everyone leaves the
              room making new connections.
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

          <div
            className="rise mx-auto w-full max-w-xs sm:max-w-sm lg:col-span-5 lg:max-w-none"
            style={{ animationDelay: '0.35s' }}
          >
            {/* Intrinsic size matches the PNG (1412×2006). CSS shrinks it; Next still
                needs the real ratio so the slot does not collapse before the file loads.
                The asset is already transparent -- a black studio backdrop was knocked
                out -- so it sits on the sage band without a rectangle around the hand. */}
            <Image
              src="/hero-mockup.png"
              alt="Show Up on a phone: a Board games group with chat, a venue, and members."
              width={1412}
              height={2006}
              priority
              sizes="(min-width: 1024px) 40vw, 320px"
              className="h-auto w-full"
            />
          </div>
        </div>
      </section>

      {/* ---- Walking in alone ------------------------------------------------------ */}
      {/*
        This used to be two sections: a problem statement ("should not feel like dating")
        and a numbered how-it-works grid. The problem copy restated the hero, and the
        eyebrow plus 01-04 numerals made the grid look like a manual. One heading now
        names the fear; the cards are the answer. Sage stays so the canvas cards read
        as cards rather than disappearing into the page.
      */}
      <section className="band band-sage py-20 sm:py-28">
        <h2 className="display max-w-4xl text-5xl sm:text-6xl">
          Most plans die at the thought of walking in alone. But not if everyone's
          alone.
        </h2>
        <ol className="mt-12 grid gap-6 sm:grid-cols-2">
          {STEPS.map((step) => (
            <li key={step.title} className="rounded-3xl bg-canvas p-6 sm:p-8">
              <h3 className="display text-2xl">{step.title}</h3>
              <p className="mt-4 leading-6 text-body">{step.body}</p>
            </li>
          ))}
        </ol>
      </section>

      {/* ---- The assigned question ------------------------------------------------- */}
      {/*
        The pale-green quote card used to stand in for this feature by restating the
        body copy. The phone mockup is the real surface -- a private card over the group
        chat -- so it proves the claim instead of repeating it. The eyebrow went with the
        card: the heading already says what the section is. Intrinsic size is the PNG
        (1310x2708); CSS shrinks it. A 50/50 column at full width would make a phone this
        tall dominate the copy, so the slot stays capped the way the hero phone is.
      */}
      <section className="py-20 sm:py-28">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-14">
          <div>
            <h2 className="display text-4xl sm:text-5xl">
              Before you get there, we give you one thing to ask.
            </h2>
            <p className="mt-8 max-w-lg text-lg leading-7 text-body">
              Not an icebreaker for the table. One question, meant for one person in your
              group. Everyone gets one, and nobody sees anyone else's. So the first ten
              minutes have a job, and you're not the one who has to start.
            </p>
          </div>

          <div className="mx-auto w-full max-w-xs sm:max-w-sm">
            <Image
              src="/question-mockup.png"
              alt="Show Up on a phone: a private question to ask Theo, over a group chat."
              width={1310}
              height={2708}
              sizes="(min-width: 1024px) 24rem, 320px"
              className="h-auto w-full"
            />
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
