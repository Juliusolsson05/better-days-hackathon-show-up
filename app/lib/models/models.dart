// Domain models. Deliberately plain: no codegen, no freezed, no json_serializable.
// Hand-written fromMap keeps the Supabase swap honest without a build_runner step.

// `auth` is the first phase only when the app runs against the real backend
// (--dart-define=USE_SUPABASE=true); the mock flow skips straight to onboarding.
enum Phase { auth, onboarding, waiting, matched, during, after, contacts }

class Profile {
  final String id;
  final String displayName;
  final String avatar; // emoji stand-in; real build uploads to Supabase Storage
  final String passion;
  final List<String> tags;
  final String city;
  final List<String> availability;
  final String phone;

  const Profile({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.passion,
    required this.tags,
    required this.city,
    required this.availability,
    required this.phone,
  });
}

class Member {
  final String id;
  final String displayName;
  final String avatar;
  final List<String> tags;
  final String? photoUrl;
  const Member({
    required this.id,
    required this.displayName,
    required this.avatar,
    this.tags = const [],
    this.photoUrl,
  });
}

class VenueOption {
  final String id;
  final String name;
  final String address;
  final String pitch; // one line, written for this group
  final List<String> categories;
  // Coordinates come from grounded venue retrieval, but remain nullable so legacy groups can
  // still render. The map degrades to the address rather than making missing backfill data a
  // reason the whole group screen fails.
  final double? lat;
  final double? lng;
  const VenueOption({
    required this.id,
    required this.name,
    required this.address,
    required this.pitch,
    required this.categories,
    this.lat,
    this.lng,
  });

  bool get hasLocation => lat != null && lng != null;
}

class Group {
  final String id;
  final DateTime eventAt;
  final List<Member> members;
  final List<VenueOption> venueOptions;
  final String? chosenVenueId;
  final String activity;
  const Group({
    required this.id,
    required this.eventAt,
    required this.members,
    required this.venueOptions,
    required this.activity,
    this.chosenVenueId,
  });

  VenueOption? get chosenVenue => chosenVenueId == null
      ? null
      : venueOptions.firstWhere((v) => v.id == chosenVenueId);
}

enum MessageKind { user, venueVote, system }

/// Where a message is in its journey to the server.
///
/// Only ever [sending] or [failed] for messages this device wrote and has not yet seen
/// echoed back. Everything that arrives from the server is [sent] by definition.
enum MessageStatus { sent, sending, failed }

class Message {
  final String id;
  final String authorId;
  final String authorName;
  final String avatar;
  final String body;
  final DateTime sentAt;
  final MessageKind kind;
  final String? authorPhotoUrl;

  /// The uuid this device generated before sending, echoed back on the server row.
  ///
  /// It is what ties an optimistic bubble to the row that eventually arrives through the
  /// realtime subscription -- `id` is a bigserial the client cannot know in advance, so
  /// without this the message renders twice for a beat. Null on anything written
  /// server-side (system framing, the vote anchor), which has no client to generate one.
  final String? clientMsgId;

  final MessageStatus status;
  const Message({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.avatar,
    required this.body,
    required this.sentAt,
    this.kind = MessageKind.user,
    this.authorPhotoUrl,
    this.clientMsgId,
    this.status = MessageStatus.sent,
  });

  Message copyWith({MessageStatus? status}) => Message(
    id: id,
    authorId: authorId,
    authorName: authorName,
    avatar: avatar,
    body: body,
    sentAt: sentAt,
    kind: kind,
    authorPhotoUrl: authorPhotoUrl,
    clientMsgId: clientMsgId,
    status: status ?? this.status,
  );

  /// 'me' is the sentinel both repositories map the current user onto, so the chat screen
  /// does not need to know whether it is talking to the mock or to Supabase.
  bool get isMine => authorId == 'me';
}

/// Your private assignment. Never shown to the group -- that is the whole point.
class Assignment {
  final String targetId;
  final String targetName;
  final String question;
  const Assignment({
    required this.targetId,
    required this.targetName,
    required this.question,
  });
}

class MutualContact {
  final String id;
  final String displayName;
  final String avatar;
  final String phone;
  final String? photoUrl;
  const MutualContact({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.phone,
    this.photoUrl,
  });
}
