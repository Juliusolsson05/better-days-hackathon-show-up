import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// Between signup and the sweep. The PRD's only user decision is attend or don't, so
/// there is deliberately nothing to do here -- the screen polls for the group in the
/// background and tears itself down the moment one exists.
class WaitingScreen extends StatefulWidget {
  final AppState state;
  const WaitingScreen(this.state, {super.key});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Stands in for the "your group has formed" push. Once run-matching has placed this
    // user, enterGroup() flips the phase to matched and this screen is disposed. Against
    // MockRepository currentGroup() stays null until the dev menu forms one, so this is a
    // harmless no-op there.
    _poll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => widget.state.enterGroup(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('🕯️', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 24),
              const Text("You're in.",
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                'We match on Monday. You will get a notification when your group forms —\n'
                'nothing to do until then.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), height: 1.5),
              ),
              const SizedBox(height: 36),
              OutlinedButton(
                onPressed: () => widget.state.enterGroup(),
                child: const Text('Check for my group now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
