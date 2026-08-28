import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

const _pendingBackgroundRsvpKey = 'showup.pending_notification_rsvp';

/// The three preference operations the background-action handoff actually needs.
///
/// Keeping this boundary smaller than SharedPreferences itself makes the cross-isolate protocol
/// testable without initializing a platform channel in a Dart VM test. Production uses the async,
/// uncached preferences API below because a cached instance in the main isolate cannot observe a
/// write made by flutter_local_notifications' background isolate.
@visibleForTesting
abstract interface class NotificationActionPreferences {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class _AsyncNotificationActionPreferences
    implements NotificationActionPreferences {
  _AsyncNotificationActionPreferences()
    : _preferences = SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> remove(String key) => _preferences.remove(key);
}

/// Durable bridge between the notification callback isolate and the app's main isolate.
///
/// A single slot is intentional. RSVP is mutable intent: if somebody taps "I'm in" and then
/// "Can't make it" before reopening the app, replaying both mutations creates needless traffic and
/// an intermediate lie. Overwriting the slot preserves the latest choice. [claim] removes before
/// returning so repeated lifecycle callbacks cannot apply that same physical action twice.
@visibleForTesting
class BackgroundNotificationActionStore {
  BackgroundNotificationActionStore({
    NotificationActionPreferences? preferences,
  }) : _preferences = preferences ?? _AsyncNotificationActionPreferences();

  final NotificationActionPreferences _preferences;

  Future<void> save(NotificationTap tap) {
    if (tap.action != 'rsvp_yes' && tap.action != 'rsvp_no') {
      throw ArgumentError.value(
        tap.action,
        'tap.action',
        'expected an RSVP action',
      );
    }
    return _preferences.setString(
      _pendingBackgroundRsvpKey,
      jsonEncode({
        'group_id': tap.groupId,
        'rung': tap.rung.name,
        'action': tap.action,
      }),
    );
  }

  Future<NotificationTap?> claim() async {
    final raw = await _preferences.getString(_pendingBackgroundRsvpKey);
    if (raw == null) return null;

    // Remove even malformed data. A damaged value must not become a permanent poison message that
    // retries on every foreground transition, and removing before publication gives the relay the
    // same at-most-once ownership rule it already applies to cold-launch notification responses.
    await _preferences.remove(_pendingBackgroundRsvpKey);
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final map = Map<String, dynamic>.from(value);
      final groupId = map['group_id'];
      final rungName = map['rung'];
      final action = map['action'];
      if (groupId is! String || rungName is! String || action is! String) {
        return null;
      }
      if (action != 'rsvp_yes' && action != 'rsvp_no') return null;
      final rung = _rungNamed(rungName);
      if (rung == null) return null;
      return NotificationTap(groupId, rung, action: action);
    } catch (_) {
      return null;
    }
  }
}

/// Only action buttons belong in the durable background handoff.
///
/// Notification body taps already reach the main-isolate callback or launch-details API. Saving
/// them here as well would make one physical tap navigate twice. Unknown actions are also ignored:
/// this background isolate cannot safely invent semantics for a future button.
@visibleForTesting
NotificationTap? decodeBackgroundRsvpTap(String? payload, String? actionId) {
  if (actionId != 'rsvp_yes' && actionId != 'rsvp_no') return null;
  return _decode(payload, actionId);
}

/// Relays notification responses without losing the one response produced before runApp().
///
/// The notification plugin exposes a cold-launch response during [NotificationService.init],
/// while the app cannot subscribe until after that method returns and runApp builds the shell.
/// A plain broadcast controller drops events with no listeners, which made every cold-launch
/// deep link disappear. Only that plugin-owned launch response is buffered here. Live callbacks
/// deliberately retain broadcast semantics so foreground/background delivery cannot be replayed
/// later as a second navigation or a second RSVP mutation.
@visibleForTesting
class NotificationTapRelay {
  NotificationTapRelay() {
    _controller = StreamController<NotificationTap>.broadcast(
      onListen: _flushInitialTap,
    );
  }

  late final StreamController<NotificationTap> _controller;
  NotificationTap? _pendingInitialTap;

  Stream<NotificationTap> get stream => _controller.stream;

  /// Publishes an ordinary plugin callback exactly once to the listeners that exist now.
  void publishLive(NotificationTap tap) => _controller.add(tap);

  /// Holds the plugin's one cold-launch response until the app installs its first listener.
  void publishInitial(NotificationTap tap) {
    if (_controller.hasListener) {
      _controller.add(tap);
      return;
    }

    // The platform API promises one launch response. Keeping the first if a buggy platform
    // implementation reports twice is safer than replacing the routing fact just before the app
    // subscribes, and still guarantees that one physical tap causes at most one app transition.
    _pendingInitialTap ??= tap;
  }

  void _flushInitialTap() {
    final tap = _pendingInitialTap;
    if (tap == null) return;

    // Clear before adding. A synchronous cancellation/re-listen from downstream must not observe
    // the same action twice; RSVP writes are idempotent today, but navigation side effects are not.
    _pendingInitialTap = null;
    _controller.add(tap);
  }

  @visibleForTesting
  Future<void> close() => _controller.close();
}

/// iOS category that carries the two RSVP buttons. Registered at init; referenced by
/// `categoryIdentifier` on the reveal rung only.
///
/// The buttons exist because the product asks for exactly one decision, and every screen
/// between the user and that decision loses some of them. Answering from the lock screen
/// is the shortest possible path.
const _rsvpCategoryId = 'showup.rsvp';

