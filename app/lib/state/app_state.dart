import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../models/models.dart';

/// ChangeNotifier rather than a state-management package: one less dependency, and the
/// app has exactly one piece of global state -- where you are in the flow.
class AppState extends ChangeNotifier {
  AppState(this.repo, {Phase initialPhase = Phase.onboarding})
    : phase = initialPhase;
  final Repository repo;

  Phase phase;
  Profile? me;
  Group? group;
  Assignment? assignment;
  List<MutualContact> contacts = const [];

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
  }

  /// Refreshes server-owned group state without replaying the navigation transition.
  ///
  /// Venue selection is completed by the database when the final ballot lands. Keeping a
  /// stale Group object after voting would make the tally correct while group info still says
  /// "voting open" until the app restarts. This narrow refresh lets the vote card pick up the
  /// winner without reloading the private assignment or changing phases.
  Future<void> refreshGroup() async {
    final refreshed = await repo.currentGroup();
    if (refreshed == null) return;
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
