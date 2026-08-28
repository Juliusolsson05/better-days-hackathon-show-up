import 'package:flutter_test/flutter_test.dart';
import 'package:showup/data/mock_repository.dart';
import 'package:showup/models/models.dart';
import 'package:showup/state/app_state.dart';

class _PastMeetupRepository extends MockRepository {
  @override
  Future<Group?> currentGroup() async => Group(
    id: 'past-group',
    eventAt: DateTime.now().subtract(const Duration(hours: 3)),
    members: const [
      Member(id: 'me', displayName: 'You', avatar: '🙂'),
      Member(id: 'u2', displayName: 'Tom', avatar: '🎧'),
      Member(id: 'u3', displayName: 'Priya', avatar: '📷'),
      Member(id: 'u4', displayName: 'Sam', avatar: '🍞'),
    ],
    venueOptions: const [],
    activity: 'Talk',
  );
}

class _OtpRepository extends MockRepository {
  _OtpRepository({required this.profileExists, this.restoredGroup});

  final bool profileExists;
  final Group? restoredGroup;
  bool verified = false;
  int profileChecks = 0;
  int groupChecks = 0;

  @override
  Future<void> verifyEmailOtp(String email, String token) async {
    verified = true;
  }

  @override
  Future<bool> hasProfile() async {
    profileChecks++;
    return profileExists;
  }

  @override
  Future<Group?> currentGroup() async {
    groupChecks++;
    return restoredGroup;
  }

  @override
  Future<Assignment> assignment(String groupId) async => const Assignment(
    targetId: 'u2',
    targetName: 'Tom',
    question: 'What made you care about this?',
  );
}

Group _futureGroup() => Group(
  id: 'restored-group',
  eventAt: DateTime(2030, 1, 1, 19),
  members: const [
    Member(id: 'me', displayName: 'You', avatar: '🙂'),
    Member(id: 'u2', displayName: 'Tom', avatar: '🎧'),
  ],
  venueOptions: const [],
  activity: 'Talk',
);

Future<void> _completeProfile(MockRepository repo) => repo.submitProfile(
  displayName: 'Test User',
  avatar: '🙂',
  passion:
      'I care enough about testing production flows to write the details down.',
  tags: const ['testing'],
  city: 'SF',
  availability: const ['fri_eve'],
  phone: '+14155550100',
  photoPath: '/fixture/profile.jpg',
);

void main() {
  test(
    'a real past meetup enters after-flow once, including zero selections',
    () async {
      final repo = _PastMeetupRepository();
      addTearDown(repo.dispose);
      await _completeProfile(repo);

      final firstLaunch = AppState(repo);
      await firstLaunch.restore();
      expect(firstLaunch.phase, Phase.after);

      // Selecting nobody is intentionally valid. Completion needs its own durable fact; inferring
      // it from contact rows would make this person repeat the recap forever.
      await repo.selectContacts('past-group', const {});

      final nextLaunch = AppState(repo);
      await nextLaunch.restore();
      expect(nextLaunch.phase, Phase.matched);
    },
  );

  test('RSVP persists before its funnel event is recorded', () async {
    final repo = _PastMeetupRepository();
    addTearDown(repo.dispose);

    await repo.setRsvp('past-group', RsvpStatus.confirmed);

    expect(await repo.myRsvp('past-group'), RsvpStatus.confirmed);
    expect(repo.tracked.last.event, 'rsvp');
    expect(repo.tracked.last.groupId, 'past-group');
  });

  test(
    'OTP restores an existing profile into its durable group phase',
    () async {
      final repo = _OtpRepository(
        profileExists: true,
        restoredGroup: _futureGroup(),
      );
      addTearDown(repo.dispose);
      final state = AppState(repo, initialPhase: Phase.auth);

      await state.verifyEmailOtp('returning@example.test', '123456');

      expect(repo.verified, isTrue);
      expect(repo.profileChecks, 1);
      expect(repo.groupChecks, 1);
      expect(state.group?.id, 'restored-group');
      expect(state.phase, Phase.matched);
    },
  );

  test('OTP keeps a genuinely new user in onboarding', () async {
    final repo = _OtpRepository(profileExists: false);
    addTearDown(repo.dispose);
    final state = AppState(repo, initialPhase: Phase.auth);

    await state.verifyEmailOtp('new@example.test', '123456');

    // currentGroup is intentionally untouched: matching state is meaningful only after the
    // required profile exists, and asking early would blur a missing profile into "waiting".
    expect(repo.verified, isTrue);
    expect(repo.profileChecks, 1);
    expect(repo.groupChecks, 0);
    expect(state.phase, Phase.onboarding);
  });
}
