import 'package:flutter_test/flutter_test.dart';
import 'package:showup/core/notifications.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/models/models.dart';
import 'package:showup/state/app_state.dart';

Group _group() => Group(
  id: 'notification-test-group',
  eventAt: DateTime(2030, 1, 1, 19),
  members: const [Member(id: 'me', displayName: 'You', avatar: '🙂')],
  venueOptions: const [],
  activity: 'Conversation',
);

void main() {
  test(
    'unchosen venue candidates never leak into durable notification copy',
    () {
      final group = Group(
        id: 'open-vote',
        eventAt: DateTime(2030, 1, 1, 19),
        members: const [Member(id: 'me', displayName: 'You', avatar: '🙂')],
        venueOptions: const [
          VenueOption(
            id: 'candidate-one',
            name: 'Wrong Place If Option Two Wins',
            address: '1 Candidate St',
            pitch: '',
            categories: [],
          ),
        ],
        venueStatus: VenueStatus.voting,
        activity: 'Conversation',
      );

      for (final rung in [Rung.reveal, Rung.morning, Rung.doorway]) {
        expect(
          NotificationService.instance.notificationBody(rung, group),
          isNot(contains('Wrong Place If Option Two Wins')),
        );
      }
    },
  );

  group('ladder ordering', () {
    // Every rung is an offset from eventAt, so a careless edit to one Duration reorders
    // the ladder without any error. The user then gets "Tonight at 7" the day before,
    // which is exactly the kind of bug nobody notices until it is on a real phone.
    test(
      'rungs fire in narrative order, and only the reflection is after the event',
      () {
        final order = [
          Rung.reveal,
          Rung.confirm,
          Rung.morning,
          Rung.doorway,
          Rung.reflect,
        ];

        for (var i = 0; i < order.length - 1; i++) {
          expect(
            ladderOffsets[order[i]]!,
            lessThan(ladderOffsets[order[i + 1]]!),
            reason: '${order[i].name} must fire before ${order[i + 1].name}',
          );
        }

        for (final rung in Rung.values.where((r) => r != Rung.reflect)) {
          expect(
            ladderOffsets[rung]!.isNegative,
            isTrue,
            reason: '${rung.name} must fire before the event',
          );
        }
        expect(ladderOffsets[Rung.reflect]!.isNegative, isFalse);
      },
    );

    test('every rung has an offset', () {
      // A rung added to the enum without an offset throws a null assertion at schedule
      // time, on a device, rather than here.
      for (final rung in Rung.values) {
        expect(
          ladderOffsets[rung],
          isNotNull,
          reason: '${rung.name} has no offset',
        );
      }
    });
  });

  group('notification ids', () {
    test('are stable across calls and distinct across rungs', () {
      const groupId = '2f8b1c34-0000-4000-8000-000000000001';

      // Stable: cancelLadder recomputes ids to cancel. If they drifted, the old rungs
      // would survive a reschedule and the user would get each notification twice.
      for (final rung in Rung.values) {
        expect(
          notificationIdFor(groupId, rung),
          notificationIdFor(groupId, rung),
        );
      }

      // Distinct: a collision means one rung silently overwrites another and never fires.
      final ids = Rung.values.map((r) => notificationIdFor(groupId, r)).toSet();
      expect(ids.length, Rung.values.length);
    });

    test('are non-negative, because Android ids are signed 32-bit', () {
      for (final rung in Rung.values) {
        for (final g in [
          'a',
          'another-group',
          '2f8b1c34-0000-4000-8000-000000000001',
        ]) {
          expect(notificationIdFor(g, rung), greaterThanOrEqualTo(0));
        }
      }
    });

    test('differ between groups, so two groups do not clobber each other', () {
      for (final rung in Rung.values) {
        expect(
          notificationIdFor('group-a', rung),
          isNot(notificationIdFor('group-b', rung)),
        );
      }
    });
  });

  group('app-state degradation', () {
    test('a permission failure becomes observable disabled state', () async {
      final repo = MockRepository();
      addTearDown(repo.dispose);
      var scheduled = false;
      final state = AppState(
        repo,
        requestNotificationPermission: () async {
          throw StateError('platform plugin unavailable');
        },
        scheduleNotificationLadder: (group, {demo = false}) async {
          scheduled = true;
        },
      )..group = _group();

      // enterGroup launches this future without awaiting it. The direct call proves the same
      // future completes normally and leaves state the UI can inspect instead of merely hiding an
      // unhandled zone error that would still fail widget tests and occasionally crash debug runs.
      await state.armLadder();

      expect(state.notificationsEnabled, isFalse);
      expect(scheduled, isFalse);
      expect(repo.tracked, isEmpty);
    });

    test('a scheduling failure revokes an earlier permission success', () async {
      final repo = MockRepository();
      addTearDown(repo.dispose);
      final state = AppState(
        repo,
        requestNotificationPermission: () async => true,
        scheduleNotificationLadder: (group, {demo = false}) async {
          throw StateError('OS scheduler unavailable');
        },
      )..group = _group();

      // Permission alone is not enough to promise reminders. If queueing fails after permission
      // succeeds, false is the honest state and the success funnel event must not be emitted.
      await state.armLadder();

      expect(state.notificationsEnabled, isFalse);
      expect(repo.tracked, isEmpty);
    });
  });
}
