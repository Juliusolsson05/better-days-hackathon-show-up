import 'package:flutter_test/flutter_test.dart';
import 'package:showup/core/notifications.dart';

void main() {
  group('ladder ordering', () {
    // Every rung is an offset from eventAt, so a careless edit to one Duration reorders
    // the ladder without any error. The user then gets "Tonight at 7" the day before,
    // which is exactly the kind of bug nobody notices until it is on a real phone.
    test('rungs fire in narrative order, and only the reflection is after the event', () {
      final order = [Rung.reveal, Rung.confirm, Rung.morning, Rung.doorway, Rung.reflect];

      for (var i = 0; i < order.length - 1; i++) {
        expect(
          ladderOffsets[order[i]]!,
          lessThan(ladderOffsets[order[i + 1]]!),
          reason: '${order[i].name} must fire before ${order[i + 1].name}',
        );
      }

      for (final rung in Rung.values.where((r) => r != Rung.reflect)) {
        expect(ladderOffsets[rung]!.isNegative, isTrue,
            reason: '${rung.name} must fire before the event');
      }
      expect(ladderOffsets[Rung.reflect]!.isNegative, isFalse);
    });

    test('every rung has an offset', () {
      // A rung added to the enum without an offset throws a null assertion at schedule
      // time, on a device, rather than here.
      for (final rung in Rung.values) {
        expect(ladderOffsets[rung], isNotNull, reason: '${rung.name} has no offset');
      }
    });
  });

  group('notification ids', () {
    test('are stable across calls and distinct across rungs', () {
      const groupId = '2f8b1c34-0000-4000-8000-000000000001';

      // Stable: cancelLadder recomputes ids to cancel. If they drifted, the old rungs
      // would survive a reschedule and the user would get each notification twice.
      for (final rung in Rung.values) {
        expect(notificationIdFor(groupId, rung), notificationIdFor(groupId, rung));
      }

      // Distinct: a collision means one rung silently overwrites another and never fires.
      final ids = Rung.values.map((r) => notificationIdFor(groupId, r)).toSet();
      expect(ids.length, Rung.values.length);
    });

    test('are non-negative, because Android ids are signed 32-bit', () {
      for (final rung in Rung.values) {
        for (final g in ['a', 'another-group', '2f8b1c34-0000-4000-8000-000000000001']) {
          expect(notificationIdFor(g, rung), greaterThanOrEqualTo(0));
        }
      }
    });

    test('differ between groups, so two groups do not clobber each other', () {
      for (final rung in Rung.values) {
        expect(notificationIdFor('group-a', rung),
            isNot(notificationIdFor('group-b', rung)));
      }
    });
  });
}
