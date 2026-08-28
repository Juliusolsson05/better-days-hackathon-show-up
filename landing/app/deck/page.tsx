import type { Metadata } from 'next';
import Image from 'next/image';

import { Deck, Slide } from '@/components/deck/Deck';

export const metadata: Metadata = {
  title: 'The pitch',
  description: 'Why Show Up exists and how the table experience works.',
};

/**
 * The pitch is deliberately a five-slide product story rather than an exhaustive walkthrough.
 *
 * It lives as a route rather than a Keynote file so it remains versioned, shareable, and
 * visually consistent with the product. Each slide answers the next question an audience
 * naturally has: why this matters, what happens, what breaks the ice, and what happens after.
 */

export default function DeckPage() {
  return (
    <Deck>
      {/* 1 ---------------------------------------------------------------------- */}
      <Slide>
        <h1 className="display text-6xl sm:text-8xl">Show Up</h1>
        <p className="eyebrow mt-6">San Francisco</p>
        <p className="display mt-6 max-w-4xl text-3xl text-ink-deep sm:text-5xl">
          Four to six people who came alone, one table, one evening.
        </p>
      </Slide>

      {/* 2 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">The problem</p>
        <h2 className="display mt-8 max-w-4xl text-5xl sm:text-7xl">
          People skip the things they want to do because going alone feels awkward.
        </h2>
        <p className="mt-10 max-w-2xl text-xl text-muted">
          Half of US adults say they feel left out or lacking companionship at least some of
          the time. But the barrier is rarely interest or options. It&apos;s the moment you
          realize you&apos;d be walking in by yourself.
        </p>
      </Slide>

      {/* 3 ---------------------------------------------------------------------- */}
      {/*
        Copy alone restates the product; the group screen is the proof. Two columns keep
        the claim and the surface in one glance. Phone width is capped because a true
        50/50 split of this 2:3 mockup would dwarf the heading on a 16:10 stage.
      */}
      <Slide contentClassName="max-w-6xl">
        <div className="grid items-center gap-10 sm:grid-cols-2 sm:gap-14">
          <div>
            <p className="eyebrow">What we built</p>
            <h2 className="display mt-8 text-4xl leading-tight sm:text-5xl">
              No browsing. No profiles. You&apos;re assigned to a table.
            </h2>
            <p className="mt-8 max-w-xl text-lg leading-relaxed text-muted">
              Pick your interests. We put you with four or five people who came alone too,
              open a group chat, and give the group a few venues to vote on. The only
              decision you make is show up or don&apos;t.
            </p>
          </div>
          <div className="mx-auto w-full max-w-sm">
            <Image
              src="/hero-mockup.png"
              alt="Show Up on a phone: a Board games group with chat, a venue, and members."
              width={1412}
              height={2006}
              priority
              className="h-auto w-full"
            />
          </div>
        </div>
      </Slide>

      {/* 4 ---------------------------------------------------------------------- */}
      {/*
        The green quote card used to paraphrase this mechanic. The private-question
        screen is the actual surface, so the slide no longer invents a second artifact
        to stand in for the product. Same two-column rule as slide 3; this PNG is
        taller, so the slot stays narrower or it overflows the 900px stage.
      */}
      <Slide contentClassName="max-w-6xl">
        <div className="grid items-center gap-10 sm:grid-cols-2 sm:gap-14">
          <div>
            <p className="eyebrow">The part nobody else does</p>
            <h2 className="display mt-8 text-4xl leading-tight sm:text-5xl">
              Everyone gets one question and one person to ask it to.
            </h2>
            <p className="mt-8 max-w-xl text-lg leading-relaxed text-muted">
              Nobody sees anyone else&apos;s, and matching guarantees every person is
              somebody&apos;s target. The first ten minutes have a job, and you&apos;re not the
              one who has to start it.
            </p>
          </div>
          <div className="mx-auto w-full max-w-xs">
            <Image
              src="/question-mockup.png"
              alt="Show Up on a phone: a private question to ask Theo, over a group chat."
              width={1310}
              height={2708}
              className="h-auto w-full"
            />
          </div>
        </div>
      </Slide>

      {/* 5 ---------------------------------------------------------------------- */}
      <Slide>
        <p className="eyebrow">After the table</p>
        <h2 className="display mt-8 max-w-4xl text-5xl sm:text-7xl">
          You only exchange numbers if you both pick each other.
        </h2>
        <p className="mt-10 max-w-2xl text-xl text-muted">
          Nobody is notified, and nobody finds out they weren&apos;t picked. Being unselected
          has to be invisible, or people pick everyone out of politeness and the signal is
          worthless.
        </p>
      </Slide>
    </Deck>
  );
}
