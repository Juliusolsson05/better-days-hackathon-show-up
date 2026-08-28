import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/notifications.dart';
import '../data/repository.dart';
import '../models/models.dart';

/// ChangeNotifier rather than a state-management package: one less dependency, and the
/// app has exactly one piece of global state -- where you are in the flow.
class AppState extends ChangeNotifier {
  AppState(this.repo, {Phase initialPhase = Phase.onboarding}) : phase = initialPhase;
  final Repository repo;

  Phase phase;
  Profile? me;
  Group? group;
  Assignment? assignment;
  List<MutualContact> contacts = const [];

  /// Null until we have asked. False means the user declined, which the group screen
  /// uses to show an in-app countdown instead -- a denied permission must degrade the
  /// experience, never block the flow.
  bool? notificationsEnabled;

  /// Email OTP, step one. Throws on failure so the auth screen can surface it.
  Future<void> sendEmailOtp(String email) => repo.sendEmailOtp(email);

  /// Email OTP, step two. On success we land in onboarding -- a signed-in user without
  /// a profile is exactly the signup case.
  Future<void> verifyEmailOtp(String email, String token) async {
    await repo.verifyEmailOtp(email, token);
    phase = Phase.onboarding;
    notifyListeners();
  }

  Future<void> completeOnboarding(Profile p) async {
    me = p;
    phase = Phase.waiting;
    notifyListeners();
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
    notificationsEnabled = await NotificationService.instance.requestPermission();
    if (notificationsEnabled != true) {
      notifyListeners();
      return;
    }
    await NotificationService.instance.scheduleLadder(group!, demo: demo);
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

    // A lock-screen RSVP is the whole point of the buttons -- honour it before routing.
    if (tap.action == 'rsvp_yes' || tap.action == 'rsvp_no') {
      phase = Phase.matched;
      notifyListeners();
      return;
    }

    phase = switch (tap.rung) {
      Rung.reveal || Rung.confirm || Rung.morning || Rung.doorway => Phase.matched,
      Rung.reflect => Phase.after,
    };
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
