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

  Phase phase;
  Profile? me;
  Group? group;
  Assignment? assignment;
  List<MutualContact> contacts = const [];

  /// Group ids whose automatic ladder handoff has already started in this app-state lifetime.
  ///
  /// Restoration and a notification tap can race through separate group-loading paths. Marking the
  /// attempt before launching its Future prevents two permission prompts and two schedules, while
  /// [armLadder] itself remains public so the explicit compressed demo control can still rerun it.
  final _automaticLadderAttempts = <String>{};

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
    // Profile completion is durable, but matching is server-owned. Reading the repository
    // immediately avoids both invented client-side matches and a trip through fixture UI.
    await _loadProductPhase();
    notifyListeners();
  }

  Future<void> _loadProductPhase() async {
    group = await repo.currentGroup();
    if (group == null) {
      assignment = null;
      phase = Phase.waiting;
      return;
    }
    final lifecycle = await repo.experienceState(group!.id);
    if (lifecycle == ExperienceState.completed ||
        lifecycle == ExperienceState.cancelled) {
      group = null;
      assignment = null;
      phase = Phase.waiting;
      return;
    }
    assignment = await repo.assignment(group!.id);
    phase = switch (lifecycle) {
      ExperienceState.preMeetup => Phase.matched,
      ExperienceState.during => Phase.during,
      ExperienceState.after => Phase.after,
      ExperienceState.completed || ExperienceState.cancelled => Phase.waiting,
    };
    if (lifecycle == ExperienceState.preMeetup) _armLadderOnce();
  }

  /// Group formation and the chat opening are the same event -- there is no lobby.
  Future<void> enterGroup() async {
    // Entering from Waiting is not proof that the meetup is still upcoming. A backgrounded app
    // can sit on that screen until well after the event, and forcing `matched` here would bypass
    // the server-backed after-flow completion check used during cold restoration. One resolver
    // must own both paths so elapsed wall time cannot create two different product histories.
    await _loadProductPhase();
    notifyListeners();
  }

  /// Revokes the durable membership before clearing local state. If the server write fails the
  /// room stays visible with an error at the call site; pretending to leave locally would keep
  /// receiving private messages and photos while telling the person they were safe.
  Future<void> leaveCurrentGroup() async {
    final current = group;
    if (current == null) return;
    await repo.leaveGroup(current.id);
    group = null;
    assignment = null;
    contacts = const [];
    phase = Phase.waiting;
    notifyListeners();
  }

  void _armLadderOnce() {
    final groupId = group?.id;
    if (groupId == null || !_automaticLadderAttempts.add(groupId)) return;
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
      // RSVP changes attendance intent, not lifecycle eligibility. Re-resolve the durable phase
      // after the write so a delayed lock-screen action cannot move a post-meetup user out of an
      // incomplete recap or reopen one they already completed.
      await _loadProductPhase();
      notifyListeners();
      return;
    }

    // A notification rung says why the app was opened; it is not durable navigation state. Local
    // notifications can be tapped days late, so routing from the rung alone let an old reflection
    // notification reopen a sealed after-flow and let a pre-event rung skip a now-due recap. The
    // current group time plus its completion row are the authoritative destination.
    await _loadProductPhase();
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

  /// Leave the completed recap at its durable endpoint. Returning to `matched` here would create a
  /// second client-only route into a lifecycle the server already marks completed.
  void finishCurrentExperience() {
    group = null;
    assignment = null;
    contacts = const [];
    phase = Phase.waiting;
    notifyListeners();
  }

  Future<void> loadContacts() async {
    if (group == null) return;
    contacts = await repo.mutualContacts(group!.id);
    phase = Phase.contacts;
    notifyListeners();
  }
}
