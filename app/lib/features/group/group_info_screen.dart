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
    final venue = g.chosenVenue ?? g.venueOptions.first;
    return Scaffold(
      appBar: AppBar(title: const Text('Group')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
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
                    const Icon(Icons.place_outlined, size: 20, color: inkDeep),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        venue.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (g.chosenVenueId == null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: accentPale,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Voting open',
                          style: TextStyle(
                            fontSize: 11,
                            color: inkDeep,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  venue.address,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                VenueMap(venue),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            '${g.members.length} people',
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
                for (var i = 0; i < g.members.length; i++) ...[
                  _member(context, g.members[i]),
                  if (i != g.members.length - 1) const Divider(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _member(BuildContext context, Member m) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Avatar(m.avatar),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.displayName, style: Theme.of(context).textTheme.titleMedium),
            if (m.tags.isNotEmpty)
              Text(
                m.tags.join(', '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ],
    ),
  );
}
