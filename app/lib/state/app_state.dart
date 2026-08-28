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

  /// Reconstruct the durable phase after a process restart. Auth restoration alone is not enough:
  /// a verified user may still need onboarding, while an onboarded user may be waiting or already
  /// matched. Keeping this decision here stops the app shell from duplicating repository reads.
  Future<void> restore() async {
    if (!await repo.isSignedIn()) {
      phase = Phase.auth;
      notifyListeners();
      return;
    }
    if (!await repo.hasProfile()) {
      phase = Phase.onboarding;
      notifyListeners();
      return;
    }

    group = await repo.currentGroup();
    if (group == null) {
      phase = Phase.waiting;
    } else {
      assignment = await repo.assignment(group!.id);
      phase = Phase.matched;
    }
    notifyListeners();
  }

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
