# Fast-forward to post-event feedback

Issue: #41

## Problem

The feedback experience already implements reflection, attendance, and mutual contact exchange,
but the demo phase picker only changes the global enum. From a fresh reference launch there is no
group or private assignment, so jumping directly to the post-event phase violates `AfterFlow`'s
state invariant and can crash before the demo begins.

## Plan

1. Give demo navigation one state-preparation boundary that loads or creates the group before any
   group-dependent destination is shown.
2. Keep fixture creation restricted to `MockRepository`; a Supabase rehearsal may read existing
   server state but must never invent an event from a client-only control.
3. Make the menu destination explicitly say “Post-event feedback” so it is easy to find on stage.
4. Add widget coverage that starts from a fresh mock launch, selects that destination, and proves
   the real reflection screen has both the group and assignment it requires.
5. Run formatting, analysis, and focused tests, then build a signed release with reference UI and
   demo controls enabled and install it on the connected iPhone.
6. Push the implementation and open an issue-linked PR without merging it.

## Acceptance criteria

- One fast-forward action from a fresh reference launch opens the real “What stuck” feedback step.
- Reflection copy includes the assigned person's name, proving assignment preparation completed.
- Attendance and contact exchange continue through the existing repository-backed flow.
- Ordinary release builds do not expose the shortcut unless `SHOW_DEMO_CONTROLS=true` is supplied.
- Demo navigation never fabricates group state in `SupabaseRepository`.
- The signed demo bundle installs and launches on the connected iPhone.
