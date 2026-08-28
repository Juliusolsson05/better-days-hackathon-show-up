import '../models/models.dart';

/// The seam between the UI and the backend.
///
/// Everything the app needs is behind this interface so the whole flow can be built and
/// demoed against MockRepository while the edge functions and schema are still moving.
/// SupabaseRepository implements the same contract; swapping is one line in main.dart.
abstract class Repository {
  /// Restore an existing session if there is one. The mock treats this as a no-op;
  /// SupabaseRepository lets supabase_flutter rehydrate from disk.
  Future<void> signIn();

  /// True once there is a usable session. Drives whether the app opens on the auth
  /// screen or straight into onboarding.
  Future<bool> isSignedIn();

  /// Email OTP, step one: mail a six-digit code (and create the user if new).
  Future<void> sendEmailOtp(String email);

  /// Email OTP, step two: exchange the code for a session. Throws on a bad code.
  Future<void> verifyEmailOtp(String email, String token);

  Future<Profile> submitProfile({
    required String displayName,
    required String avatar,
    required String passion,
    required List<String> tags,
    required String city,
    required List<String> availability,

    /// Local file path from the image picker. Uploaded to Supabase Storage and sent
    /// to submit-profile as photo_url. Null is allowed; the edge function accepts it.
    String? photoPath,
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

  Future<void> submitReflection(
    String groupId,
    String text, {
    bool wasFallback = false,
  });
  Future<void> submitAttendance(String groupId, Map<String, bool> showedUp);

  /// True once the group has voted and the majority marked you absent. The PRD's flaking
  /// rule: acknowledge it to that person privately, with no penalty and no group effect.
  /// Returns false until enough votes are in to be a "verdict" rather than one opinion.
  Future<bool> wasMarkedNoShow(String groupId);

  /// Selections are one-way and private. Nothing tells anyone they were not selected.
  Future<void> selectContacts(String groupId, Set<String> selectedIds);
  Future<List<MutualContact>> mutualContacts(String groupId);
}
