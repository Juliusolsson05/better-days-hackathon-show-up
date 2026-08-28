// Domain models. Deliberately plain: no codegen, no freezed, no json_serializable.
// Hand-written fromMap keeps the Supabase swap honest without a build_runner step.

enum Phase { onboarding, waiting, matched, during, after, contacts }

class Profile {
  final String id;
  final String displayName;
  final String avatar; // emoji stand-in; real build uploads to Supabase Storage
  final String passion;
  final List<String> tags;
  final String city;
  final List<String> availability;

  const Profile({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.passion,
    required this.tags,
    required this.city,
    required this.availability,
  });
}

class Member {
  final String id;
  final String displayName;
  final String avatar;
  final List<String> tags;
  const Member({
    required this.id,
    required this.displayName,
    required this.avatar,
    this.tags = const [],
  });
}

class VenueOption {
  final String id;
  final String name;
  final String address;
  final String pitch; // one line, written for this group
  final List<String> categories;
  const VenueOption({
    required this.id,
    required this.name,
    required this.address,
    required this.pitch,
    required this.categories,
  });
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

  VenueOption? get chosenVenue =>
      chosenVenueId == null ? null : venueOptions.firstWhere((v) => v.id == chosenVenueId);
}

enum MessageKind { user, venueVote, system }

class Message {
  final String id;
  final String authorId;
  final String authorName;
  final String avatar;
  final String body;
  final DateTime sentAt;
  final MessageKind kind;
  const Message({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.avatar,
    required this.body,
    required this.sentAt,
    this.kind = MessageKind.user,
  });
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
  const MutualContact({
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.phone,
  });
}
