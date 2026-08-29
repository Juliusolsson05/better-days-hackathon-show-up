// Domain models. Deliberately plain: no codegen, no freezed, no json_serializable.
// Hand-written fromMap keeps the Supabase swap honest without a build_runner step.

enum Phase { auth, onboarding, waiting, matched, during, after, contacts }

/// Server-owned lifecycle returned by current_experience(). The app may present these states but
/// never derives them from its own clock or from the mere existence of a membership row.
enum ExperienceState { preMeetup, during, after, completed, cancelled }

/// RSVP is persisted separately from membership because being placed in a group and agreeing
/// to attend are different facts. Keeping the pending state explicit prevents a missing row or
/// failed read from being presented as a decline.
enum RsvpStatus { pending, confirmed, declined }

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

/// The server-owned venue pipeline state.
///
/// This is intentionally not inferred from nullable option/result rows. Group formation, venue
/// retrieval, and vote finalization are separate transactions, so an empty projection can mean
/// "not ready", "failed", or "this group predates voting". Postgres records that distinction and
/// Flutter must preserve it or a legacy display venue can accidentally become a writable ballot.
enum VenueStatus { pending, voting, chosen, failed, legacy }

class Group {
  final String id;
  final DateTime eventAt;
  final List<Member> members;
  final List<VenueOption> venueOptions;
  final String? chosenVenueId;
  final VenueStatus venueStatus;
  final String activity;
  const Group({
    required this.id,
    required this.eventAt,
    required this.members,
    required this.venueOptions,
    required this.activity,
    this.chosenVenueId,
    VenueStatus? venueStatus,
  }) : venueStatus =
           venueStatus ??
           (chosenVenueId == null ? VenueStatus.voting : VenueStatus.chosen);

  /// Only typed options in the explicit voting state accept a ballot.
  ///
  /// In particular, a legacy venue also lives in [venueOptions] so the existing map/avatar
  /// presentation can be reused, but its synthetic `legacy:<group>` id is not a Postgres UUID and
  /// must never cross the vote API boundary.
  bool get venueVoteOpen =>
      venueStatus == VenueStatus.voting && chosenVenueId == null;

  /// Whether polling can still reveal a meaningful venue transition.
  bool get venueNeedsRefresh =>
      venueStatus == VenueStatus.pending || venueStatus == VenueStatus.voting;

  VenueOption? get chosenVenue {
    if (venueStatus == VenueStatus.legacy) {
      return venueOptions.isEmpty ? null : venueOptions.first;
    }
    if (chosenVenueId == null) return null;
    // Group finalization and option projection are separate reads. During a deploy, retry, or
    // stale mobile cache the winning id can arrive before its option row; crashing every chat
    // surface is a much worse interpretation than briefly showing the existing "vote pending"
    // state. The next group refresh repairs the projection without inventing venue details.
    for (final venue in venueOptions) {
      if (venue.id == chosenVenueId) return venue;
    }
    return null;
  }
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

/// A note another member wrote about the current user after the meetup.
///
/// This model deliberately has no `aboutUserId`: Postgres RLS returns only rows addressed to the
/// caller and only after they have submitted their own reflection. Carrying a broader shape into
/// Flutter would suggest the client can browse a group's private notes when it cannot and must not.
class ReceivedReflection {
  final String authorId;
  final String authorName;
  final String authorAvatar;
  final String text;
  final String? authorPhotoUrl;

  const ReceivedReflection({
    required this.authorId,
    required this.authorName,
    required this.authorAvatar,
    required this.text,
    this.authorPhotoUrl,
  });
}
