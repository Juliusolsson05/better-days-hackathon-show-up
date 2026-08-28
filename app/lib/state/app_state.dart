import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/notifications.dart';
import '../data/repository.dart';
import '../models/models.dart';

typedef NotificationPermissionRequest = Future<bool> Function();
typedef NotificationLadderSchedule =
    Future<void> Function(Group group, {bool demo});

/// ChangeNotifier rather than a state-management package: one less dependency, and the
/// app has exactly one piece of global state -- where you are in the flow.
class AppState extends ChangeNotifier {
  AppState(
    this.repo, {
    Phase initialPhase = Phase.onboarding,
    this.referenceUiPreview = false,
    NotificationPermissionRequest? requestNotificationPermission,
    NotificationLadderSchedule? scheduleNotificationLadder,
  }) : _requestNotificationPermission =
           requestNotificationPermission ??
           NotificationService.instance.requestPermission,
       _scheduleNotificationLadder =
           scheduleNotificationLadder ??
           NotificationService.instance.scheduleLadder,
       phase = initialPhase;
  final Repository repo;

  // Platform plugins are unavailable in Dart VM widget tests and can also fail on a real device
  // when an OS service is temporarily unavailable. Keeping only these two narrow operations behind
  // function seams lets AppState own the product fallback while tests inject deterministic failures;
  // it avoids replacing the repository or teaching the production notification service about tests.
  final NotificationPermissionRequest _requestNotificationPermission;
  final NotificationLadderSchedule _scheduleNotificationLadder;

  /// The reference build deliberately models screens that do not yet have backend
  /// contracts. Making preview eligibility constructor-owned keeps tests explicit and,
  /// more importantly, prevents a restored Supabase session from drifting into static
  /// sample data merely because Flutter happens to be running in debug mode.
  final bool referenceUiPreview;

  Phase phase;
  Profile? me;
  Group? group;
  Assignment? assignment;
  List<MutualContact> contacts = const [];

  /// Reconstruct the durable phase after a process restart. Auth restoration alone is not enough:
  /// a verified user may still need onboarding, while an onboarded user may be waiting or already
  /// matched. Keeping this decision here stops the app shell from duplicating repository reads.
  Future<void> restore() async {
    if (!await repo.isSignedIn()) {
      phase = Phase.auth;
      notifyListeners();
      return;
    }

    await _loadAuthenticatedPhase();
    notifyListeners();
  }

  Future<void> _loadAuthenticatedPhase() async {
    if (!await repo.hasProfile()) {
      phase = Phase.onboarding;
      return;
    }
    await _loadProductPhase();
  }

  /// Null until we have asked. False means the user declined, which the group screen
  /// uses to show an in-app countdown instead -- a denied permission must degrade the
  /// experience, never block the flow.
  bool? notificationsEnabled;

  /// Email OTP, step one. Throws on failure so the auth screen can surface it.
  Future<void> sendEmailOtp(String email) => repo.sendEmailOtp(email);

  /// Email OTP, step two. A verified session may belong either to a new signup or to somebody
  /// returning after reinstalling, so authentication success alone cannot choose onboarding.
  Future<void> verifyEmailOtp(String email, String token) async {
    await repo.verifyEmailOtp(email, token);
    // Reuse the same server-owned decision as cold-start restoration. Forcing onboarding here
    // would invite an existing user to overwrite their profile merely because this device did not
    // retain the session; a genuinely new user still has no profile and takes the onboarding arm.
    await _loadAuthenticatedPhase();
    notifyListeners();
  }

  Future<void> completeOnboarding(Profile p) async {
    me = p;
    if (referenceUiPreview) {
      phase = Phase.home;
    } else {
      // Profile completion is durable, but matching is server-owned. Reading the
      // repository immediately avoids both invented client-side matches and a brief
      // trip through the static reference shell before the waiting/chat destination.
      await _loadProductPhase();
    }
    notifyListeners();
  }

  /// The approved mock permits skipping onboarding. This changes only presentation state;
  /// it deliberately does not create a fake backend profile or smuggle placeholder data
  /// through the repository contract.
  void skipOnboarding() {
    // Only the approved preview has somewhere legitimate to skip to. In every other
    // configuration the waiting screen is the safest non-fabricated destination; the
    // real onboarding UI does not expose this control, so no backend profile is implied.
    phase = referenceUiPreview ? Phase.home : Phase.waiting;
    notifyListeners();
  }

