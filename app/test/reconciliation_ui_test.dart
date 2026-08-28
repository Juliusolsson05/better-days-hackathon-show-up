import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/features/after/after_flow.dart';
import 'package:showup/features/group/group_info_screen.dart';
import 'package:showup/features/group/venue_vote_card.dart';
import 'package:showup/state/app_state.dart';

class _FailingVoteRepository extends MockRepository {
  @override
  Future<void> castVenueVote(String groupId, String optionId) async {
    throw StateError('offline');
  }
}

Future<AppState> _formedState(
  WidgetTester tester,
  MockRepository repository,
) async {
  repository.formGroup();
  final state = AppState(repository);
  final entering = state.enterGroup();
  // Mock latency uses timers on purpose. Widget tests own a fake clock, so advance it while the
  // future is pending rather than awaiting a timer that cannot fire outside tester.pump().
  await tester.pump(const Duration(seconds: 1));
  await entering;
  return state;
}

void main() {
  testWidgets(
    'group info never presents option one as the chosen destination',
    (tester) async {
      final repository = MockRepository();
      final state = await _formedState(tester, repository);

      await tester.pumpWidget(MaterialApp(home: GroupInfoScreen(state)));

      expect(find.textContaining('Voting is still open'), findsOneWidget);
      expect(find.text('Kinship'), findsNothing);
      repository.dispose();
    },
  );

  testWidgets('a failed venue vote rolls back and offers retry feedback', (
    tester,
  ) async {
    final repository = _FailingVoteRepository();
    final state = await _formedState(tester, repository);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: VenueVoteCard(state))),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Kinship'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Your vote did not save. Try again.'), findsOneWidget);
    repository.dispose();
  });

  testWidgets('an empty reflection cannot advance the durable after flow', (
    tester,
  ) async {
    final repository = MockRepository();
    final state = await _formedState(tester, repository);

    await tester.pumpWidget(MaterialApp(home: AfterFlow(state)));
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.text('Write one thing that stuck with you.'), findsOneWidget);
    expect(find.text('What stuck'), findsOneWidget);
    repository.dispose();
  });
}
