import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// Between signup and the sweep. The PRD's only user decision is attend or don't, so
/// there is deliberately nothing to do here.
class WaitingScreen extends StatelessWidget {
  final AppState state;
  const WaitingScreen(this.state, {super.key});

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
              // Stands in for the matching sweep having run. Real build: push notification.
              OutlinedButton(
                onPressed: state.enterGroup,
                child: const Text('Simulate the sweep running'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
