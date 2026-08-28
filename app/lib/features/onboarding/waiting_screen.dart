import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';

/// Between signup and the sweep. The PRD's only user decision is attend or don't, so
/// there is deliberately nothing to do here. We check on app restoration and on an
/// explicit user request instead of running a blind timer: overlapping polls made a
/// temporary network failure unobservable and could race navigation during slow calls.
class WaitingScreen extends StatefulWidget {
  final AppState state;
  const WaitingScreen(this.state, {super.key});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  bool _checking = false;
  String? _error;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await widget.state.enterGroup();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not check yet. Try again.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
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
                  'We match on Monday. Check whenever you reopen the app to see whether '
                  'your group has formed.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                OutlinedButton(
                  // A slow or failed read must remain visible. Calling AppState directly
                  // discards that state and makes the button appear to do nothing when the
                  // network is the only thing preventing entry into an existing group.
                  onPressed: _checking ? null : _check,
                  child: Text(_checking ? 'Checking…' : 'Check for my group'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: negative,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
