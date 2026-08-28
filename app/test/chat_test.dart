import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/core/theme.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/features/group/group_chat_screen.dart';
import 'package:showup/models/models.dart';
import 'package:showup/state/app_state.dart';

/// Drives the message stream by hand.
///
/// Extends MockRepository rather than reimplementing Repository so this file does not
/// have to be edited every time a method is added to the seam -- the point here is the
/// chat's rendering of message state, not the breadth of the interface.
class _ChatStub extends MockRepository {
  // Synchronous delivery makes the fixture deterministic: the assertion's pump rebuilds
  // from the value just pushed instead of racing a broadcast microtask that may run after
  // the test has already inspected the tree. Production Realtime remains asynchronous.
  final _controller = StreamController<List<Message>>.broadcast(sync: true);
  final retried = <String>[];
  final seen = <String>[];
  int watches = 0;

  @override
  Stream<List<Message>> watchMessages(String groupId) {
    watches++;
    return _controller.stream;
  }

  @override
  Future<void> retryMessage(String groupId, Message failed) async {
    retried.add(failed.clientMsgId ?? '');
  }

  @override
  Future<void> track(
    String event, {
    String? groupId,
    Map<String, dynamic> props = const {},
  }) async {
    seen.add(event);
  }

  void push(List<Message> msgs) => _controller.add(msgs);

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

Message _msg(String body, MessageStatus status, {String id = 'c1'}) => Message(
  id: 'pending-$id',
  authorId: 'me',
  authorName: 'You',
  avatar: '🙂',
  body: body,
  sentAt: DateTime.now(),
  clientMsgId: id,
  status: status,
);

Future<AppState> _mounted(WidgetTester tester, _ChatStub repo) async {
  final state = AppState(repo, initialPhase: Phase.matched);
  // Do not ask MockRepository.currentGroup() here. Its deliberate 350 ms network delay
  // runs on WidgetTester's fake clock, and awaiting it before the first pump deadlocks the
  // test: only pump() advances that clock. The chat only needs a stable group id and
  // event time for these rendering contracts, so an explicit fixture is both smaller and
  // more honest than teaching production code about the test harness.
  state.group = Group(
    id: 'g1',
    eventAt: DateTime(2030, 1, 1, 19),
    members: const [Member(id: 'me', displayName: 'You', avatar: '🙂')],
    venueOptions: const [],
    activity: 'Conversation',
  );
  await tester.pumpWidget(
    MaterialApp(theme: buildTheme(), home: GroupChatScreen(state)),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('a message that failed to send is visible and retryable', (
    tester,
  ) async {
    // The product reason this is tested: in a loneliness app the worst version of a
    // dropped send is a user believing they reached out and nobody answered, when in fact
    // nothing was ever delivered.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _ChatStub();
    addTearDown(repo.dispose);
    await _mounted(tester, repo);

    repo.push([_msg('did this send?', MessageStatus.failed)]);
    await tester.pump();

    expect(find.text('Not sent'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    // Retried under its ORIGINAL client id -- that is what makes the retry idempotent
    // against the unique index rather than a second copy of the message.
    expect(repo.retried, ['c1']);
  });

  testWidgets('an in-flight message shows without a failure affordance', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _ChatStub();
    addTearDown(repo.dispose);
    await _mounted(tester, repo);

    repo.push([_msg('on its way', MessageStatus.sending)]);
    await tester.pump();

    expect(find.text('on its way'), findsOneWidget);
    // Sending is the overwhelmingly common case and resolves in a few hundred ms; badging
    // it would put an error-shaped affordance on almost every message the user sends.
    expect(find.text('Not sent'), findsNothing);
  });

  testWidgets('opening the chat emits the funnel event', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _ChatStub();
    addTearDown(repo.dispose);
    await _mounted(tester, repo);

    // Nothing else emits this, and the dashboard funnel cannot distinguish "matched and
    // ignored it" from "matched and looked" without it.
    expect(repo.seen, contains('chat_opened'));
  });

  testWidgets('widget rebuilds retain one message subscription', (
    tester,
  ) async {
    // This is the regression PR #9 could not expose with MockRepository: its broadcast
    // stream is cheap to ask for repeatedly, while SupabaseRepository opens a Realtime
    // channel per call. A keyboard or viewport change rebuilds the screen frequently, so
    // the stream must belong to State's lifetime rather than build().
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _ChatStub();
    addTearDown(repo.dispose);
    await _mounted(tester, repo);
    expect(repo.watches, 1);

    tester.view.physicalSize = const Size(1179, 2556);
    await tester.pump();

    expect(repo.watches, 1);
  });
}
