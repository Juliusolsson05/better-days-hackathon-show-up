import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'repository.dart';
import 'supabase_row_decoders.dart';

/// The real implementation of the same protocol used by [MockRepository].
///
/// Database JSON is deliberately decoded here, rather than in widgets or AppState. PostgREST,
/// RLS, and storage URLs are replaceable infrastructure details; letting their row shapes leak
/// upward would turn every schema migration into a UI migration too.
class SupabaseRepository implements Repository {
  SupabaseRepository(this._client);

  final SupabaseClient _client;
  static const _photoBucket = 'photos';

  // Message rows carry only an author UUID. The group fetch is the source of truth for the
  // human-facing name/photo, and this cache avoids joining profiles into a realtime stream (the
  // stream API intentionally returns table rows, not embedded PostgREST relations).
  Map<String, Member> _membersByUserId = const {};

  GoTrueClient get _auth => _client.auth;

  String get _userId {
    final id = _auth.currentUser?.id;
    if (id == null) {
      throw StateError('A signed-in user is required for this operation');
    }
    return id;
  }

  @override
  Future<void> signIn() async {
    // Supabase.initialize rehydrates the persisted session before constructing this repository.
  }

  @override
  Future<bool> isSignedIn() async => _auth.currentSession != null;

  @override
  Future<bool> hasProfile() async {
    if (_auth.currentUser == null) return false;
    final row = await _client
        .from('profiles')
        .select('id')
        .eq('id', _userId)
        .maybeSingle();
    return row != null;
  }

  @override
  Future<void> sendEmailOtp(String email) =>
      _auth.signInWithOtp(email: email, shouldCreateUser: true);

  @override
  Future<void> verifyEmailOtp(String email, String token) async {
    await _auth.verifyOTP(
      type: OtpType.email,
      email: email,
      token: token.trim(),
    );
  }

