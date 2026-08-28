import '../models/models.dart';

/// The seam between the UI and the backend.
///
/// Everything the app needs is behind this interface so the whole flow can be built and
/// demoed against MockRepository while the edge functions and schema are still moving.
/// SupabaseRepository implements the same contract; swapping is one line in main.dart.
abstract class Repository {
  Future<void> signIn();

  Future<Profile> submitProfile({
    required String displayName,
    required String avatar,
    required String passion,
    required List<String> tags,
    required String city,
    required List<String> availability,
  });

  /// Null until the matching sweep has placed you in a group.
  Future<Group?> currentGroup();

  /// The group chat is the product surface, so this is the primary stream.
  Stream<List<Message>> watchMessages(String groupId);
  Future<void> sendMessage(String groupId, String body);

  /// Voting is anonymous: you can read your own ballot and the tally, never who voted.
  Future<void> castVenueVote(String groupId, String optionId);
  Future<String?> myVenueVote(String groupId);
  Future<Map<String, int>> venueTally(String groupId);

  Future<Assignment> assignment(String groupId);

  Future<void> submitReflection(String groupId, String text, {bool wasFallback = false});
  Future<void> submitAttendance(String groupId, Map<String, bool> showedUp);

  /// Selections are one-way and private. Nothing tells anyone they were not selected.
  Future<void> selectContacts(String groupId, Set<String> selectedIds);
  Future<List<MutualContact>> mutualContacts(String groupId);
}
