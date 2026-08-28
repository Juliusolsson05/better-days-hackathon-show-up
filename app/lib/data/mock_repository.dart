import 'dart:async';

import '../models/models.dart';
import 'repository.dart';

/// In-memory implementation of the whole flow.
///
/// Two things here are deliberate rather than lazy. Latency is simulated so the UI is
/// built against a backend that is not instant -- loading states get written once, now,
/// rather than retrofitted. And the other members reply on a timer, because a chat that
/// never moves reads as broken in a demo and hides every scroll and ordering bug.
class MockRepository implements Repository {
  static const _lag = Duration(milliseconds: 350);

  final _members = const [
    Member(id: 'u1', displayName: 'Maya',  avatar: '🧗', tags: ['climbing', 'outdoors']),
    Member(id: 'u2', displayName: 'Tom',   avatar: '🎧', tags: ['music', 'records']),
    Member(id: 'u3', displayName: 'Priya', avatar: '📷', tags: ['photography', 'analog']),
    Member(id: 'u4', displayName: 'Sam',   avatar: '🍞', tags: ['baking', 'food']),
    Member(id: 'u5', displayName: 'Alex',  avatar: '♟️', tags: ['chess', 'strategy']),
  ];

  final _venues = const [
    VenueOption(
      id: 'v1', name: 'Kinship', address: '2801 Mission St',
      lat: 37.7522, lng: -122.4185,
      pitch: 'Small plates, no TVs, a back room quiet enough to actually hear each other.',
      categories: ['cocktail bars', 'tapas'],
    ),
    VenueOption(
      id: 'v2', name: 'Dogpatch Boulders', address: '2573 3rd St',
      lat: 37.7562, lng: -122.3885,
      pitch: 'Intro session at 7. Nobody has to make conversation while holding a rope.',
      categories: ['climbing', 'active'],
    ),
    VenueOption(
      id: 'v3', name: 'Four Star Cafe', address: '2200 Mission St',
      lat: 37.7620, lng: -122.4193,
      pitch: 'Coffee and a long table. The low-key option if a bar feels like a lot.',
      categories: ['cafes'],
    ),
  ];

  Profile? _me;
  Group? _group;
  String? _myVote;
  final _tally = <String, int>{'v1': 2, 'v2': 1, 'v3': 0};
  final _messages = <Message>[];
  final _controller = StreamController<List<Message>>.broadcast();
  Timer? _chatter;

  @override
  Future<void> signIn() => Future.delayed(_lag);

  @override
  Future<bool> isSignedIn() async => true;

  @override
  Future<void> sendEmailOtp(String email) => Future.delayed(_lag);

  @override
  Future<void> verifyEmailOtp(String email, String token) => Future.delayed(_lag);

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
    await Future.delayed(_lag);
    return _me = Profile(
      id: 'me', displayName: displayName, avatar: avatar, passion: passion,
      tags: tags, city: city, availability: availability,
    );
  }

  /// Called by the dev menu to stand in for the matching sweep having run.
  void formGroup() {
    _group = Group(
      id: 'g1',
      eventAt: DateTime.now().add(const Duration(days: 3, hours: 4)),
      members: [
        Member(id: 'me', displayName: _me?.displayName ?? 'You', avatar: _me?.avatar ?? '🙂'),
        ..._members,
      ],
      venueOptions: _venues,
      activity: 'Drinks and small plates',
    );
    _messages
      ..clear()
      ..addAll([
        Message(
          id: 'm0', authorId: 'system', authorName: '', avatar: '',
          body: 'Six of you matched on climbing, music and making things. '
              'Pick a spot below. Votes are anonymous.',
          sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
          kind: MessageKind.system,
        ),
        Message(
          id: 'm1', authorId: 'vote', authorName: '', avatar: '',
          body: '', sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
          kind: MessageKind.venueVote,
        ),
        Message(
          id: 'm2', authorId: 'u1', authorName: 'Maya', avatar: '🧗',
          body: 'oh the boulders one is very tempting', 
          sentAt: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      ]);
    _emit();
    _startChatter();
  }

  @override
  Future<Group?> currentGroup() async {
    await Future.delayed(_lag);
    return _group;
  }

  @override
  Stream<List<Message>> watchMessages(String groupId) {
    scheduleMicrotask(_emit);
    return _controller.stream;
  }

  @override
  Future<void> sendMessage(String groupId, String body) async {
    _messages.add(Message(
      id: 'm${_messages.length}', authorId: 'me',
      authorName: _me?.displayName ?? 'You', avatar: _me?.avatar ?? '🙂',
      body: body, sentAt: DateTime.now(),
    ));
    _emit();
  }

  void _emit() => _controller.add(List.unmodifiable(_messages));

  /// Someone replies a few seconds after the group opens, so the chat is visibly live.
  void _startChatter() {
    _chatter?.cancel();
    const lines = [
      ('u2', 'Tom', '🎧', 'im in for whatever, first time doing one of these'),
      ('u4', 'Sam', '🍞', 'same. voted!'),
      ('u3', 'Priya', '📷', 'kinship has the back room, ive been'),
    ];
    var i = 0;
    _chatter = Timer.periodic(const Duration(seconds: 9), (t) {
      if (i >= lines.length) return t.cancel();
      final (id, name, avatar, body) = lines[i++];
      _messages.add(Message(
        id: 'c$i', authorId: id, authorName: name, avatar: avatar,
        body: body, sentAt: DateTime.now(),
      ));
      _emit();
    });
  }

  @override
  Future<void> castVenueVote(String groupId, String optionId) async {
    await Future.delayed(_lag);
    if (_myVote != null) _tally[_myVote!] = (_tally[_myVote!] ?? 1) - 1;
    _myVote = optionId;
    _tally[optionId] = (_tally[optionId] ?? 0) + 1;
  }

  @override
  Future<String?> myVenueVote(String groupId) async => _myVote;

  @override
  Future<Map<String, int>> venueTally(String groupId) async {
    await Future.delayed(_lag);
    return Map.unmodifiable(_tally);
  }

  @override
  Future<Assignment> assignment(String groupId) async {
    await Future.delayed(_lag);
    return const Assignment(
      targetId: 'u2', targetName: 'Tom',
      question: 'Ask Tom what the first record was that made him care about how something '
          'was mixed, rather than what it was.',
    );
  }

  @override
  Future<void> submitReflection(String groupId, String text, {bool wasFallback = false}) =>
      Future.delayed(_lag);

  @override
  Future<void> submitAttendance(String groupId, Map<String, bool> showedUp) =>
      Future.delayed(_lag);

  Set<String> _selected = {};
  @override
  Future<void> selectContacts(String groupId, Set<String> selectedIds) async {
    await Future.delayed(_lag);
    _selected = selectedIds;
  }

  /// Only reciprocated choices come back. In the mock, Maya and Tom picked you; Priya did
  /// not — and nothing in the result says so, which is the rule the real RLS enforces.
  @override
  Future<List<MutualContact>> mutualContacts(String groupId) async {
    await Future.delayed(_lag);
    const theyPicked = {'u1', 'u2', 'u5'};
    return _selected.where(theyPicked.contains).map((id) {
      final m = _members.firstWhere((x) => x.id == id);
      return MutualContact(
        id: m.id, displayName: m.displayName, avatar: m.avatar,
        phone: '+1 415 555 0${100 + _members.indexOf(m)}',
      );
    }).toList();
  }

  void dispose() {
    _chatter?.cancel();
    _controller.close();
  }
}
