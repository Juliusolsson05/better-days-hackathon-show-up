'use client';

import { useState } from 'react';

type State =
  | { kind: 'idle' }
  | { kind: 'sending' }
  | { kind: 'done'; already: boolean }
  | { kind: 'error'; message: string };

/**
 * Waitlist capture.
 *
 * Uses a real <form> with a real submit button, so it works with the keyboard and with
 * password managers, and so a failed hydration leaves a form rather than a dead input.
 *
 * The success state replaces the form instead of showing a toast beside it. A toast next to
 * a still-filled input reads as "did that work?", and the one thing this component owes the
 * visitor is certainty that their address landed.
 */
export function WaitlistForm() {
  const [email, setEmail] = useState('');
  const [state, setState] = useState<State>({ kind: 'idle' });

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setState({ kind: 'sending' });

    try {
      const res = await fetch('/api/waitlist', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
      const body = await res.json().catch(() => ({}));

      if (!res.ok) {
        setState({
          kind: 'error',
          message: body.error ?? 'Something went wrong. Try again.',
        });
        return;
      }
      setState({ kind: 'done', already: Boolean(body.already) });
    } catch {
      // A network failure is the visitor's connection far more often than our outage, and
      // the copy should not blame the wrong thing.
      setState({ kind: 'error', message: 'No connection. Try again in a moment.' });
    }
  }

  if (state.kind === 'done') {
    return (
      <p className="display text-2xl sm:text-3xl" role="status">
        {state.already
          ? "You're already on the list. We'll be in touch."
          : "You're on the list. We'll write when there's a table."}
      </p>
    );
  }

  const sending = state.kind === 'sending';

  return (
    <form onSubmit={submit} className="w-full max-w-md">
      <div className="flex flex-col gap-3 sm:flex-row">
        <label htmlFor="waitlist-email" className="sr-only">
          Email address
        </label>
        <input
          id="waitlist-email"
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          disabled={sending}
          className="min-h-12 min-w-0 flex-1 rounded-xl border border-ink bg-canvas px-4 py-3 text-base text-ink placeholder:text-muted disabled:opacity-60"
        />
        <button
          type="submit"
          disabled={sending}
          className="min-h-12 rounded-3xl bg-primary px-6 py-3 font-semibold text-ink transition-colors hover:bg-primary-active disabled:opacity-60"
        >
          {sending ? 'Adding you…' : 'Join the waitlist'}
        </button>
      </div>

      {state.kind === 'error' && (
        <p className="mt-3 text-sm font-semibold text-negative" role="alert">
          {state.message}
        </p>
      )}
    </form>
  );
}
