import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';

/// The push ladder.
///
/// Notifications are not a feature bolted onto this product -- between signup and the
/// event they ARE the product. The user makes one decision (attend or don't) and then has
/// to actually do it three days later, and that gap is where the whole thing fails.
///
/// Everything here is scheduled ON-DEVICE with flutter_local_notifications. Server-driven
/// push would need an APNs key, which needs a paid Apple Developer membership we do not
/// have. That constraint turns out to have an upside for the demo: nothing fires over the
/// network, so a room with 400 people on one wifi cannot break it.
///
/// The honest limits of client scheduling, so nobody mistakes this for production:
///   - cannot reach a user who has not opened the app since being matched
///   - cannot be revised after scheduling (a venue change three days out never lands)
///   - cannot survive a reinstall
///   - delivery is unobservable; we know we scheduled, not that it arrived
enum Rung { reveal, confirm, morning, doorway, reflect }

/// Each rung is expressed as an offset from `eventAt` rather than a wall-clock time.
///
/// This deliberately avoids timezone arithmetic. An offset from an absolute instant is
/// still an absolute instant, so the ladder is correct no matter what `tz.local` resolves
/// to -- see the note in [_toTz]. "Morning of" is -10h because the PRD's evening slot is
/// 19:00, which puts it at 09:00 the same day.
const ladderOffsets = <Rung, Duration>{
  Rung.reveal: Duration(days: -3),
  Rung.confirm: Duration(days: -1),
  Rung.morning: Duration(hours: -10),
  Rung.doorway: Duration(minutes: -10),
  Rung.reflect: Duration(hours: 2),
};

/// Where a tapped notification should take the user. The rung is the routing key, so the
/// app never has to parse copy to work out intent.
class NotificationTap {
  const NotificationTap(this.groupId, this.rung, {this.action});
  final String groupId;
  final Rung rung;

  /// Set when the user hit a button on the notification instead of the body itself.
  /// 'rsvp_yes' | 'rsvp_no'.
  final String? action;
}

