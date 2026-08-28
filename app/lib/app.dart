import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/mock_repository.dart';
import 'models/models.dart';
import 'state/app_state.dart';
import 'features/after/after_flow.dart';
import 'features/after/contacts_screen.dart';
import 'features/group/group_chat_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/waiting_screen.dart';

class ShowUpApp extends StatefulWidget {
  const ShowUpApp({super.key});
  @override
  State<ShowUpApp> createState() => _ShowUpAppState();
}

class _ShowUpAppState extends State<ShowUpApp> {
  final _repo = MockRepository();
  late final AppState _state = AppState(_repo);

  @override
  void initState() {
    super.initState();
    _repo.signIn();
  }

  @override
  void dispose() {
    _repo.dispose();
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
