import type { Metadata } from 'next';
import { Inter, Space_Mono } from 'next/font/google';

import { site } from '@/lib/site';
import './globals.css';

/**
 * Inter performs both display and utility roles because Wise Sans is proprietary.
 *
 * The distinction now comes from weight rather than family: black 900 for brand statements,
 * regular and semibold for everything functional. That strict split is more important than
 * approximating the proprietary face with a second font that introduces its own personality.
 *
 * Space Mono earns its place on exactly one thing: the scoring formula in the deck. It is
 * deliberately kept away from labels and eyebrows, where mono would make a warm page read
 * like a terminal.
 *
 * `display: 'swap'` throughout: a flash of fallback beats a blank hero on a slow connection,
 * and the hero is the whole pitch.
 */
const inter = Inter({
  subsets: ['latin'],
  variable: '--font-inter',
  display: 'swap',
});

const spaceMono = Space_Mono({
  subsets: ['latin'],
  weight: ['400', '700'],
  variable: '--font-space-mono',
  display: 'swap',
});

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: {
    default: `${site.name} — ${site.tagline}`,
    template: `%s — ${site.name}`,
  },
  description: site.description,
  openGraph: {
    title: `${site.name} — ${site.tagline}`,
    description: site.description,
    url: site.url,
    siteName: site.name,
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
    title: `${site.name} — ${site.tagline}`,
    description: site.description,
  },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={`${inter.variable} ${spaceMono.variable}`}
    >
      <body className="bg-canvas text-ink antialiased">{children}</body>
    </html>
  );
}