/// iOS category that carries the two RSVP buttons. Registered at init; referenced by
/// `categoryIdentifier` on the reveal rung only.
///
/// The buttons exist because the product asks for exactly one decision, and every screen
/// between the user and that decision loses some of them. Answering from the lock screen
/// is the shortest possible path.
const _rsvpCategoryId = 'showup.rsvp';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<NotificationTap>.broadcast();

  /// Listened to by the app shell to route taps. Broadcast because a cold-start tap and a
  /// warm tap arrive through different plugin callbacks and both funnel in here.
  Stream<NotificationTap> get taps => _taps.stream;

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();

    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        // All four permission flags are false here on purpose: initialize() would
        // otherwise prompt on first launch, before the user knows what the app is, and an
        // iOS denial is effectively permanent. We ask later, from requestPermission().
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
          notificationCategories: <DarwinNotificationCategory>[
            DarwinNotificationCategory(
              _rsvpCategoryId,
              actions: <DarwinNotificationAction>[
                DarwinNotificationAction.plain('rsvp_yes', "I'm in"),
                DarwinNotificationAction.plain('rsvp_no', "Can't make it"),
              ],
            ),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );

    // A tap that launched the app from cold does NOT arrive through the callback above --
    // it is waiting here instead. Handling only the warm path is a bug that shows up
    // exactly once, on the demo phone, at the worst time.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final r = launch!.notificationResponse;
      if (r != null) _onResponse(r);
    }

    _ready = true;
  }

  void _onResponse(NotificationResponse r) {
    final tap = _decode(r.payload, r.actionId);
    if (tap != null) _taps.add(tap);
  }

  /// Ask for permission at the moment the value is obvious -- right after the group
  /// reveal, never at launch. Returns false if denied so the caller can fall back to an
  /// in-app banner rather than silently losing the ladder.
  Future<bool> requestPermission() async {
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  /// Schedules the whole ladder for a group.
  ///
  /// [demo] compresses every rung to a few seconds apart. That is not a debug leftover:
  /// the real ladder spans three days, so without it the notification system -- the part
  /// of this product that carries the story -- cannot be shown on stage at all.
  Future<void> scheduleLadder(Group group, {bool demo = false}) async {
    await init();
    await cancelLadder(group.id);

    final now = DateTime.now();
    for (final rung in Rung.values) {
      final when = demo
          // ~7s apart, so the full ladder plays in well under a minute.
          ? now.add(Duration(seconds: 5 + rung.index * 7))
          : group.eventAt.add(ladderOffsets[rung]!);

      // Never fire a rung whose moment has already passed. Scheduling one in the past
      // makes iOS deliver it immediately, so a user matched two days before the event
      // would get the T-3d reveal and the T-1d confirm stacked on top of each other.
      if (when.isBefore(now)) continue;

      await _plugin.zonedSchedule(
        id: notificationIdFor(group.id, rung),
        title: _title(rung, group),
        body: _body(rung, group),
        scheduledDate: _toTz(when),
        payload: jsonEncode({'group_id': group.id, 'rung': rung.name}),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        notificationDetails: NotificationDetails(
          iOS: DarwinNotificationDetails(
            // Only the reveal carries buttons; the rest are informational and a button
            // on them would be a second job for a rung that already has one.
            categoryIdentifier: rung == Rung.reveal ? _rsvpCategoryId : null,
            // Deliberately NOT interruptionLevel.timeSensitive, tempting as it is for the
            // doorway rung: that needs the Time Sensitive Notifications entitlement,
            // which needs a paid developer account.
            interruptionLevel: InterruptionLevel.active,
            threadIdentifier: group.id,
          ),
          android: AndroidNotificationDetails(
            'ladder', 'Meetup reminders',
            channelDescription: 'Reminders for the meetup you were matched into',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }
  }

  Future<void> cancelLadder(String groupId) async {
    for (final rung in Rung.values) {
      await _plugin.cancel(id: notificationIdFor(groupId, rung));
    }
  }

  /// What is actually queued. Used by the dev menu to prove the ladder is armed without
  /// waiting three days to find out it is not.
  Future<List<PendingNotificationRequest>> pending() => _plugin.pendingNotificationRequests();

  /// The instant is already correct in [dt] -- this only re-expresses it in a location.
  /// `tz.local` falls back to UTC when the platform timezone was never set, which is
  /// harmless here precisely because every rung is derived from an absolute DateTime
  /// rather than constructed from wall-clock parts.
  tz.TZDateTime _toTz(DateTime dt) => tz.TZDateTime.from(dt, tz.local);

  // ---- copy -------------------------------------------------------------------------
  //
  // Each rung has a different job; four variations of "don't forget!" would waste three of
  // them. Two rules hold across all of them:
  //
  //   Never guilt. No "you haven't responded", no "your group is waiting", no streaks.
  //   This is a loneliness product and obligation-shaped copy is actively harmful.
  //
  //   Name people and places. A notification should answer "where and when" without the
  //   user having to open the app.

  String _title(Rung rung, Group g) {
    final day = DateFormat('EEEE').format(g.eventAt);
    switch (rung) {
      case Rung.reveal:
        return "You're in for $day.";
      case Rung.confirm:
        return 'Tomorrow, ${DateFormat('h:mm a').format(g.eventAt)}.';
      case Rung.morning:
        return 'Tonight at ${DateFormat('h').format(g.eventAt)}.';
      case Rung.doorway:
        return "You're close.";
      case Rung.reflect:
        return 'How was it?';
    }
  }

  String _body(Rung rung, Group g) {
    final venue = g.chosenVenue ?? (g.venueOptions.isNotEmpty ? g.venueOptions.first : null);
    final place = venue?.name ?? 'the venue';
    final others = g.members.where((m) => m.id != 'me').map((m) => m.displayName).toList();
    final first = others.isNotEmpty ? others.first : 'someone';

    switch (rung) {
      case Rung.reveal:
        return '${g.members.length} people, '
            '${DateFormat('h:mm a').format(g.eventAt)} at $place. In or out?';
      case Rung.confirm:
        return others.isEmpty
            ? 'The chat is open if you want to say hi.'
            : '${_names(others)}. The chat is open if you want to say hi.';
      case Rung.morning:
        return '$place, ${venue?.address ?? ''}. '
            '${others.length} people are coming.'.trim();
      case Rung.doorway:
        // The hardest moment in the product: walking alone into a room of strangers is
        // where people turn around and go home. Naming a place and one person converts
        // "find a group of strangers" into "find a table", which is a smaller task.
        return 'Look for the long table at $place — $first is already there.';
      case Rung.reflect:
        return 'One question about what $first said. Takes a minute.';
    }
  }

  String _names(List<String> names) {
    if (names.length <= 2) return names.join(' and ');
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }
}

/// Deterministic per (group, rung) so a reschedule replaces precisely those five rungs
/// rather than clearing every notification the app owns.
///
/// Two invariants ride on this and both fail silently if broken: the id must be STABLE
/// across calls (or cancelLadder misses and the user gets duplicates) and DISTINCT across
/// rungs (or one rung overwrites another and simply never arrives). Masked to 31 bits
/// because Android notification ids are signed 32-bit.
int notificationIdFor(String groupId, Rung rung) =>
    Object.hash(groupId, rung.index) & 0x7FFFFFFF;

NotificationTap? _decode(String? payload, String? actionId) {
  if (payload == null) return null;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final groupId = map['group_id'] as String?;
    final rungName = map['rung'] as String?;
    if (groupId == null || rungName == null) return null;
    return NotificationTap(
      groupId,
      Rung.values.firstWhere((r) => r.name == rungName, orElse: () => Rung.reveal),
      action: actionId,
    );
  } catch (_) {
    // A malformed payload must not take down a notification tap -- worst case the user
    // lands on the default screen instead of a deep link.
    return null;
  }
}

/// Runs in a separate isolate when an action button is hit while the app is backgrounded.
///
/// The vm:entry-point annotation is load-bearing: without it this is tree-shaken out of a
/// RELEASE build, and release is the only mode that runs on a physical iPhone. The buttons
/// would then do nothing in exactly the build being demoed.
///
/// It cannot touch app state -- different isolate, no shared memory. The RSVP is applied
/// when the app next opens and replays the tap.
@pragma('vm:entry-point')
void notificationBackgroundHandler(NotificationResponse response) {
  debugPrint('[ladder] background action: ${response.actionId} ${response.payload}');
}
