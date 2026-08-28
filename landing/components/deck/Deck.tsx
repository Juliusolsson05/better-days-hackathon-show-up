'use client';

import {
  Deck as SpectacleDeck,
  DefaultTemplate,
  Slide as SpectacleSlide,
  fadeTransition,
} from 'spectacle';

/**
 * Spectacle owns presentation state, navigation, presenter mode, overview mode, touch
 * gestures, print/export mode, and cross-window synchronization.
 *
 * The first implementation rebuilt only the visible slideshow behaviour with scroll snap.
 * That looked like a deck but omitted the reason to use a presentation framework: presenter
 * notes, a second synchronized window, overview, and export. Keeping this wrapper thin lets
 * the content route remain ordinary JSX while Spectacle owns every presentation concern.
 *
 * Useful built-in commands are available through Spectacle's command bar (`Cmd/Ctrl+Shift+P`):
 * presenter mode, overview, print/export, and fullscreen. Arrow keys and space navigate.
 */
export function Deck({ children }: { children: React.ReactNode }) {
  return (
    <SpectacleDeck
      transition={fadeTransition}
      theme={{
        size: { width: 1440, height: 900, maxCodePaneHeight: 650 },
        colors: {
          primary: '#0e0f0c',
          secondary: '#163300',
          tertiary: '#9fe870',
          quaternary: '#e8ebe6',
          quinary: '#ffffff',
        },
        fonts: {
          header: 'var(--font-inter), system-ui, sans-serif',
          text: 'var(--font-inter), system-ui, sans-serif',
          monospace: 'var(--font-space-mono), monospace',
        },
      }}
      template={() => <DefaultTemplate color="#454745" />}
    >
      {children}
    </SpectacleDeck>
  );
}

/**
 * A content-width boundary inside Spectacle's fixed 16:10 stage.
 *
 * Padding belongs on the actual Slide so presenter, overview, and export modes all see the
 * same geometry. A nested viewport-sized section would fight Spectacle's aspect-ratio
 * fitting and is the exact mistake this wrapper exists to prevent.
 */
export function Slide({
  children,
  className = '',
  contentClassName,
}: {
  children: React.ReactNode;
  className?: string;
  /**
   * Replaces the default max-w-5xl on the inner stage, rather than appending to it.
   * Two-column product slides need the extra width; stacking both max-width utilities
   * would let the stylesheet order win, not the class string, and silently stay narrow.
   */
  contentClassName?: string;
}) {
  return (
    <SpectacleSlide
      backgroundColor="#e8ebe6"
      textColor="#0e0f0c"
      padding="64px 80px"
      className={className}
    >
      <div
        className={`mx-auto flex h-full w-full flex-col justify-center ${contentClassName ?? 'max-w-5xl'}`}
      >
        {children}
      </div>
    </SpectacleSlide>
  );
}
