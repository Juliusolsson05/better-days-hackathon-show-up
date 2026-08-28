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
    final g = state.group!;
    final venue = g.chosenVenue;
    return Scaffold(
      appBar: AppBar(title: const Text('Group')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          if (venue == null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                children: [
                  Icon(Icons.how_to_vote_outlined, size: 18, color: accent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Voting is still open. The destination appears here after everyone votes.',
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.place_outlined, size: 18, color: accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          venue.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    venue.address,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // A map before finalization would turn the first candidate into an implied
                  // winner. Rendering it only in this branch preserves the vote as the source
                  // of truth while still retaining the independently-built map feature.
                  VenueMap(venue),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Text(
            '${g.members.length} people',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final m in g.members) _member(m),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _member(Member m) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Avatar(m.avatar, imageUrl: m.photoUrl),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (m.tags.isNotEmpty)
              Text(
                m.tags.join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
