import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// The flaking acknowledgement (PRD step 10). Shown once, only to the person the group
/// voted absent. There is deliberately nothing to do here: no penalty, no appeal, and
/// nobody else is told. It exists so a no-show is met with a sentence rather than silence.
class NoShowSheet extends StatelessWidget {
  const NoShowSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 28),
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: accentPale,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.nightlight_round, size: 30, color: inkDeep),
          ),
          const SizedBox(height: 20),
          Text(
            'You missed the last one',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            "That's completely fine. Nothing happens, nobody was told, and you're in the "
            'next group automatically.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    );
  }
}
