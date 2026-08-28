import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../models/models.dart';

/// ChangeNotifier rather than a state-management package: one less dependency, and the
/// app has exactly one piece of global state -- where you are in the flow.
class AppState extends ChangeNotifier {
  AppState(this.repo);
  final Repository repo;

  Phase phase = Phase.onboarding;
  Profile? me;
  Group? group;
  Assignment? assignment;
  List<MutualContact> contacts = const [];

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
