import 'package:flutter_test/flutter_test.dart';
import 'package:showup/core/notifications.dart';

class _MemoryNotificationPreferences implements NotificationActionPreferences {
  final values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test('the cold-launch tap waits for the first app subscriber exactly once', () async {
    final relay = NotificationTapRelay();
    addTearDown(relay.close);
    const launchTap = NotificationTap(
      'group-from-launch',
      Rung.reflect,
      action: 'rsvp_yes',
    );

    // NotificationService.init runs before runApp, so this order is the regression: publishing
    // into the old broadcast controller here permanently discarded the route.
    relay.publishInitial(launchTap);
    // Some platform versions have historically delivered overlapping launch signals. Even if
    // that happens, one physical response must not become two routes or two RSVP writes.
    relay.publishInitial(launchTap);

    final delivered = await relay.stream.first.timeout(
      const Duration(seconds: 1),
    );
    expect(delivered.groupId, 'group-from-launch');
    expect(delivered.rung, Rung.reflect);
    expect(delivered.action, 'rsvp_yes');

    final replayed = <NotificationTap>[];
    final secondSubscriber = relay.stream.listen(replayed.add);
    await Future<void>.delayed(Duration.zero);
    await secondSubscriber.cancel();

    // Clearing before delivery matters: rebuilding the app shell must not repeat navigation or
    // apply an RSVP action a second time merely because it installed a replacement listener.
    expect(replayed, isEmpty);
  });

  test('live callbacks stay broadcast-only and are never replayed', () async {
    final relay = NotificationTapRelay();
    addTearDown(relay.close);
    const liveTap = NotificationTap('live-group', Rung.confirm);

    // A live event with no subscriber is not reclassified as a launch event. Buffering every
    // callback would let foreground/background delivery reappear later as duplicate navigation.
    relay.publishLive(liveTap);

    final delivered = <NotificationTap>[];
    final subscriber = relay.stream.listen(delivered.add);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);

    relay.publishLive(liveTap);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
    expect(delivered.single.groupId, 'live-group');

    await subscriber.cancel();
  });

  test('background RSVP is claimed and relayed exactly once', () async {
    final preferences = _MemoryNotificationPreferences();
    final store = BackgroundNotificationActionStore(preferences: preferences);
    final relay = NotificationTapRelay();
    addTearDown(relay.close);

    // RSVP is mutable intent, so the last button tapped while the UI sleeps is authoritative. A
    // single durable slot prevents a rapid correction from replaying a misleading intermediate
    // state before the choice the person actually settled on.
    await store.save(
      const NotificationTap(
        'background-group',
        Rung.reveal,
        action: 'rsvp_yes',
      ),
    );
    await store.save(
      const NotificationTap('background-group', Rung.reveal, action: 'rsvp_no'),
    );

    final claimed = await store.claim();
    expect(claimed?.groupId, 'background-group');
    expect(claimed?.rung, Rung.reveal);
    expect(claimed?.action, 'rsvp_no');
    expect(await store.claim(), isNull);

    relay.publishInitial(claimed!);
    final delivered = await relay.stream.first;
    expect(delivered.action, 'rsvp_no');

    final replayed = <NotificationTap>[];
    final secondSubscriber = relay.stream.listen(replayed.add);
    await Future<void>.delayed(Duration.zero);
    await secondSubscriber.cancel();
    expect(replayed, isEmpty);
  });

  test('background decoder accepts RSVP buttons and rejects body taps', () {
    const payload = '{"group_id":"g1","rung":"reveal"}';

    expect(decodeBackgroundRsvpTap(payload, null), isNull);
    expect(decodeBackgroundRsvpTap(payload, ''), isNull);
    expect(decodeBackgroundRsvpTap(payload, 'future_action'), isNull);

    final tap = decodeBackgroundRsvpTap(payload, 'rsvp_yes');
    expect(tap?.groupId, 'g1');
    expect(tap?.rung, Rung.reveal);
    expect(tap?.action, 'rsvp_yes');
  });
}