class NotificationService with WidgetsBindingObserver {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _tapRelay = NotificationTapRelay();
  // Construct preferences only when init actually replays actions. AppState references this
  // singleton in hermetic widget tests where main() intentionally never registers plugins; eager
  // construction would make an unrelated chat screen fail before its injected notification seams
  // can take effect. Runtime init and the background handler both run after plugin registration.
  late final _backgroundActions = BackgroundNotificationActionStore();

  /// Listened to by the app shell to route taps. Live taps remain broadcast events; the relay
  /// retains only the plugin's initial launch response because it necessarily predates runApp().
  Stream<NotificationTap> get taps => _tapRelay.stream;

  bool _ready = false;
  bool _observingLifecycle = false;
  Future<void>? _backgroundReplay;

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
      if (r != null) _onResponse(r, initialLaunch: true);
    }

    // A non-foreground RSVP action is delivered on another isolate and therefore cannot touch the
    // relay above. Claim it after plugin initialization; publishInitial buffers it until ShowUpApp
    // installs the listener immediately after runApp. The same method runs on resume for actions
    // taken while an already-running app was asleep.
    await _replayBackgroundRsvp();
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }

    _ready = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_replayBackgroundRsvp());
    }
  }

  Future<void> _replayBackgroundRsvp() {
    // init and a resume callback can occur close together on a cold launch. Sharing one in-flight
    // claim prevents two reads from observing the same stored action before either removes it.
    return _backgroundReplay ??= _claimAndPublishBackgroundRsvp().whenComplete(
      () => _backgroundReplay = null,
    );
  }

  Future<void> _claimAndPublishBackgroundRsvp() async {
    try {
      final tap = await _backgroundActions.claim();
      if (tap != null) _tapRelay.publishInitial(tap);
    } catch (error) {
      // Reminder delivery is an enhancement, while app startup and the live group are the product
      // path. A temporarily unavailable preferences channel must not convert a recoverable missed
      // lock-screen action into a failed launch or an unhandled lifecycle Future.
      debugPrint('[ladder] could not replay background RSVP: $error');
    }
  }

  void _onResponse(NotificationResponse r, {bool initialLaunch = false}) {
    final tap = _decode(r.payload, r.actionId);
    if (tap == null) return;
    if (initialLaunch) {
      _tapRelay.publishInitial(tap);
    } else {
      _tapRelay.publishLive(tap);
    }
  }

  /// Ask for permission at the moment the value is obvious -- right after the group
  /// reveal, never at launch. Returns false if denied so the caller can fall back to an
  /// in-app banner rather than silently losing the ladder.
  Future<bool> requestPermission() async {
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
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
            'ladder',
            'Meetup reminders',
            channelDescription:
                'Reminders for the meetup you were matched into',
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
  Future<List<PendingNotificationRequest>> pending() =>
      _plugin.pendingNotificationRequests();

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
    final venue =
        g.chosenVenue ??
        (g.venueOptions.isNotEmpty ? g.venueOptions.first : null);
    final place = venue?.name ?? 'the venue';
    final others = g.members
        .where((m) => m.id != 'me')
        .map((m) => m.displayName)
        .toList();
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
                '${others.length} people are coming.'
            .trim();
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
int notificationIdFor(String groupId, Rung rung) {
  // Object.hash is randomized between Dart processes on some runtimes. That looks stable in a
  // unit test but leaves old notifications impossible to cancel after an app restart. FNV-1a is
  // deliberately boring and deterministic across both process and platform boundaries.
  var hash = 0x811C9DC5;
  for (final unit in '$groupId:${rung.index}'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

NotificationTap? _decode(String? payload, String? actionId) {
  if (payload == null) return null;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final groupId = map['group_id'] as String?;
    final rungName = map['rung'] as String?;
    if (groupId == null || rungName == null) return null;
    final rung = _rungNamed(rungName);
    if (rung == null) return null;
    return NotificationTap(groupId, rung, action: actionId);
  } catch (_) {
    // A malformed payload must not take down a notification tap -- worst case the user
    // lands on the default screen instead of a deep link.
    return null;
  }
}

Rung? _rungNamed(String name) {
  for (final rung in Rung.values) {
    if (rung.name == name) return rung;
  }
  return null;
}

/// Runs in a separate isolate when an action button is hit while the app is backgrounded.
///
/// The vm:entry-point annotation is load-bearing: without it this is tree-shaken out of a
/// RELEASE build, and release is the only mode that runs on a physical iPhone. The buttons
/// would then do nothing in exactly the build being demoed.
///
/// It cannot touch app state -- different isolate, no shared memory. It therefore writes the
/// decoded RSVP intent through an uncached platform preference and lets NotificationService claim
/// it on init/resume. Trying to call Supabase here would require reconstructing auth/session state
/// inside an isolate the app does not own and would turn a lock-screen tap into a second login path.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(
  NotificationResponse response,
) async {
  final tap = decodeBackgroundRsvpTap(response.payload, response.actionId);
  if (tap == null) return;

  try {
    // The notification plugin registers its own callback entry point, but plugins used *from* that
    // isolate still need the generated registrant before their platform channels are available.
    DartPluginRegistrant.ensureInitialized();
    await BackgroundNotificationActionStore().save(tap);
  } catch (error) {
    // There is no UI on this isolate. Logging is the only honest fallback; throwing would make the
    // OS consider the callback failed without giving the person any recovery path at all.
    debugPrint('[ladder] could not persist background RSVP: $error');
  }
}
