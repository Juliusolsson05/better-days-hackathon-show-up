import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';

/// The intended endpoint. Once numbers are exchanged the group can leave the app, and
/// this product treats that as success rather than churn.
class ContactsScreen extends StatelessWidget {
  final AppState state;
  const ContactsScreen(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final contacts = state.contacts;
    return Scaffold(
      appBar: AppBar(title: const Text('Numbers')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (contacts.isEmpty) ...[
            const SizedBox(height: 60),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: accentPale,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.eco_outlined, size: 34, color: inkDeep),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                'No matches this time',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'You are in the next one automatically.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ] else ...[
            for (final contact in contacts)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(cardRadius),
                ),
                child: Row(
                  children: [
                    // The repository turns private storage paths into short-lived signed URLs.
                    // Dropping photoUrl during a visual restyle would silently replace real
                    // people with emoji even though the privacy-safe image is already loaded.
                    Avatar(contact.avatar, imageUrl: contact.photoUrl),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contact.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            contact.phone,
                            style: const TextStyle(
                              color: inkDeep,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 30),
          Text(
            'The group chat stays open. Nothing here expires.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // Contacts are a durable endpoint, not a modal dead end. The explicit route back keeps
          // the still-open group chat reachable after either a mutual match or an empty result.
          OutlinedButton(
            onPressed: () => state.goTo(Phase.matched),
            child: const Text('Back to group chat'),
          ),
        ],
      ),
    );
  }
}
