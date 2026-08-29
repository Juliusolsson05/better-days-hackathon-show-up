import 'package:flutter_test/flutter_test.dart';
import 'package:showup/data/supabase_repository.dart';
import 'package:showup/models/models.dart';

void main() {
  test(
    'reflection RPC payload leaves author and assignment target server-owned',
    () {
      final params = reflectionSubmissionParams(
        groupId: '2f8b1c34-0000-4000-8000-000000000001',
        text: 'The first ten minutes felt easier than I expected.',
        wasFallback: false,
      );

      expect(params, {
        'grp': '2f8b1c34-0000-4000-8000-000000000001',
        'reflection_text': 'The first ten minutes felt easier than I expected.',
        'fallback': false,
      });
      // These are the two values a hostile client could previously forge through the direct-table
      // upsert. Their absence is more important than the spelling of any presentation field above.
      expect(params, isNot(contains('user_id')));
      expect(params, isNot(contains('about_user')));
    },
  );

  test('message RPC payload leaves author and message kind server-owned', () {
    final params = messageSubmissionParams(
      groupId: '2f8b1c34-0000-4000-8000-000000000001',
      clientMsgId: '2f8b1c34-0000-4000-8000-000000000002',
      body: 'See you there',
    );

    expect(params, {
      'grp': '2f8b1c34-0000-4000-8000-000000000001',
      'client_id': '2f8b1c34-0000-4000-8000-000000000002',
      'message_body': 'See you there',
    });
    expect(params, isNot(contains('user_id')));
    expect(params, isNot(contains('kind')));
    expect(params, isNot(contains('created_at')));
  });

  test('RSVP RPC payload leaves identity and deadline server-owned', () {
    final params = rsvpSubmissionParams(
      groupId: '2f8b1c34-0000-4000-8000-000000000001',
      status: RsvpStatus.confirmed,
    );

    expect(params, {
      'grp': '2f8b1c34-0000-4000-8000-000000000001',
      'new_status': 'confirmed',
    });
    expect(params, isNot(contains('user_id')));
    expect(params, isNot(contains('rsvp_closes_at')));
  });
}
