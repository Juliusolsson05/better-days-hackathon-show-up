import 'dart:async';

import 'package:flutter/material.dart';

import 'core/notifications.dart';
import 'core/theme.dart';
import 'data/repository.dart';
import 'models/models.dart';
import 'state/app_state.dart';
import 'features/after/after_flow.dart';
import 'features/after/contacts_screen.dart';
import 'features/group/group_chat_screen.dart';
import 'features/onboarding/auth_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/waiting_screen.dart';

class ShowUpApp extends StatefulWidget {
  const ShowUpApp({
    super.key,
    required this.repository,
    required this.initialPhase,
    this.restoreSession = true,
  });

  /// The composition root owns the concrete repository. Production passes SupabaseRepository;
  /// tests may pass a fixture without making the production library import or construct it.
  final Repository repository;
  final Phase initialPhase;
  final bool restoreSession;

  @override
  State<ShowUpApp> createState() => _ShowUpAppState();
}

class _ShowUpAppState extends State<ShowUpApp> {
  late final Repository _repo = widget.repository;
  late final AppState _state = AppState(
    _repo,
    initialPhase: widget.initialPhase,
  );
  late bool _restoring;
  Object? _restoreError;

  StreamSubscription<NotificationTap>? _tapSub;

  @override
  void initState() {
    super.initState();
    _restoring = widget.restoreSession;
    _repo.signIn();
    // Notification responses outlive individual screens. Subscribe before restoration so a
    // cold-start tap can be replayed once AppState has loaded the durable group.
    _tapSub = NotificationService.instance.taps.listen(
      _state.handleNotificationTap,
    );
    if (widget.restoreSession) _restore();
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
            child: switch (_state.phase) {
              Phase.auth => AuthScreen(_state),
              Phase.onboarding => OnboardingScreen(_state),
              Phase.waiting => WaitingScreen(_state),
              Phase.matched || Phase.during => GroupChatScreen(_state),
              Phase.after => AfterFlow(_state),
              Phase.contacts => ContactsScreen(_state),
            },
          );
        },
      ),
    );
  }
}
