import 'dart:async';

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
import 'features/onboarding/auth_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/waiting_screen.dart';

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

  late final Repository _repo =
      _useSupabase ? SupabaseRepository(Supabase.instance.client) : MockRepository();
  late final AppState _state = AppState(_repo, initialPhase: _initialPhase());

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
    // Subscribed here rather than per-screen because a tap can arrive in any phase,
    // including a cold start where no screen has been built yet.
    _tapSub = NotificationService.instance.taps.listen(_state.handleNotificationTap);
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
        // Tap anywhere to dismiss the keyboard. Two fields in this app are multiline
        // (the passion answer and the post-meetup reflection), so Return inserts a
        // newline and there is otherwise NO way to close the keyboard once it is open.
        // translucent so the gesture does not swallow taps meant for the widgets below.
        builder: (context, _) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: Stack(children: [
          switch (_state.phase) {
            Phase.auth       => AuthScreen(_state),
            Phase.onboarding => OnboardingScreen(_state),
            Phase.waiting    => WaitingScreen(_state),
            Phase.matched ||
            Phase.during     => GroupChatScreen(_state),
            Phase.after      => AfterFlow(_state),
            Phase.contacts   => ContactsScreen(_state),
          },
            _DevJump(_state),
            _DevLadder(_state),
          ]),
        ),
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

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 92,
      child: SafeArea(
        child: PopupMenuButton<Phase>(
          tooltip: 'Jump to step',
          icon: const CircleAvatar(
            radius: 18, backgroundColor: Colors.white12,
            child: Icon(Icons.fast_forward, size: 18, color: Colors.white54),
          ),
          onSelected: (p) async {
            if (p == Phase.matched && state.group == null) {
              (state.repo as MockRepository).formGroup();
              await state.enterGroup();
              return;
            }
            if (p == Phase.contacts) return state.loadContacts();
            state.goTo(p);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: Phase.onboarding, child: Text('1 · Signup')),
            PopupMenuItem(value: Phase.waiting,    child: Text('2 · Waiting')),
            PopupMenuItem(value: Phase.matched,    child: Text('3 · Group chat + vote')),
            PopupMenuItem(value: Phase.after,      child: Text('4 · After the meetup')),
            PopupMenuItem(value: Phase.contacts,   child: Text('5 · Numbers')),
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
            radius: 18, backgroundColor: Colors.white12,
            child: Icon(Icons.notifications_active_outlined,
                size: 18, color: Colors.white54),
          ),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            if (state.group == null) {
              messenger?.showSnackBar(const SnackBar(
                content: Text('Enter a group first — the ladder schedules from it.')));
              return;
            }
            await state.armLadder(demo: true);
            final pending = await NotificationService.instance.pending();
            messenger?.showSnackBar(SnackBar(
              content: Text(state.notificationsEnabled == true
                  ? '${pending.length} rungs armed — background the app to see them'
                  : 'Notifications denied — enable them in Settings'),
            ));
          },
        ),
      ),
    );
  }
}
