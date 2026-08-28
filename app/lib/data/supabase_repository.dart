import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
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
    // An empty list is a legitimate, short-lived state because group/chat formation commits
    // independently from external venue retrieval. Do not manufacture a VenueOption sentinel:
    // if the vote-card message arrives before this projection refreshes, a fake option would be
    // rendered as votable and Postgres would correctly reject its made-up id.

    return Group(
      id: groupId,
      eventAt: DateTime.parse(groupRow['event_at'] as String),
      members: members,
      venueOptions: venues,
      activity: groupRow['activity'] as String,
      chosenVenueId: nullableString(groupRow['chosen_venue_id']),
    );
  }

  /// Messages this device has sent but not yet seen echoed back, per group.
  ///
  /// The optimistic bubble lives here rather than in the widget so that it survives the
  /// widget rebuilding, and so the merge with the server list happens in one place.
  final _pending = <String, List<Message>>{};

  /// Lets [sendMessage] re-emit the merged list without owning the stream.
  final _repaint = <String, void Function()>{};

  @override
  Stream<List<Message>> watchMessages(String groupId) {
    // Hand-rolled controller rather than `async*` + `yield*`, because this stream is the
    // merge of two sources: the realtime rows, and the local sends that have not come
    // back yet. A plain yield* can only forward one of them.
    late final StreamController<List<Message>> out;
    StreamSubscription<List<Map<String, dynamic>>>? sub;
    var server = const <Message>[];

    void push() {
      if (out.isClosed) return;
      // A pending message whose row has arrived is now represented twice. The server copy
      // is the real one -- it has the authoritative id and timestamp -- so the local one
      // is dropped. This is the whole reason client_msg_id exists: `id` is a bigserial
      // the client cannot predict, so there is no other way to recognise your own echo.
      final echoed = server
          .map((m) => m.clientMsgId)
          .whereType<String>()
          .toSet();
      _pending[groupId]?.removeWhere((m) => echoed.contains(m.clientMsgId));
      out.add([...server, ...?_pending[groupId]]);
    }

    out = StreamController<List<Message>>(
      // Subscribing in onListen rather than eagerly means the realtime channel is opened
      // when someone actually watches and closed again on cancel -- the chat screen is
      // rebuilt constantly, and an eager subscription would outlive the listener.
      onListen: () {
        try {
          final uid = _userId;
          if (_membersByUserId.isEmpty) {
            // AppState loads currentGroup before constructing the chat. Making that ordering
            // explicit avoids reopening the roster through a second, weaker decoder that would
            // bypass private signed-photo handling and drift from the group screen's identities.
            throw StateError(
              'currentGroup must be loaded before watching messages',
            );
          }
          _repaint[groupId] = push;
          // messages is in the supabase_realtime publication (0001), so this pushes on
          // every insert. RLS 'read group messages' scopes it to the caller's groups, so
          // no filtering beyond the group_id is needed -- or possible to get wrong.
          sub = _client
              .from('messages')
              .stream(primaryKey: ['id'])
              .eq('group_id', groupId)
              .order('id', ascending: true)
              .listen((rows) {
                server = [
                  for (final row in rows)
                    decodeMessageRow(
                      row,
                      currentUserId: uid,
                      membersByUserId: _membersByUserId,
                    ),
                ];
                push();
              }, onError: out.addError);
        } catch (err, st) {
          out.addError(err, st);
        }
      },
      onCancel: () async {
        _repaint.remove(groupId);
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  @override
  Future<void> sendMessage(String groupId, String body) async {
    // Optimistic, because the round trip is visible and the demo runs on venue wifi.
    // Without this the message disappears between tapping send and the echo arriving,
    // which reads as the app having eaten it.
    final clientMsgId = _uuidV4();
    final me = _membersByUserId[_userId];
    final optimistic = Message(
      id: 'pending-$clientMsgId',
      authorId: 'me',
      authorName: me?.displayName ?? 'You',
      avatar: me?.avatar ?? '',
      body: body,
      sentAt: DateTime.now(),
      authorPhotoUrl: me?.photoUrl,
      clientMsgId: clientMsgId,
      status: MessageStatus.sending,
    );

    final queue = _pending.putIfAbsent(groupId, () => <Message>[]);
    queue.add(optimistic);
    _repaint[groupId]?.call();

    void mark(MessageStatus status) {
      final i = queue.indexWhere((m) => m.clientMsgId == clientMsgId);
      if (i >= 0) queue[i] = queue[i].copyWith(status: status);
      _repaint[groupId]?.call();
    }

    try {
      // RLS 'post as self' pins user_id to the caller; passing it explicitly is what the
      // policy checks against rather than something it could be tricked by.
      await _insertUserMessage(groupId, body, clientMsgId);
      // Deliberately NOT removed here. The row is committed, but until the echo arrives
      // this bubble is the only thing on screen representing it -- push() drops it the
      // moment the real row lands. Marking it sent just retires the spinner.
      mark(MessageStatus.sent);
    } catch (_) {
      // Left in the queue on purpose: a failed message the user can see and retry beats
      // one that vanishes. client_msg_id makes the retry safe -- the unique constraint
      // means a send that actually landed cannot be double-posted by trying again.
      mark(MessageStatus.failed);
      rethrow;
    }
  }

  @override
  Future<void> retryMessage(String groupId, Message failed) async {
    final queue = _pending[groupId];
    if (queue == null || failed.clientMsgId == null) return;
    final i = queue.indexWhere((m) => m.clientMsgId == failed.clientMsgId);
    if (i >= 0) queue[i] = queue[i].copyWith(status: MessageStatus.sending);
    _repaint[groupId]?.call();
    try {
      await _insertUserMessage(groupId, failed.body, failed.clientMsgId!);
      if (i >= 0) queue[i] = queue[i].copyWith(status: MessageStatus.sent);
    } catch (_) {
      if (i >= 0) queue[i] = queue[i].copyWith(status: MessageStatus.failed);
    }
    _repaint[groupId]?.call();
  }

  Future<void> _insertUserMessage(
    String groupId,
    String body,
    String clientMsgId,
  ) async {
    // Both the first attempt and every retry use the same conflict-safe write. A transport
    // timeout cannot reveal whether Postgres committed, so a plain INSERT on retry turns the
    // unique key into a user-visible error. DO NOTHING makes the stable client id the protocol:
    // either this call writes the row or an indistinguishable earlier attempt already did.
    await _client
        .from('messages')
        .upsert(
          {
            'group_id': groupId,
            'user_id': _userId,
            'body': body,
            'kind': 'user',
            'client_msg_id': clientMsgId,
          },
          onConflict: 'client_msg_id',
          ignoreDuplicates: true,
        );
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
  Future<void> track(
    String event, {
    String? groupId,
    Map<String, dynamic> props = const {},
  }) async {
    try {
      final response = await _client.functions.invoke(
        'track',
        body: {'name': event, 'group_id': ?groupId, 'props': props},
      );
      // invoke() returns non-2xx responses as data rather than necessarily throwing. If
      // we ignore the status, a rejected event looks identical to a written one in debug
      // and the closing-slide funnel silently stays empty.
      if (response.status < 200 || response.status >= 300) {
        throw Exception(
          'track rejected with ${response.status}: ${response.data}',
        );
      }
    } catch (err) {
      // Swallowed by contract. An analytics write must never be able to fail the user
      // action that triggered it -- a dropped funnel row costs us a number on a slide, a
      // thrown exception costs the user their action.
      //
      // Deliberately not retried or queued: the events table is a funnel, not a ledger,
      // and a queue that survives restarts is more machinery than the question needs.
      if (kDebugMode) debugPrint('track($event) dropped: $err');
    }
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
  Future<bool> wasMarkedNoShow(String groupId) async {
    // attendance_result returns a row per person the group voted on. We look at our own
    // row only, and require at least two votes so a single early opinion does not tell
    // someone they flaked. Absent = fewer than half the voters saw you.
    final rows =
        await _client.rpc('attendance_result', params: {'grp': groupId})
            as List;
    for (final r in rows.cast<Map<String, dynamic>>()) {
      if (r['subject_id'] != _userId) continue;
      final showed = (r['showed_up'] as num).toInt();
      final total = (r['total'] as num).toInt();
      return total >= 2 && showed * 2 < total;
    }
    return false;
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

/// RFC 4122 version 4, from the platform CSPRNG.
///
/// Hand-rolled rather than adding the `uuid` package: this is the only place the app
/// needs one, and Random.secure() is the same entropy source that package would use.
/// Version and variant bits are set explicitly because Postgres validates the shape on
/// the uuid column and a raw 16 random bytes is rejected.
final _rand = Random.secure();

String _uuidV4() {
  final b = List<int>.generate(16, (_) => _rand.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-${h(8)}${h(9)}-'
      '${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}
