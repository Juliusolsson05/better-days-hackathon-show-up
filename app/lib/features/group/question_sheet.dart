import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';

/// Your private assignment. Never revealed to the group -- everyone has one, and
/// matching guarantees every member is somebody's target, so nobody is left out.
class QuestionSheet extends StatelessWidget {
  final AppState state;
  const QuestionSheet(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final a = state.assignment;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 24),
        const Text('Just for you',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Nobody else can see this, and everyone has one.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, color: Colors.white.withValues(alpha: 0.55))),
        const SizedBox(height: 24),
        if (a == null)
          const CircularProgressIndicator()
        else ...[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withValues(alpha: 0.4)),
            ),
            child: Text(a.question,
                style: const TextStyle(fontSize: 16, height: 1.45)),
          ),
          const SizedBox(height: 20),
          Text('Your person is ${a.targetName}.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
        ],
      ]),
    );
  }
}
