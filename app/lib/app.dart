import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  @override
  void initState() {
    super.initState();
    _repo.signIn();
  }

  @override
  void dispose() {
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
        builder: (context, _) => Stack(children: [
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
        ]),
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
        child: PopupMenuButton<Object>(
          tooltip: 'Jump to step',
          icon: const CircleAvatar(
            radius: 18, backgroundColor: Colors.white12,
            child: Icon(Icons.fast_forward, size: 18, color: Colors.white54),
          ),
          onSelected: (p) async {
            if (p == 'noshow') {
              // Preview the flaking acknowledgement. There is no attendance data in the
              // mock to derive it from, so flip the flag and show the sheet directly.
              if (state.repo is MockRepository) {
                (state.repo as MockRepository).demoNoShow = true;
              }
              await showModalBottomSheet<void>(
                context: context, backgroundColor: surface, isScrollControlled: true,
                builder: (_) => const NoShowSheet());
              return;
            }
            if (p == Phase.matched && state.group == null) {
              // Mock: fabricate a group. Real backend: just fetch whatever run-matching
              // has already written for this user.
              if (state.repo is MockRepository) {
                (state.repo as MockRepository).formGroup();
              }
              await state.enterGroup();
              return;
            }
            if (p == Phase.contacts) return state.loadContacts();
            if (p is Phase) state.goTo(p);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: Phase.onboarding, child: Text('1 · Signup')),
            PopupMenuItem(value: Phase.waiting,    child: Text('2 · Waiting')),
            PopupMenuItem(value: Phase.matched,    child: Text('3 · Group chat + vote')),
            PopupMenuItem(value: Phase.after,      child: Text('4 · After the meetup')),
            PopupMenuItem(value: Phase.contacts,   child: Text('5 · Numbers')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'noshow', child: Text('· flip no-show')),
          ],
        ),
      ),
    );
  }
}
