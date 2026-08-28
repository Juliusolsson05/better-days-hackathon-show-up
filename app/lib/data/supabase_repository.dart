import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'repository.dart';

/// Real backend. Implements the same [Repository] contract as MockRepository.
///
/// Only the signup path is wired today: email OTP, the photo upload, and the
/// `submit-profile` edge function. The group / chat / vote / after-meetup methods
/// throw [UnimplementedError] on purpose -- they depend on the 0002 schema, which is
/// still a draft (`supabase/drafts/0002_product_model.sql.draft`). Wire them here as
/// each one lands; nothing else in the app has to change.
class SupabaseRepository implements Repository {
  SupabaseRepository(this._client);

  final SupabaseClient _client;

  /// Bucket for signup photos. Must exist before signup works -- see the PR notes for
  /// the one `create bucket` statement.
  static const _photoBucket = 'photos';

  GoTrueClient get _auth => _client.auth;

  @override
  Future<void> signIn() async {
    // supabase_flutter rehydrates the session from disk during Supabase.initialize,
    // so there is nothing to do here beyond letting that have happened.
  }

  @override
  Future<bool> isSignedIn() async => _auth.currentSession != null;

  @override
  Future<void> sendEmailOtp(String email) {
    // shouldCreateUser: the PRD has no separate "register" step -- first sight of an
    // address is a signup. emailRedirectTo is null because we verify the code in-app
    // rather than following a magic link.
    return _auth.signInWithOtp(email: email, shouldCreateUser: true);
  }

  @override
  Future<void> verifyEmailOtp(String email, String token) async {
    await _auth.verifyOTP(type: OtpType.email, email: email, token: token.trim());
  }

  @override
  Future<Profile> submitProfile({
    required String displayName,
    required String avatar,
    required String passion,
    required List<String> tags,
    required String city,
    required List<String> availability,
    String? photoPath,
  }) async {
    final uid = _auth.currentUser?.id;
    if (uid == null) {
      throw StateError('submitProfile called without a session');
    }

    final photoUrl = photoPath == null ? null : await _uploadPhoto(uid, photoPath);

    // The function holds the ClickHouse and LLM secrets and does the embed + tag
    // extraction; it also upserts the profiles row, so the client never writes it
    // directly. supabase_flutter attaches the session JWT automatically.
    final res = await _client.functions.invoke('submit-profile', body: {
      'display_name': displayName,
      'passion': passion,
      'tags': tags,
      'city': city,
      'availability': availability,
      if (photoUrl != null) 'photo_url': photoUrl,
    });

    if (res.status != 200) {
      final detail = res.data is Map ? res.data['error'] : res.data;
      throw Exception('submit-profile failed (${res.status}): $detail');
    }

    return Profile(
      id: uid,
      displayName: displayName,
      avatar: avatar,
      passion: passion,
      tags: tags,
      city: city,
      availability: availability,
    );
  }

  /// Uploads to `photos/<uid>/profile.jpg` and returns the public URL. One photo per
  /// user, overwritten on re-submit (upsert), so editing a profile does not pile up
  /// orphaned objects.
  Future<String> _uploadPhoto(String uid, String path) async {
    final bytes = await File(path).readAsBytes();
    final objectPath = '$uid/profile.jpg';
    await _client.storage.from(_photoBucket).uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
        );
    return _client.storage.from(_photoBucket).getPublicUrl(objectPath);
  }

  Never _notWired(String method) => throw UnimplementedError(
        'SupabaseRepository.$method is not wired yet -- it needs the 0002 schema, which '
        'is still a draft. Run against MockRepository for the post-signup flow.',
      );

  @override
  Future<Group?> currentGroup() async => _notWired('currentGroup');

  @override
  Stream<List<Message>> watchMessages(String groupId) => _notWired('watchMessages');

  @override
  Future<void> sendMessage(String groupId, String body) async => _notWired('sendMessage');

  @override
  Future<void> castVenueVote(String groupId, String optionId) async =>
      _notWired('castVenueVote');

  @override
  Future<String?> myVenueVote(String groupId) async => _notWired('myVenueVote');

  @override
  Future<Map<String, int>> venueTally(String groupId) async => _notWired('venueTally');

  @override
  Future<Assignment> assignment(String groupId) async => _notWired('assignment');

  @override
  Future<void> submitReflection(String groupId, String text, {bool wasFallback = false}) async =>
      _notWired('submitReflection');

  @override
  Future<void> submitAttendance(String groupId, Map<String, bool> showedUp) async =>
      _notWired('submitAttendance');

  @override
  Future<void> selectContacts(String groupId, Set<String> selectedIds) async =>
      _notWired('selectContacts');

  @override
  Future<List<MutualContact>> mutualContacts(String groupId) async =>
      _notWired('mutualContacts');
}
