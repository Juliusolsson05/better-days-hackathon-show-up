import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'repository.dart';

/// Real backend. Implements the same [Repository] contract as MockRepository.
///
/// Wired against the 0001 schema: signup (email OTP + photo + `submit-profile`), the
/// live group chat, and the private question. Venue voting, attendance, and contact
/// exchange still throw [_notWired] -- their tables live in the 0002 draft
/// (`supabase/drafts/0002_product_model.sql.draft`) and, for venue, in Julius's
/// `feat/venue-pipeline`. Wire them here as each lands; nothing else in the app changes.
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
      'photo_url': ?photoUrl,
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
        'SupabaseRepository.$method is not wired yet -- its tables are in the 0002 draft '
        '(and, for venue, in feat/venue-pipeline). Run the after-meetup flow against '
        'MockRepository until then.',
      );

  String get _uid {
    final id = _auth.currentUser?.id;
    if (id == null) throw StateError('called without a session');
    return id;
  }

  // Group membership is fixed for the life of a group, so the member list is resolved
  // once and reused -- currentGroup() to build the roster, watchMessages() to put a name
  // and photo on each incoming row without a join per message.
  final _memberCache = <String, Map<String, Member>>{};

  Future<Map<String, Member>> _members(String groupId) async {
    final cached = _memberCache[groupId];
    if (cached != null) return cached;
    final rows = await _client
        .from('group_members')
        .select('user_id, profiles(display_name, photo_url, tags)')
        .eq('group_id', groupId);
    final map = {
      for (final r in rows) r['user_id'] as String: _memberFrom(r),
    };
    _memberCache[groupId] = map;
    return map;
  }

  Member _memberFrom(Map<String, dynamic> row) {
    final p = (row['profiles'] as Map<String, dynamic>?) ?? const {};
    return Member(
      id: row['user_id'] as String,
      displayName: (p['display_name'] as String?) ?? 'Someone',
      avatar: (p['photo_url'] as String?) ?? '',
      tags: ((p['tags'] as List?) ?? const []).cast<String>(),
    );
  }

  Message _messageFrom(Map<String, dynamic> row, Map<String, Member> members, String uid) {
    final authorId = row['user_id'] as String;
    final mine = authorId == uid;
    final m = members[authorId];
    return Message(
      id: '${row['id']}',
      // 'me' is the sentinel Message.isMine checks; keeping the mock's convention means
      // group_chat_screen.dart needs no change to tell my bubbles from everyone else's.
      authorId: mine ? 'me' : authorId,
      authorName: m?.displayName ?? 'Someone',
      avatar: m?.avatar ?? '',
      body: (row['body'] as String?) ?? '',
      sentAt: DateTime.parse(row['created_at'] as String).toLocal(),
    );
  }

  @override
  Future<Group?> currentGroup() async {
    final mine = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', _uid)
        .limit(1);
    if (mine.isEmpty) return null;
    final groupId = mine.first['group_id'] as String;

    final g = await _client
        .from('groups')
        .select('id, event_at, venue, activity')
        .eq('id', groupId)
        .single();

    final members = (await _members(groupId)).values.toList();

    // 0001 stores the single venue Claude already picked -- there is no ballot yet, so it
    // is the chosen one. Venue voting (0002 / feat/venue-pipeline) will replace this with
    // a real venue_options row set.
    final venue = (g['venue'] as Map<String, dynamic>?) ?? const {};
    final option = VenueOption(
      id: 'venue-$groupId',
      name: (venue['name'] as String?) ?? 'Venue to be confirmed',
      address: (venue['address'] as String?) ?? '',
      pitch: '',
      categories: const [],
    );

    return Group(
      id: g['id'] as String,
      eventAt: DateTime.parse(g['event_at'] as String).toLocal(),
      members: members,
      venueOptions: [option],
      activity: (g['activity'] as String?) ?? '',
      chosenVenueId: option.id,
    );
  }

  @override
  Stream<List<Message>> watchMessages(String groupId) async* {
    final uid = _uid;
    final members = await _members(groupId);
    // The messages table is in the supabase_realtime publication (0001), so this pushes
    // on every insert. RLS 'read group messages' scopes it to groups the caller is in.
    yield* _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        .order('id', ascending: true)
        .map((rows) => [for (final r in rows) _messageFrom(r, members, uid)]);
  }

  @override
  Future<void> sendMessage(String groupId, String body) async {
    // No optimistic insert: the realtime stream echoes the row back in a beat, and RLS
    // 'post as self' already forces user_id to the caller.
    await _client.from('messages').insert({
      'group_id': groupId,
      'user_id': _uid,
      'body': body,
    });
  }

  @override
  Future<void> castVenueVote(String groupId, String optionId) async =>
      _notWired('castVenueVote');

  @override
  Future<String?> myVenueVote(String groupId) async => _notWired('myVenueVote');

  @override
  Future<Map<String, int>> venueTally(String groupId) async => _notWired('venueTally');

  @override
  Future<Assignment> assignment(String groupId) async {
    final row = await _client
        .from('group_members')
        .select('pair_with, question')
        .eq('group_id', groupId)
        .eq('user_id', _uid)
        .single();

    final pairWith = row['pair_with'] as String?;
    var name = 'your pair';
    if (pairWith != null) {
      final p = await _client
          .from('profiles')
          .select('display_name')
          .eq('id', pairWith)
          .maybeSingle();
      name = (p?['display_name'] as String?) ?? name;
    }
    return Assignment(
      targetId: pairWith ?? '',
      targetName: name,
      question: (row['question'] as String?) ?? '',
    );
  }

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
