import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../models/models.dart';

/// ChangeNotifier rather than a state-management package: one less dependency, and the
/// app has exactly one piece of global state -- where you are in the flow.
class AppState extends ChangeNotifier {
  AppState(
    this.repo, {
    Phase initialPhase = Phase.onboarding,
    this.referenceUiPreview = false,
  }) : phase = initialPhase;
  final Repository repo;

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
    if (!await repo.hasProfile()) {
      phase = Phase.onboarding;
      notifyListeners();
      return;
    }

    await _loadProductPhase();
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
    phase = Phase.matched;
  }

  /// Group formation and the chat opening are the same event -- there is no lobby.
  Future<void> enterGroup() async {
    group = await repo.currentGroup();
    if (group == null) return;
    assignment = await repo.assignment(group!.id);
    phase = Phase.matched;
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
