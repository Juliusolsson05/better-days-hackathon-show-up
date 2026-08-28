import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../product/product_shell.dart';

/// Direct native translation of the reference onboarding. Fields absent from the approved
/// UX receive neutral values only at the repository boundary; restoring the old long form
/// here would make the experience structurally different from the source of truth.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen(this.state, {super.key});
  final AppState state;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const interests = <(IconData, String)>[
    (Icons.menu_book_rounded, 'Books'),
    (Icons.local_cafe_rounded, 'Slow coffee'),
    (Icons.hiking_rounded, 'Hiking'),
    (Icons.movie_rounded, 'Film'),
    (Icons.palette_rounded, 'Ceramics'),
    (Icons.ramen_dining_rounded, 'Food markets'),
    (Icons.image_rounded, 'Galleries'),
    (Icons.casino_rounded, 'Board games'),
    (Icons.music_note_rounded, 'Music'),
    (Icons.pedal_bike_rounded, 'Cycling'),
    (Icons.photo_camera_rounded, 'Photography'),
    (Icons.eco_rounded, 'Gardening'),
  ];
  final selected = <String>{};
  var step = 0;
  XFile? photo;
  var busy = false;
  bool get canContinue =>
      step == 0 || (step == 1 ? selected.length >= 2 : photo != null);

  Future<void> pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 84,
    );
    if (picked != null && mounted) setState(() => photo = picked);
  }

  Future<void> next() async {
    if (step < 2) return setState(() => step++);
    setState(() => busy = true);
    try {
      final profile = await widget.state.repo.submitProfile(
        displayName: 'You',
        avatar: '',
        passion: selected.join(', '),
        tags: selected.toList(),
        city: 'SF',
        availability: const ['weekend'],
        photoPath: photo?.path,
      );
      await widget.state.completeOnboarding(profile);
    } catch (_) {
      if (!mounted) return;
      setState(() => busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save your profile. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 18),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
                      decoration: BoxDecoration(
                        color: i <= step ? accent : const Color(0x190E0F0C),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: switch (step) {
                  0 => const _Welcome(key: ValueKey(0)),
                  1 => _Interests(
                    key: const ValueKey(1),
                    selected: selected,
                    onToggle: (value) => setState(() {
                      selected.contains(value)
                          ? selected.remove(value)
                          : selected.add(value);
                    }),
                  ),
                  _ => _PhotoStep(
                    key: const ValueKey(2),
                    photo: photo,
                    onPick: pickPhoto,
                  ),
                },
              ),
            ),
            FilledButton(
              onPressed: canContinue && !busy ? next : null,
              child: Text(step == 2 ? 'Find my table' : 'Continue'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: widget.state.skipOnboarding,
              child: const Text(
                'Skip onboarding',
                style: TextStyle(
                  decoration: TextDecoration.underline,
                  color: mutedInk,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SOLO MEETUPS',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
            color: mutedInk,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'A table of four to six people who all came alone.',
          style: displayStyle(30),
        ),
        const SizedBox(height: 12),
        const Text(
          "No plus-ones, no odd one out. You'll get one lighthearted question to ask one person, so there's nothing to figure out when you arrive.",
          style: TextStyle(fontSize: 14, height: 1.55, color: mutedInk),
        ),
      ],
    ),
  );
}

class _Interests extends StatelessWidget {
  const _Interests({super.key, required this.selected, required this.onToggle});
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What would you actually show up for?', style: displayStyle(24)),
        const SizedBox(height: 8),
        const Text(
          'Pick at least two. This is how we match your table.',
          style: TextStyle(fontSize: 13, color: mutedInk),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in _OnboardingScreenState.interests)
                  FilterChip(
                    avatar: Icon(item.$1, size: 17, color: ink),
                    label: Text(item.$2),
                    selected: selected.contains(item.$2),
                    showCheckmark: false,
                    onSelected: (_) => onToggle(item.$2),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PhotoStep extends StatelessWidget {
  const _PhotoStep({super.key, required this.photo, required this.onPick});
  final XFile? photo;
  final VoidCallback onPick;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add a photo', style: displayStyle(24)),
        const SizedBox(height: 8),
        const Text(
          "It's what makes your group feel like people instead of names. Required, and only your group sees it.",
          style: TextStyle(fontSize: 13, height: 1.45, color: mutedInk),
        ),
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            onTap: onPick,
            child: Container(
              width: 160,
              height: 160,
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: surface,
                border: Border.all(color: line),
              ),
              child: photo == null
                  ? const Text(
                      'Tap to upload',
                      style: TextStyle(fontSize: 12, color: mutedInk),
                    )
                  : Image.file(
                      File(photo!.path),
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                    ),
            ),
          ),
        ),
        if (photo != null)
          Center(
            child: TextButton(
              onPressed: onPick,
              child: const Text(
                'Choose another',
                style: TextStyle(
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                  color: mutedInk,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
