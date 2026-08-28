import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import 'venue_map.dart';

/// Reached by tapping the group name, the way WhatsApp group info works. Members and
/// photos only -- there is deliberately no profile page to navigate into.
class GroupInfoScreen extends StatelessWidget {
  final AppState state;
  const GroupInfoScreen(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final group = state.group!;
    final venue = group.chosenVenue;
    return Scaffold(
      appBar: AppBar(title: const Text('Group')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          if (venue == null)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(cardRadius),
              ),
              child: const Row(
                children: [
                  Icon(Icons.how_to_vote_outlined, size: 20, color: inkDeep),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Voting is still open. The destination appears here after everyone votes.',
                      style: TextStyle(color: bodyInk, height: 1.45),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(cardRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.place_outlined,
                        size: 20,
                        color: inkDeep,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          venue.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    venue.address,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  // A map before finalization gives the first candidate visual authority and
                  // implies the ballot no longer matters. Postgres' chosen_venue_id is the only
                  // winning signal, so location details exist exclusively in this branch.
                  VenueMap(venue),
                ],
              ),
            ),
          const SizedBox(height: 28),
          Text(
            '${group.members.length} people',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(cardRadius),
            ),
            child: Column(
              children: [
                for (var index = 0; index < group.members.length; index++) ...[
                  _member(context, group.members[index]),
                  if (index != group.members.length - 1) const Divider(),
                ],
              ],
            ),
          ),
          if (group.eventAt
              .add(const Duration(hours: 2))
              .isBefore(DateTime.now())) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => _showReceivedReflections(context, state),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('What people remembered'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                // Contacts can become mutual after this user finished the after-flow. Keeping
                // the only read behind that one-time flow made the durable RPC effectively
                // write-once/read-once: a later reciprocal choice was stored correctly but had
                // no production route back into the app. Pop the nested info route first so the
                // root phase transition can reveal ContactsScreen instead of changing invisibly
                // underneath this Navigator page.
                Navigator.pop(context);
                await state.loadContacts();
              },
              icon: const Icon(Icons.contact_phone_outlined),
              label: const Text('View mutual contacts'),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _member(BuildContext context, Member member) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        // Signed photo URLs are deliberately passed separately from the durable emoji.
        // The URL may expire between launches; Avatar can then fall back without losing the
        // member's identity or requiring group info to understand storage refresh policy.
        Avatar(member.avatar, imageUrl: member.photoUrl),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              member.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (member.tags.isNotEmpty)
              Text(
                member.tags.join(', '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ],
    ),
  );
}

Future<void> _showReceivedReflections(
  BuildContext context,
  AppState state,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final notes = await state.repo.receivedReflections(state.group!.id);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReflectionSheet(notes),
    );
  } catch (_) {
    // A missing reciprocal note is an ordinary empty result, while a failed read is recoverable.
    // Keep those distinct so an outage does not tell someone that nobody remembered them.
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not load reflections. Try again.')),
    );
  }
}

class _ReflectionSheet extends StatelessWidget {
  const _ReflectionSheet(this.notes);

  final List<ReceivedReflection> notes;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What people remembered',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            notes.isEmpty
                ? 'Nothing has come back yet. Reflections appear only after both sides write.'
                : 'Only notes written about you appear here.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            for (final note in notes)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(cardRadius),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Avatar(note.authorAvatar, imageUrl: note.authorPhotoUrl),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            note.authorName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(note.text),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    ),
  );
}
