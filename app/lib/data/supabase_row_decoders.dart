import '../models/models.dart';

/// PostgREST returns untyped JSON maps, while widgets consume stable domain objects. Keeping
/// that translation in this one boundary is what lets a SQL column be renamed or a join shape
/// change without teaching every screen about database protocol details.
///
/// These functions are intentionally pure. The repository resolves private storage paths to
/// signed URLs first, then passes those URLs in; unit tests can therefore exercise every row
/// contract without booting Supabase or mocking a network client.

Member decodeMemberRow(
  Map<String, dynamic> row, {
  required String currentUserId,
  String? signedPhotoUrl,
}) {
  final userId = _requiredString(row, 'user_id');
  final profile = _requiredMap(row, 'profiles');
  return Member(
    // The presentation layer has always used `me` as its local identity sentinel. Mapping at
    // the boundary preserves that contract while every database write still uses the real UUID.
    id: userId == currentUserId ? 'me' : userId,
    displayName: _requiredString(profile, 'display_name'),
    avatar: _string(profile['avatar']) ?? '🙂',
    tags: _stringList(profile['tags']),
    photoUrl: signedPhotoUrl,
  );
}

VenueOption decodeVenueOptionRow(Map<String, dynamic> row) => VenueOption(
  id: _requiredString(row, 'id'),
  name: _requiredString(row, 'name'),
  address: _requiredString(row, 'address'),
  pitch: _requiredString(row, 'pitch'),
  categories: [_requiredString(row, 'kind')],
  lat: _double(row['lat']),
  lng: _double(row['lng']),
);

/// Groups created before grounded retrieval keep one JSON venue. It is decoded only when no
/// typed options exist, so an in-flight deployment can upgrade without blanking the map.
VenueOption? decodeLegacyVenue(Object? value, String groupId) {
  if (value is! Map) return null;
  final venue = Map<String, dynamic>.from(value);
  final name = _string(venue['name']);
  if (name == null || name.isEmpty) return null;
  return VenueOption(
    id: 'legacy:$groupId',
    name: name,
    address: _string(venue['address']) ?? 'Address coming soon',
    pitch: _string(venue['why']) ?? '',
    categories: const [],
    lat: _double(venue['lat']),
    lng: _double(venue['lng']),
  );
}

Message decodeMessageRow(
  Map<String, dynamic> row, {
  required String currentUserId,
  required Map<String, Member> membersByUserId,
}) {
  final rawAuthorId = _string(row['user_id']);
  final author = rawAuthorId == null ? null : membersByUserId[rawAuthorId];
  final kind = switch (_string(row['kind']) ?? 'user') {
    'venue_vote' => MessageKind.venueVote,
    'system' => MessageKind.system,
    _ => MessageKind.user,
  };

  return Message(
    id: '${row['id']}',
    authorId: rawAuthorId == currentUserId ? 'me' : (rawAuthorId ?? kind.name),
    authorName: author?.displayName ?? '',
    avatar: author?.avatar ?? '🙂',
    authorPhotoUrl: author?.photoUrl,
    body: _string(row['body']) ?? '',
    sentAt: DateTime.parse(_requiredString(row, 'created_at')),
    kind: kind,
  );
}

MutualContact decodeMutualContactRow(
  Map<String, dynamic> row, {
  String? signedPhotoUrl,
}) => MutualContact(
  id: _requiredString(row, 'user_id'),
  displayName: _requiredString(row, 'display_name'),
  avatar: _string(row['avatar']) ?? '🙂',
  phone: _requiredString(row, 'phone'),
  photoUrl: signedPhotoUrl,
);

Map<String, dynamic> nestedMap(Map<String, dynamic> row, String key) =>
    _requiredMap(row, key);

String? nullableString(Object? value) => _string(value);

Map<String, dynamic> _requiredMap(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException(
    'Expected $key to be an object, got ${value.runtimeType}',
  );
}

String _requiredString(Map<String, dynamic> row, String key) {
  final value = _string(row[key]);
  if (value != null) return value;
  throw FormatException('Expected $key to be a string');
}

String? _string(Object? value) => value is String ? value : null;

double? _double(Object? value) => value is num ? value.toDouble() : null;

List<String> _stringList(Object? value) => switch (value) {
  List<dynamic> values => values.whereType<String>().toList(growable: false),
  _ => const [],
};
