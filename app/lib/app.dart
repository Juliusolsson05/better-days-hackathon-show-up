import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/notifications.dart';
import 'core/theme.dart';
import 'data/mock_repository.dart';
import 'data/repository.dart';
import 'data/supabase_repository.dart';
import 'models/models.dart';
import 'state/app_state.dart';
import 'features/after/after_flow.dart';
import 'features/after/contacts_screen.dart';
import 'features/group/group_chat_screen.dart';
import 'features/group/no_show_sheet.dart';
import 'features/onboarding/auth_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/waiting_screen.dart';
import 'features/product/product_shell.dart';

class ShowUpApp extends StatefulWidget {
  const ShowUpApp({super.key});
  @override
  State<ShowUpApp> createState() => _ShowUpAppState();
}

class _ShowUpAppState extends State<ShowUpApp> {
  /// --dart-define=USE_SUPABASE=true swaps the mock for the real backend. Main() only
  /// calls Supabase.initialize under the same flag, so MockRepository stays the default
  /// and needs no cloud project.
  static const _useSupabase = bool.fromEnvironment('USE_SUPABASE');
  static const _showReferenceUi = bool.fromEnvironment('SHOW_REFERENCE_UI');

  late final Repository _repo = _useSupabase
      ? SupabaseRepository(Supabase.instance.client)
      : MockRepository();
  late final AppState _state = AppState(
    _repo,
    initialPhase: _initialPhase(),
    // The reference shell is intentionally a mock-only preview. It contains static
    // example groups whose "join" controls are presentation prototypes, so routing a
    // real session there would fork the product lifecycle away from Postgres truth.
    // Debug builds make visual review convenient; SHOW_REFERENCE_UI makes the same
    // preview available in a release-mode reference build without weakening production.
    referenceUiPreview: !_useSupabase && (kDebugMode || _showReferenceUi),
  );
  bool _restoring = _useSupabase;
  Object? _restoreError;

  Phase _initialPhase() {
    if (!_useSupabase) return Phase.onboarding;
    // A restored session means the user is past auth; a signed-in user with no profile
    // yet is precisely the onboarding case.
    return Supabase.instance.client.auth.currentSession == null
        ? Phase.auth
        : Phase.onboarding;
  }

  StreamSubscription<NotificationTap>? _tapSub;

