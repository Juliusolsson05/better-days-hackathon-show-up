import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
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
          padding: const EdgeInsets.all(24),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(cardRadius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    color: accentPale,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.groups_rounded,
                    size: 36,
                    color: inkDeep,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  "You're in.",
                  style: Theme.of(context).textTheme.displayMedium,
                ),
                const SizedBox(height: 14),
                Text(
                  'We match on Monday. You will get a notification when your group forms. '
                  'There is nothing to do until then.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                OutlinedButton(
                  onPressed: () => widget.state.enterGroup(),
                  child: const Text('Check for my group'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
