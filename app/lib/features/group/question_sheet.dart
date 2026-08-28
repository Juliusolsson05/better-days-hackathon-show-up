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
    final assignment = state.assignment;
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
          Text(
            'Just for you',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Nobody else can see this, and everyone has one.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          if (assignment == null)
            // A neutral placeholder avoids fabricating a question while assignment() is still
            // loading. The private server row is the source of truth; a client-side fallback
            // could violate the one-target-per-member derangement matching guarantees.
            Container(
              height: 92,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(cardRadius),
              ),
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: accentPale,
                borderRadius: BorderRadius.circular(cardRadius),
              ),
              child: Text(
                assignment.question,
                style: const TextStyle(
                  color: ink,
                  fontSize: 18,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Your person is ${assignment.targetName}.',
              style: const TextStyle(
                color: inkDeep,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
