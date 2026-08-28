import 'package:flutter_test/flutter_test.dart';
import 'package:showup/data/supabase_row_decoders.dart';
import 'package:showup/models/models.dart';

void main() {
  test('venue pipeline status is decoded from its durable database value', () {
    expect(decodeVenueStatus('pending'), VenueStatus.pending);
    expect(decodeVenueStatus('voting'), VenueStatus.voting);
    expect(decodeVenueStatus('chosen'), VenueStatus.chosen);
    expect(decodeVenueStatus('failed'), VenueStatus.failed);
    expect(decodeVenueStatus('legacy'), VenueStatus.legacy);
    expect(() => decodeVenueStatus('unknown'), throwsFormatException);
  });

  test('membership rows preserve UUIDs except for the local me sentinel', () {
    final me = decodeMemberRow(
      {
        'user_id': 'user-a',
        'profiles': {
          'display_name': 'Maya',
          'avatar': '🧗',
          'tags': ['climbing'],
        },
      },
      currentUserId: 'user-a',
      signedPhotoUrl: 'https://signed.test/me.jpg',
    );

    expect(me.id, 'me');
    expect(me.photoUrl, 'https://signed.test/me.jpg');
    expect(me.tags, ['climbing']);
  });

  test(
    'message rows get display identity from the already-authorized group roster',
    () {
      const member = Member(
        id: 'user-b',
        displayName: 'Tom',
        avatar: '🎧',
        photoUrl: 'https://signed.test/tom.jpg',
      );
      final message = decodeMessageRow(
        {
          'id': 42,
          'user_id': 'user-b',
          'body': 'hello',
          'kind': 'user',
          'client_msg_id': '10000000-0000-4000-8000-000000000001',
          'created_at': '2026-08-28T19:00:00Z',
        },
        currentUserId: 'user-a',
        membersByUserId: const {'user-b': member},
      );

      expect(message.authorName, 'Tom');
      expect(message.authorPhotoUrl, 'https://signed.test/tom.jpg');
      expect(message.clientMsgId, '10000000-0000-4000-8000-000000000001');
      expect(message.kind, MessageKind.user);
    },
  );

  test(
    'legacy venue JSON remains readable during the grounded-option rollout',
    () {
      final venue = decodeLegacyVenue({
        'name': 'Kinship',
        'address': '2801 Mission St',
        'why': 'quiet enough to talk',
        'lat': 37.75,
        'lng': -122.41,
      }, 'group-a');

      expect(venue?.id, 'legacy:group-a');
      expect(venue?.hasLocation, isTrue);
    },
  );

  test(
    'received reflection rows keep private text behind the decoder boundary',
    () {
      final note = decodeReceivedReflectionRow({
        'user_id': 'user-b',
        'what_stuck': 'You made the first ten minutes feel easy.',
        'profiles': {
          'display_name': 'Tom',
          'avatar': '🎧',
          // The durable storage path is intentionally not decoded into the model; the
          // repository must replace it with a short-lived URL after Storage authorizes it.
          'photo_url': 'user-b/profile.jpg',
        },
      }, signedPhotoUrl: 'https://signed.test/tom-reflection.jpg');

      expect(note.authorId, 'user-b');
      expect(note.authorName, 'Tom');
      expect(note.text, 'You made the first ten minutes feel easy.');
      expect(note.authorPhotoUrl, 'https://signed.test/tom-reflection.jpg');
    },
  );
}