  Future<void> _loadProductPhase() async {
    group = await repo.currentGroup();
    if (group == null) {
      assignment = null;
      phase = Phase.waiting;
      return;
    }
    assignment = await repo.assignment(group!.id);
    // event_at is the start, not the end. A two-hour grace period avoids asking someone to
    // reflect while the meetup is still happening, and the completion row distinguishes a
    // genuine "selected nobody" result from a person who has not seen this flow yet.
    final reflectionIsDue = group!.eventAt
        .add(const Duration(hours: 2))
        .isBefore(DateTime.now());
    final completed = reflectionIsDue
        ? await repo.hasCompletedAfterFlow(group!.id)
        : false;
    phase = reflectionIsDue && !completed ? Phase.after : Phase.matched;
  }

  /// Group formation and the chat opening are the same event -- there is no lobby.
  Future<void> enterGroup() async {
    group = await repo.currentGroup();
    if (group == null) return;
    assignment = await repo.assignment(group!.id);
    phase = Phase.matched;
    notifyListeners();
    // Arm the ladder only once the user is actually looking at their group. Asking for
    // notification permission at launch, before they know what the app is, is how you get
    // a denial -- and on iOS a denial is close to permanent.
    unawaited(armLadder());
  }

  /// Requests permission and schedules the five rungs.
  ///
  /// [demo] compresses the ladder into seconds so it can be shown on stage; the real one
  /// spans three days and is otherwise impossible to demo.
  Future<void> armLadder({bool demo = false}) async {
    if (group == null) return;

    try {
      notificationsEnabled = await _requestNotificationPermission();
      if (notificationsEnabled != true) {
        notifyListeners();
        return;
      }
      await _scheduleNotificationLadder(group!, demo: demo);
    } catch (error) {
      // enterGroup deliberately does not await this work because opening the chat must never wait
      // on an OS prompt or scheduler. That makes this catch the ownership boundary for failures:
      // letting one escape would become an unhandled asynchronous error, while recording false
      // gives both the direct caller and the UI the same observable degraded state as a denial.
      notificationsEnabled = false;
      if (kDebugMode) debugPrint('notification ladder unavailable: $error');
      notifyListeners();
      return;
    }

    await repo.track('notif_sent', groupId: group!.id, props: {'demo': demo});
    notifyListeners();
  }

  /// Routes a tapped notification. The rung is the routing key so we never parse copy to
  /// work out where the user meant to go.
  Future<void> handleNotificationTap(NotificationTap tap) async {
    if (group == null) {
      // Cold start straight from a notification: the group has not been loaded yet.
      await enterGroup();
      if (group == null) return;
    }

    // A stale notification from an earlier weekly group must never mutate or route the newest
    // group. Its deterministic payload is the only trustworthy link back to what was scheduled.
    if (group!.id != tap.groupId) return;

    await repo.track(
      'notif_opened',
      groupId: tap.groupId,
      props: {'rung': tap.rung.name, 'action': ?tap.action},
    );

    // A lock-screen RSVP is the whole point of the buttons -- honour it before routing.
    if (tap.action == 'rsvp_yes' || tap.action == 'rsvp_no') {
      await repo.setRsvp(
        tap.groupId,
        tap.action == 'rsvp_yes' ? RsvpStatus.confirmed : RsvpStatus.declined,
      );
      phase = Phase.matched;
      notifyListeners();
      return;
    }

    phase = switch (tap.rung) {
      Rung.reveal ||
      Rung.confirm ||
      Rung.morning ||
      Rung.doorway => Phase.matched,
      Rung.reflect => Phase.after,
    };
    notifyListeners();
  }

  /// Refresh server-owned group facts without replaying the navigation transition.
  ///
  /// The final venue ballot updates `groups.chosen_venue_id` inside Postgres. Reloading only the
  /// group lets every surface observe that decision immediately while leaving the private
  /// assignment and current phase alone; calling [enterGroup] here would conflate a data refresh
  /// with entering the room and make future transition side effects run twice.
  Future<void> refreshGroup() async {
    final currentId = group?.id;
    final refreshed = await repo.currentGroup();
    // A new weekly match can become the repository's newest group while this State still owns a
    // realtime stream for the previous room. Swapping only the Group object would pair old chat
    // messages with a new roster; navigation/restoration owns that larger lifecycle transition.
    if (refreshed == null || refreshed.id != currentId) return;
    group = refreshed;
    notifyListeners();
  }

  void goTo(Phase p) {
    phase = p;
    notifyListeners();
  }

  Future<void> loadContacts() async {
    if (group == null) return;
    contacts = await repo.mutualContacts(group!.id);
    phase = Phase.contacts;
    notifyListeners();
  }
}