  @override
  Future<Profile> submitProfile({
    required String displayName,
    required String avatar,
    required String passion,
    required List<String> tags,
    required String city,
    required List<String> availability,
    required String phone,
    String? photoPath,
  }) async {
    final uid = _userId;
    if (photoPath == null) {
      // The database also enforces this. Failing before the LLM/embedding call makes a picker
      // race cheap and understandable instead of returning a late Postgres constraint error.
      throw ArgumentError('A profile photo is required');
    }

    final storedPhotoPath = await _uploadPhoto(uid, photoPath);

    final res = await _client.functions.invoke(
      'submit-profile',
      body: {
        'display_name': displayName,
        'avatar': avatar,
        'passion': passion,
        'tags': tags,
        'city': city,
        'availability': availability,
        'phone': phone,
        // The legacy column is named photo_url, but private buckets have no durable public URL.
        // Persist the object path and mint a short-lived signed URL only when a group reads it.
        'photo_url': storedPhotoPath,
      },
    );

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
      phone: phone,
    );
  }

  Future<String> _uploadPhoto(String uid, String path) async {
    final bytes = await File(path).readAsBytes();
    final objectPath = '$uid/profile.jpg';
    await _client.storage
        .from(_photoBucket)
        .uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    return objectPath;
  }

  @override
  Future<Group?> currentGroup() async {
    final uid = _userId;
    final membership = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', uid)
        .order('joined_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (membership == null) return null;

    final groupId = membership['group_id'] as String;

    // Start the three independent reads together. `Future`s are eager in Dart, so awaiting them
    // below does not serialize the network round trips.
    final groupFuture = _client
        .from('groups')
        .select('id,event_at,venue,activity,chosen_venue_id')
        .eq('id', groupId)
        .single();
    final memberRowsFuture = _client
        .from('group_members')
        .select(
          'user_id,profiles!group_members_user_id_fkey(display_name,avatar,tags,photo_url)',
        )
        .eq('group_id', groupId)
        .order('joined_at');
    final venueRowsFuture = _client
        .from('venue_options')
        .select('id,position,name,kind,address,lat,lng,pitch')
        .eq('group_id', groupId)
        .order('position');

    final groupRow = await groupFuture;
    final memberRows = await memberRowsFuture;
    final venueRows = await venueRowsFuture;

    final members = await Future.wait(
      memberRows.map((row) async {
        final profile = nestedMap(row, 'profiles');
        final signedPhoto = await _signedPhotoUrl(
          nullableString(profile['photo_url']),
        );
        return decodeMemberRow(
          row,
          currentUserId: uid,
          signedPhotoUrl: signedPhoto,
        );
      }),
    );
    _membersByUserId = {
      for (var i = 0; i < memberRows.length; i++)
        memberRows[i]['user_id'] as String: members[i],
    };

    final venues = venueRows.map(decodeVenueOptionRow).toList(growable: true);
    if (venues.isEmpty) {
      final legacy = decodeLegacyVenue(groupRow['venue'], groupId);
      if (legacy != null) venues.add(legacy);
    }
    if (venues.isEmpty) {
      // Group formation and venue retrieval are intentionally separate jobs. The group screen
      // must remain navigable in the gap instead of crashing on `venueOptions.first`.
      venues.add(
        const VenueOption(
          id: 'pending',
          name: 'Venue coming soon',
          address: 'The group will vote here when options are ready.',
          pitch: '',
          categories: [],
        ),
      );
    }

    return Group(
      id: groupId,
      eventAt: DateTime.parse(groupRow['event_at'] as String),
      members: members,
      venueOptions: venues,
      activity: groupRow['activity'] as String,
      chosenVenueId: nullableString(groupRow['chosen_venue_id']),
    );
  }

  @override
  Stream<List<Message>> watchMessages(String groupId) {
    final uid = _userId;
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        .order('created_at', ascending: true)
        .map(
          (rows) => rows
              .map(
                (row) => decodeMessageRow(
                  row,
                  currentUserId: uid,
                  membersByUserId: _membersByUserId,
                ),
              )
              .toList(growable: false),
        );
  }

  @override
  Future<void> sendMessage(String groupId, String body) async {
    await _client.from('messages').insert({
      'group_id': groupId,
      'user_id': _userId,
      'body': body,
      'kind': 'user',
    });
  }

  @override
  Future<void> castVenueVote(String groupId, String optionId) async {
    await _client.from('venue_votes').upsert({
      'group_id': groupId,
      'user_id': _userId,
      'option_id': optionId,
    }, onConflict: 'group_id,user_id');
  }

  @override
  Future<String?> myVenueVote(String groupId) async {
    final row = await _client
        .from('venue_votes')
        .select('option_id')
        .eq('group_id', groupId)
        .eq('user_id', _userId)
        .maybeSingle();
    return row?['option_id'] as String?;
  }

  @override
  Future<Map<String, int>> venueTally(String groupId) async {
    final rows = await _client.rpc<List<dynamic>>(
      'venue_tally',
      params: {'grp': groupId},
    );
    return {
      for (final raw in rows)
        (raw as Map<String, dynamic>)['option_id'] as String:
            ((raw['votes'] as num?) ?? 0).toInt(),
    };
  }

  @override
  Future<Assignment> assignment(String groupId) async {
    final row = await _client
        .from('member_assignments')
        .select('target_id,question')
        .eq('group_id', groupId)
        .eq('user_id', _userId)
        .single();
    final targetId = row['target_id'] as String;
    final cachedTarget = _membersByUserId[targetId];
    final targetName =
        cachedTarget?.displayName ??
        (await _client
                .from('profiles')
                .select('display_name')
                .eq('id', targetId)
                .single())['display_name']
            as String;
    return Assignment(
      targetId: targetId,
      targetName: targetName,
      question: row['question'] as String,
    );
  }

  @override
  Future<void> submitReflection(
    String groupId,
    String text, {
    bool wasFallback = false,
  }) async {
    final target = wasFallback ? null : (await assignment(groupId)).targetId;
    await _client.from('reflections').upsert({
      'group_id': groupId,
      'user_id': _userId,
      'about_user': target,
      'what_stuck': text,
      'was_fallback': wasFallback,
    }, onConflict: 'group_id,user_id');
  }

  @override
  Future<void> submitAttendance(
    String groupId,
    Map<String, bool> showedUp,
  ) async {
    final uid = _userId;
    if (_membersByUserId.isEmpty) {
      throw StateError(
        'currentGroup must be loaded before submitting attendance',
      );
    }
    final rows = _membersByUserId.entries
        .where((entry) => entry.key != uid)
        .map(
          (entry) => {
            'group_id': groupId,
            'voter_id': uid,
            'subject_id': entry.key,
            // Untouched switches visually default to true. Applying the same default here
            // prevents an empty map from meaning “nobody was evaluated”.
            'showed_up': showedUp[entry.value.id] ?? true,
          },
        )
        .toList(growable: false);
    await _client
        .from('attendance_votes')
        .upsert(rows, onConflict: 'group_id,voter_id,subject_id');
  }

  @override
  Future<void> selectContacts(String groupId, Set<String> selectedIds) async {
    await _client.rpc<void>(
      'set_contact_selections',
      params: {'grp': groupId, 'selected': selectedIds.toList(growable: false)},
    );
  }

  @override
  Future<List<MutualContact>> mutualContacts(String groupId) async {
    final rows = await _client.rpc<List<dynamic>>(
      'mutual_contacts',
      params: {'grp': groupId},
    );
    return Future.wait(
      rows.map((raw) async {
        final row = Map<String, dynamic>.from(raw as Map);
        final signedPhoto = await _signedPhotoUrl(
          nullableString(row['photo_url']),
        );
        return decodeMutualContactRow(row, signedPhotoUrl: signedPhoto);
      }),
    );
  }

  Future<String?> _signedPhotoUrl(String? objectPath) async {
    if (objectPath == null || objectPath.isEmpty) return null;
    // Preserve profiles created before the bucket became private; their stored value is already
    // a URL and asking Storage to sign it as an object path would guarantee a 404.
    if (objectPath.startsWith('http://') || objectPath.startsWith('https://')) {
      return objectPath;
    }
    try {
      return await _client.storage
          .from(_photoBucket)
          .createSignedUrl(objectPath, 3600);
    } on StorageException {
      // A missing photo must not make the entire group disappear. Avatar's emoji fallback keeps
      // the person identifiable while a later refresh can recover the storage URL.
      return null;
    }
  }
}
