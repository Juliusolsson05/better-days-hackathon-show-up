import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'repository.dart';

/// Real backend. Implements the same [Repository] contract as MockRepository.
///
/// Wired: signup (email OTP + photo + `submit-profile`), the live group chat, the
/// private question (all on 0001), and the whole after-meetup flow -- reflection,
/// attendance, contact exchange (on 0002_after_meetup). The only methods still throwing
/// [_notWired] are venue voting; its tables are in the draft and its retrieval pipeline
/// is Julius's `feat/venue-pipeline`.
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
    String? photoPath,
  }) async {
    final uid = _auth.currentUser?.id;
    if (uid == null) {
      throw StateError('submitProfile called without a session');
    }

    final photoUrl = photoPath == null
        ? null
        : await _uploadPhoto(uid, photoPath);

    // The function holds the ClickHouse and LLM secrets and does the embed + tag
    // extraction; it also upserts the profiles row, so the client never writes it
    // directly. supabase_flutter attaches the session JWT automatically.
    final res = await _client.functions.invoke(
      'submit-profile',
      body: {
        'display_name': displayName,
        'passion': passion,
        'tags': tags,
        'city': city,
        'availability': availability,
        'photo_url': ?photoUrl,
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
    );
  }

  /// Uploads to `photos/<uid>/profile.jpg` and returns the public URL. One photo per
  /// user, overwritten on re-submit (upsert), so editing a profile does not pile up
  /// orphaned objects.
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
    return _client.storage.from(_photoBucket).getPublicUrl(objectPath);
  }

  Never _notWired(String method) => throw UnimplementedError(
    'SupabaseRepository.$method is not wired yet -- venue voting needs the venue '
    'tables (still in the draft) and the retrieval pipeline on feat/venue-pipeline. '
    'Run the venue vote against MockRepository until then.',
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
    final uid = _uid;
    final rows = await _client
        .from('group_members')
        .select('user_id, profiles(display_name, photo_url, tags)')
        .eq('group_id', groupId);
    // Keyed by the real user_id so _messageFrom can always resolve an author. The Member
    // objects, though, carry id 'me' for the current user -- the mock uses that sentinel
    // (MockRepository.formGroup) and so do the screens: after_flow and group_info both do
    // `where((m) => m.id != 'me')` to list "everyone else". Without this the current user
    // shows up in their own attendance and contact lists.
    final map = {
      for (final r in rows)
        r['user_id'] as String: _memberFrom(r, isMe: r['user_id'] == uid),
    };
    _memberCache[groupId] = map;
    return map;
  }

  Member _memberFrom(Map<String, dynamic> row, {required bool isMe}) {
    final p = (row['profiles'] as Map<String, dynamic>?) ?? const {};
    return Member(
      id: isMe ? 'me' : row['user_id'] as String,
      displayName: (p['display_name'] as String?) ?? 'Someone',
      avatar: (p['photo_url'] as String?) ?? '',
      tags: ((p['tags'] as List?) ?? const []).cast<String>(),
    );
  }

  Message _messageFrom(
    Map<String, dynamic> row,
    Map<String, Member> members,
    String uid,
  ) {
    // Nullable since 0003_chat: system and venue_vote rows are written by the server and
    // have no author. Only 'user' rows are guaranteed one, and the database enforces it.
    final authorId = row['user_id'] as String?;
    final mine = authorId != null && authorId == uid;
    final m = authorId == null ? null : members[authorId];
    return Message(
      id: '${row['id']}',
      // 'me' is the sentinel Message.isMine checks; keeping the mock's convention means
      // group_chat_screen.dart needs no change to tell my bubbles from everyone else's.
      authorId: mine ? 'me' : (authorId ?? 'system'),
      authorName: m?.displayName ?? 'Someone',
      avatar: m?.avatar ?? '',
      body: (row['body'] as String?) ?? '',
      sentAt: DateTime.parse(row['created_at'] as String).toLocal(),
      kind: _kindFrom(row['kind'] as String?),
      clientMsgId: row['client_msg_id'] as String?,
    );
  }

  /// Unknown kinds degrade to [MessageKind.user] rather than throwing.
  ///
  /// The server can start writing a kind this build has never heard of -- a deployed
  /// phone is not upgraded in step with an edge function. Rendering it as an ordinary
  /// message is wrong but harmless; throwing takes down the whole chat stream.
  MessageKind _kindFrom(String? raw) => switch (raw) {
    'system' => MessageKind.system,
    'venue_vote' => MessageKind.venueVote,
    _ => MessageKind.user,
  };

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
      // planGroup's venue object is {name, address, why} -- `why` is a line written for
      // this specific group and is exactly what `pitch` renders. It was being dropped.
      //
      // Note what is NOT here: lat/lng. The 0001 comment on groups.venue claims
      // {name, address, lat, lng}, but GroupPlan never asked Claude for coordinates and
      // it must not -- a hallucinated pair of floats renders as a confident pin on a map
      // pointing at nothing. Real coordinates arrive with the Overture corpus in
      // feat/venue-pipeline, which is why VenueMap degrades to the address until then.
      pitch: (venue['why'] as String?) ?? '',
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
    var cancelled = false;

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
      onListen: () async {
        try {
          final uid = _uid;
          final members = await _members(groupId);
          // The screen can disappear while the roster fetch is in flight. In that order,
          // onCancel runs before `sub` exists; without this guard the await resumes and
          // opens a Realtime channel with nobody left to cancel it.
          if (cancelled || out.isClosed) return;
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
                server = [for (final r in rows) _messageFrom(r, members, uid)];
                push();
              }, onError: out.addError);
        } catch (err, st) {
          out.addError(err, st);
        }
      },
      onCancel: () async {
        cancelled = true;
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
    final me = (await _members(groupId))[_uid];
    final optimistic = Message(
      id: 'pending-$clientMsgId',
      authorId: 'me',
      authorName: me?.displayName ?? 'You',
      avatar: me?.avatar ?? '',
      body: body,
      sentAt: DateTime.now(),
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
      await _client.from('messages').insert({
        'group_id': groupId,
        'user_id': _uid,
        'body': body,
        'client_msg_id': clientMsgId,
      });
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
      await _client
          .from('messages')
          .upsert(
            {
              'group_id': groupId,
              'user_id': _uid,
              'body': failed.body,
              'client_msg_id': failed.clientMsgId,
            },
            onConflict: 'client_msg_id',
            ignoreDuplicates: true,
          );
      if (i >= 0) queue[i] = queue[i].copyWith(status: MessageStatus.sent);
    } catch (_) {
      if (i >= 0) queue[i] = queue[i].copyWith(status: MessageStatus.failed);
    }
    _repaint[groupId]?.call();
  }

  @override
  Future<void> castVenueVote(String groupId, String optionId) async =>
      _notWired('castVenueVote');

  @override
  Future<String?> myVenueVote(String groupId) async => _notWired('myVenueVote');

  @override
  Future<Map<String, int>> venueTally(String groupId) async =>
      _notWired('venueTally');

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
    // reflections.about_user is NOT NULL. Normally it is your assigned pair. In the
    // fallback case the UI never asks *who* you learned about instead, so we still store
    // the assigned pair and let was_fallback record that the content is really about the
    // group. Giving the fallback a real subject would need a UI change.
    final me = await _client
        .from('group_members')
        .select('pair_with')
        .eq('group_id', groupId)
        .eq('user_id', _uid)
        .single();
    final aboutUser = (me['pair_with'] as String?) ?? _uid;

    // Upsert on the (group_id, user_id) primary key: running the flow twice edits your
    // reflection rather than failing.
    await _client.from('reflections').upsert({
      'group_id': groupId,
      'user_id': _uid,
      'about_user': aboutUser,
      'what_stuck': text,
      'was_fallback': wasFallback,
    }, onConflict: 'group_id,user_id');
  }

  @override
  Future<void> submitAttendance(
    String groupId,
    Map<String, bool> showedUp,
  ) async {
    if (showedUp.isEmpty) return;
    // One row per (me, subject). CHECK (voter_id <> subject_id) holds because the UI
    // builds this map from "everyone else" -- and _members() gives the current user id
    // 'me', so they are excluded even against the real backend.
    final rows = [
      for (final e in showedUp.entries)
        {
          'group_id': groupId,
          'voter_id': _uid,
          'subject_id': e.key,
          'showed_up': e.value,
        },
    ];
    await _client
        .from('attendance_votes')
        .upsert(rows, onConflict: 'group_id,voter_id,subject_id');
  }

  @override
  Future<void> selectContacts(String groupId, Set<String> selectedIds) async {
    // Replace rather than accrete: wipe my picks for this group, then insert the current
    // set. The UI has no un-pick-and-resubmit path, but the demo re-runs the flow, and
    // "your latest choice wins" is the least surprising behaviour. contact_selections is
    // insert/select only for the caller (RLS), so a delete of one's own rows is allowed.
    await _client
        .from('contact_selections')
        .delete()
        .eq('group_id', groupId)
        .eq('selector_id', _uid);
    if (selectedIds.isEmpty) return;
    await _client.from('contact_selections').insert([
      for (final id in selectedIds)
        {'group_id': groupId, 'selector_id': _uid, 'selected_id': id},
    ]);
  }

  @override
  Future<List<MutualContact>> mutualContacts(String groupId) async {
    // The reciprocity + invisibility rules live entirely in this function (see
    // 0002_after_meetup.sql): it returns a row only for a pick that went both ways, and
    // nothing here separates "did not pick me" from "was not in the group".
    final rows =
        await _client.rpc('mutual_contacts', params: {'grp': groupId}) as List;
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        MutualContact(
          id: r['user_id'] as String,
          displayName: (r['display_name'] as String?) ?? 'Someone',
          avatar: (r['photo_url'] as String?) ?? '',
          phone: (r['phone'] as String?) ?? '',
        ),
    ];
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
