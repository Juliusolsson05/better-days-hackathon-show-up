'use client';

import { useEffect, useRef, useState } from 'react';

/**
 * The deck shell: scroll container, keyboard navigation, and the slide counter.
 *
 * Built on CSS scroll-snap rather than a slide library, which buys the property that
 * matters when you are presenting: **it works without JavaScript.** If hydration fails or
 * the bundle never arrives, the deck degrades to a scrollable document with every slide
 * still readable. A library-driven deck in the same situation renders slide one and a blank
 * page, which is not a thing you can recover from in front of a room.
 *
 * So the keyboard handling here is an enhancement layered on top of a document that is
 * already correct, never the mechanism itself.
 */
export function Deck({ children }: { children: React.ReactNode }) {
  const scroller = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(0);
  const [total, setTotal] = useState(0);

  useEffect(() => {
    const root = scroller.current;
    if (!root) return;

    const slides = Array.from(root.querySelectorAll<HTMLElement>('[data-slide]'));
    setTotal(slides.length);

    // The counter follows what is actually on screen rather than a number we increment on
    // keypress, so it stays honest when the presenter scrolls, swipes, or drags the bar.
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setIndex(slides.indexOf(entry.target as HTMLElement));
          }
        }
      },
      { root, threshold: 0.5 },
    );
    slides.forEach((slide) => observer.observe(slide));

    function go(delta: number) {
      const next = Math.min(Math.max(index + delta, 0), slides.length - 1);
      slides[next]?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    function onKey(event: KeyboardEvent) {
      // Never hijack keys while someone is typing -- there is no input on the deck today,
      // but this is the bug that appears the moment one is added.
      const target = event.target as HTMLElement | null;
      if (target && /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;

      switch (event.key) {
        case 'ArrowRight':
        case 'ArrowDown':
        case 'PageDown':
        case ' ':
          event.preventDefault();
          go(1);
          break;
        case 'ArrowLeft':
        case 'ArrowUp':
        case 'PageUp':
          event.preventDefault();
          go(-1);
          break;
        case 'Home':
          event.preventDefault();
          slides[0]?.scrollIntoView({ behavior: 'smooth', block: 'start' });
          break;
        case 'End':
          event.preventDefault();
          slides.at(-1)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
          break;
      }
    }

    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      observer.disconnect();
    };
  }, [index]);

  return (
    <>
      <div
        ref={scroller}
        className="h-svh snap-y snap-mandatory overflow-y-auto scroll-smooth"
      >
        {children}
      </div>

      {/* Fixed, low-contrast, and out of the way. A presenter needs to know where they are;
          an audience should not be reading the chrome. */}
      <div className="pointer-events-none fixed bottom-5 right-6 font-mono text-xs text-muted/70">
        {total > 0 && `${String(index + 1).padStart(2, '0')} / ${String(total).padStart(2, '0')}`}
      </div>
    </>
  );
}

/**
 * One slide. `min-h-svh` rather than `h-svh` so a slide whose content is taller than a short
 * laptop viewport scrolls instead of clipping -- losing the bottom of a slide is a failure
 * mode you only discover on the projector.
 */
export function Slide({
  children,
  className = '',
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section
      data-slide
      className={`flex min-h-svh snap-start flex-col justify-center px-6 py-20 odd:bg-canvas even:bg-canvas-soft sm:px-16 lg:px-24 ${className}`}
    >
      <div className="mx-auto w-full max-w-5xl">{children}</div>
    </section>
  );
}