  @override
  void initState() {
    super.initState();
    _repo.signIn();
    // Notification responses outlive individual screens. Subscribe before restoration so a
    // cold-start tap can be replayed once AppState has loaded the durable group.
    _tapSub = NotificationService.instance.taps.listen(
      _state.handleNotificationTap,
    );
    if (_useSupabase) _restore();
  }

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    try {
      await _state.restore();
    } catch (error) {
      if (mounted) _restoreError = error;
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    final repo = _repo;
    if (repo is MockRepository) repo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Show Up',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          if (_restoring) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (_restoreError != null) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'We could not restore your place yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _restore,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          // Multiline fields use Return for a newline, so tapping the canvas is the only
          // universal dismissal gesture. Keeping it at the shell means future screens
          // inherit the behavior instead of each rediscovering the keyboard trap.
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Stack(
              children: [
                switch (_state.phase) {
                  Phase.auth => AuthScreen(_state),
                  Phase.onboarding => OnboardingScreen(_state),
                  // Phase.home is never selected by real onboarding or restoration.
                  // Keeping the branch in the production router avoids a second app
                  // entrypoint solely for reference review, while AppState owns the
                  // invariant that only an explicitly enabled preview can enter it.
                  Phase.home => ProductShell(_state),
                  Phase.waiting => WaitingScreen(_state),
                  Phase.matched || Phase.during => GroupChatScreen(_state),
                  Phase.after => AfterFlow(_state),
                  Phase.contacts => ContactsScreen(_state),
                },
                // Demo controls compress a three-day lifecycle, but a production build
                // must never let a client manufacture phases that only the server owns.
                // The named define keeps rehearsals possible without quietly turning the
                // debug affordance into part of the release product.
                if (kDebugMode ||
                    const bool.fromEnvironment('SHOW_DEMO_CONTROLS')) ...[
                  _DevJump(_state),
                  _DevLadder(_state),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Jumps straight to any point in the flow.
///
/// This is demo infrastructure, not a debug leftover: the flow spans three days of real
/// time, so without it the post-meetup screens cannot be reached at all, let alone
/// rehearsed. Gate it on kDebugMode before this ever ships.
class _DevJump extends StatelessWidget {
  final AppState state;
  const _DevJump(this.state);

  Future<void> _select(BuildContext context, Object p) async {
    if (p == 'noshow') {
      // Preview the flaking acknowledgement. There is no attendance data in the
      // mock to derive it from, so flip the flag and show the sheet directly.
      if (state.repo is MockRepository) {
        (state.repo as MockRepository).demoNoShow = true;
      }
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: surface,
        isScrollControlled: true,
        builder: (_) => const NoShowSheet(),
      );
      return;
    }

    if (p == Phase.matched && state.group == null) {
      // Mock: fabricate a group. Real backend: just fetch whatever run-matching
      // has already written for this user. Keep the type guard here because a
      // release-like Supabase rehearsal must never mutate server state through
      // a control that only exists to compress the three-day demo timeline.
      final repo = state.repo;
      if (repo is MockRepository) repo.formGroup();
      await state.enterGroup();
      return;
    }

    if (p == Phase.after || p == Phase.contacts) {
      // These screens require both a group and its private assignment. Changing only the enum was
      // enough to render the route but left AfterFlow dereferencing null from a fresh launch. The
      // fixture is still created only by MockRepository; a Supabase rehearsal can fast-forward
      // solely when the backend already owns a real group for this user.
      final repo = state.repo;
      if (repo is MockRepository && state.group == null) repo.formGroup();
      try {
        final ready = await state.prepareGroupForDemo();
        if (!context.mounted) return;
        if (!ready) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No event is ready for post-event feedback yet.'),
            ),
          );
          return;
        }
        if (p == Phase.contacts) {
          await state.loadContacts();
        } else {
          state.goTo(Phase.after);
        }
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not prepare the post-event demo.'),
          ),
        );
      }
      return;
    }

    if (p is Phase) state.goTo(p);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 92,
      child: SafeArea(
        child: PopupMenuButton<Object>(
          tooltip: 'Jump to step',
          icon: const CircleAvatar(
            radius: 20,
            backgroundColor: ink,
            child: Icon(Icons.fast_forward, size: 18, color: accent),
          ),
          onSelected: (p) => _select(context, p),
          itemBuilder: (_) => const [
            PopupMenuItem(value: Phase.onboarding, child: Text('1 - Signup')),
            PopupMenuItem(value: Phase.home, child: Text('2 - Home')),
            PopupMenuItem(value: Phase.waiting, child: Text('2 - Waiting')),
            PopupMenuItem(
              value: Phase.matched,
              child: Text('3 - Group chat + vote'),
            ),
            PopupMenuItem(
              value: Phase.after,
              child: Text('4 - Post-event feedback'),
            ),
            PopupMenuItem(value: Phase.contacts, child: Text('5 - Numbers')),
            PopupMenuDivider(),
            PopupMenuItem(
              value: 'noshow',
              child: Text('Preview no-show message'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fires the whole ladder compressed into ~40 seconds.
///
/// Demo infrastructure like [_DevJump]: the real ladder's first rung is three days before
/// the event, so there is no way to show the notification system -- the part of this
/// product that carries the story -- without compressing it. Gate on kDebugMode before
/// this ships.
class _DevLadder extends StatelessWidget {
  final AppState state;
  const _DevLadder(this.state);

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 140,
      child: SafeArea(
        child: IconButton(
          tooltip: 'Fire the ladder (compressed)',
          icon: const CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white12,
            child: Icon(
              Icons.notifications_active_outlined,
              size: 18,
              color: Colors.white54,
            ),
          ),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            if (state.group == null) {
              messenger?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Enter a group first — the ladder schedules from it.',
                  ),
                ),
              );
              return;
            }
            await state.armLadder(demo: true);
            final pending = await NotificationService.instance.pending();
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  state.notificationsEnabled == true
                      ? '${pending.length} rungs armed — background the app to see them'
                      : 'Notifications denied — enable them in Settings',
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
