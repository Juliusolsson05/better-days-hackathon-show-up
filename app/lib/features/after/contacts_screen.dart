import 'package:flutter/material.dart';

import '../../core/theme.dart';
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
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (contacts.isEmpty) ...[
          const SizedBox(height: 60),
          Center(child: Text('🌱', style: const TextStyle(fontSize: 48))),
          const SizedBox(height: 20),
          const Center(
            child: Text('No matches this time',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('You are in the next one automatically.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.55))),
          ),
        ] else ...[
          Text('${contacts.length} of you picked each other.',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          for (final c in contacts)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: surface, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Avatar(c.avatar),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(c.phone,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
                ]),
              ]),
            ),
        ],
        const SizedBox(height: 30),
        Text(
          'The group chat stays open. Nothing here expires.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.4)),
        ),
      ]),
    );
  }
}
