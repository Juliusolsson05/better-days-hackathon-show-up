import 'package:flutter/material.dart';

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
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('🕯️', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 24),
              const Text(
                "You're in.",
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                'We match on Monday. We will let you know when your group forms.\n'
                'You can also check whenever you reopen the app.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 36),
              OutlinedButton(
                onPressed: _checking ? null : _check,
                child: Text(_checking ? 'Checking…' : 'Check for my group'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
