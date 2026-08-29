import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme.dart';
import '../../models/profile_input.dart';
import '../../state/app_state.dart';

typedef PhotoPicker = Future<XFile?> Function();

/// Signup. Interests and photo are required, per the PRD -- interests are the matching
/// input, the photo is what makes the group feel like people rather than names.
class OnboardingScreen extends StatefulWidget {
  final AppState state;
  const OnboardingScreen(
    this.state, {
    super.key,
    this.pickPhoto,
    this.onComplete,
  });

  /// The platform picker is injected only by widget tests. Keeping the seam at the OS boundary
  /// lets tests exercise the approved photo step without weakening its required-photo contract.
  final PhotoPicker? pickPhoto;
  final VoidCallback? onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingScreen> {
  static const _interests = <({String id, String label, String emoji})>[
    (id: 'slow-coffee', label: 'Slow coffee', emoji: '☕'),
    (id: 'live-music', label: 'Live music', emoji: '🎻'),
    (id: 'hiking', label: 'Hiking', emoji: '🥾'),
    (id: 'books', label: 'Books', emoji: '📖'),
    (id: 'board-games', label: 'Board games', emoji: '🎲'),
    (id: 'food-markets', label: 'Food markets', emoji: '🥘'),
    (id: 'film', label: 'Film', emoji: '🎬'),
    (id: 'ceramics', label: 'Ceramics', emoji: '🏺'),
    (id: 'running', label: 'Running', emoji: '🏃'),
    (id: 'galleries', label: 'Galleries', emoji: '🖼️'),
    (id: 'cooking', label: 'Cooking', emoji: '🍳'),
    (id: 'photography', label: 'Photography', emoji: '📷'),
  ];

  var _step = 0;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _picked = <String>{};
  final _customInterests = <String>[];
  final _customInterest = TextEditingController();
  final _about = TextEditingController();
  final _availability = <String>{'fri_eve'};
  XFile? _photo;
  var _busy = false;

  bool get _canContinue => switch (_step) {
    0 => true,
    1 => _name.text.trim().isNotEmpty && normalizeSfPhone(_phone.text) != null,
    2 => _picked.length >= 2,
    _ =>
      _photo != null &&
          _about.text.trim().length > 10 &&
          _availability.isNotEmpty,
  };

  void _addCustomInterest() {
    final raw = _customInterest.text
        .trim()
        .replaceFirst(RegExp(r'^#+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (raw.isEmpty) return;

    final normalized = raw.toLowerCase();
    for (final interest in _interests) {
      if (interest.label.toLowerCase() != normalized) continue;
      setState(() {
        _picked.add(interest.id);
        _customInterest.clear();
      });
      return;
    }

    String? existing;
    for (final interest in _customInterests) {
      if (interest.toLowerCase() == normalized) {
        existing = interest;
        break;
      }
    }
    if (existing != null) {
      setState(() {
        _picked.add(normalized);
        _customInterest.clear();
      });
      return;
    }
    if (_customInterests.length >= 8) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('That is plenty of interests to match on.'),
          ),
        );
      return;
    }

    final label = raw.length > 24 ? raw.substring(0, 24) : raw;
    setState(() {
      _customInterests.add(label);
      _picked.add(label.toLowerCase());
      _customInterest.clear();
    });
  }

  Future<void> _pickPhoto() async {
    if (_busy) return;
    try {
      final picked = widget.pickPhoto != null
          ? await widget.pickPhoto!()
          : await ImagePicker().pickImage(
              source: ImageSource.gallery,
              maxWidth: 1200,
              imageQuality: 82,
            );
      if (picked != null && mounted) setState(() => _photo = picked);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open your photos. Check the app permission.',
            ),
          ),
        );
    }
  }

  Future<void> _continue() async {
    if (!_canContinue || _busy) return;
    if (_step < 3) {
      setState(() => _step += 1);
      return;
    }

    setState(() => _busy = true);
    try {
      final profile = await widget.state.repo.submitProfile(
        displayName: _name.text.trim(),
        avatar: '🙂',
        passion: _about.text.trim(),
        tags: _picked.toList(growable: false),
        city: 'SF',
        availability: _availability.toList(growable: false),
        phone: normalizeSfPhone(_phone.text)!,
        photoPath: _photo!.path,
      );
      if (widget.onComplete case final onComplete?) {
        onComplete();
      } else {
        await widget.state.completeOnboarding(profile);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't create your profile. Give it another go."),
          ),
        );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _customInterest.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 240),
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= _step ? accent : ink.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, .025),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: switch (_step) {
                    0 => const _WelcomeStep(),
                    1 => _IdentityStep(
                      nameController: _name,
                      phoneController: _phone,
                      onChanged: (_) => setState(() {}),
                    ),
                    2 => _InterestsStep(
                      picked: _picked,
                      customInterests: _customInterests,
                      customInterestController: _customInterest,
                      onAddCustomInterest: _addCustomInterest,
                      onToggle: (id) => setState(
                        () => _picked.contains(id)
                            ? _picked.remove(id)
                            : _picked.add(id),
                      ),
                    ),
                    _ => _PhotoStep(
                      photo: _photo,
                      aboutController: _about,
                      onAboutChanged: (_) => setState(() {}),
                      onPick: _pickPhoto,
                      onClear: () => setState(() => _photo = null),
                      availability: _availability,
                      onToggleAvailability: (slot) => setState(
                        () => _availability.contains(slot)
                            ? _availability.remove(slot)
                            : _availability.add(slot),
                      ),
                    ),
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            _PrimaryButton(
              label: _step == 3 ? 'Find my table' : 'Continue',
              enabled: _canContinue && !_busy,
              busy: _busy,
              onPressed: _continue,
            ),
          ],
        ),
      ),
    ),
  );
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SOLO MEETUPS',
          style: TextStyle(
            color: mutedInk,
            fontSize: 11,
            height: 1.3,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.98,
          ),
        ),
        SizedBox(height: 12),
        Text(
          'A table of four to six people who all came alone.',
          style: _welcomeTitle,
        ),
        SizedBox(height: 12),
        Text(
          "No plus-ones, no odd one out. You'll get one lighthearted question to ask one person, so there's nothing to figure out when you arrive.",
          style: _body,
        ),
      ],
    ),
  );
}

class _IdentityStep extends StatelessWidget {
  const _IdentityStep({
    required this.nameController,
    required this.phoneController,
    required this.onChanged,
  });

  final TextEditingController nameController;
  final TextEditingController phoneController;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('A little about you', style: _stepTitle),
        const SizedBox(height: 8),
        const Text(
          'Your first name is visible to your group. Your number stays private unless you and someone else both choose to share after the meetup.',
          style: TextStyle(color: bodyInk, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('display-name-input'),
          controller: nameController,
          onChanged: onChanged,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.givenName],
          decoration: const InputDecoration(
            labelText: 'First name',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('phone-input'),
          controller: phoneController,
          onChanged: onChanged,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: const InputDecoration(
            labelText: 'Phone number',
            hintText: '(415) 555-0123',
          ),
        ),
      ],
    ),
  );
}

class _InterestsStep extends StatelessWidget {
  const _InterestsStep({
    required this.picked,
    required this.customInterests,
    required this.customInterestController,
    required this.onAddCustomInterest,
    required this.onToggle,
  });

  final Set<String> picked;
  final List<String> customInterests;
  final TextEditingController customInterestController;
  final VoidCallback onAddCustomInterest;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('What would you actually show up for?', style: _stepTitle),
        const SizedBox(height: 8),
        const Text(
          'Pick at least two. This is how we match your table.',
          style: TextStyle(color: bodyInk, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final interest in _OnboardingFlowState._interests)
                      _InterestChip(
                        emoji: interest.emoji,
                        label: interest.label,
                        selected: picked.contains(interest.id),
                        onTap: () => onToggle(interest.id),
                      ),
                    for (final interest in customInterests)
                      _InterestChip(
                        emoji: '✦',
                        label: interest,
                        selected: picked.contains(interest.toLowerCase()),
                        onTap: () => onToggle(interest.toLowerCase()),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'Something else?',
                  style: TextStyle(
                    color: ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('custom-interest-input'),
                        controller: customInterestController,
                        onSubmitted: (_) => onAddCustomInterest(),
                        maxLength: 24,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          hintText: 'Add your own interest',
                          counterText: '',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('add-custom-interest'),
                      onPressed: onAddCustomInterest,
                      style: IconButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: ink,
                      ),
                      icon: const Icon(Icons.add),
                      tooltip: 'Add interest',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _InterestChip extends StatelessWidget {
  const _InterestChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? accent : surface,
          border: Border.all(
            color: selected ? ink.withValues(alpha: .40) : ink,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13, height: 1.25)),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: ink,
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PhotoStep extends StatelessWidget {
  const _PhotoStep({
    required this.photo,
    required this.aboutController,
    required this.onAboutChanged,
    required this.onPick,
    required this.onClear,
    required this.availability,
    required this.onToggleAvailability,
  });

  final XFile? photo;
  final TextEditingController aboutController;
  final ValueChanged<String> onAboutChanged;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final Set<String> availability;
  final ValueChanged<String> onToggleAvailability;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add a photo', style: _stepTitle),
        const SizedBox(height: 8),
        const Text(
          "It's what makes your group feel like people instead of names. Required, and only your group sees it.",
          style: TextStyle(color: bodyInk, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 24),
        Align(
          child: Semantics(
            button: true,
            label: photo == null ? 'Tap to upload' : 'Your photo',
            child: InkWell(
              onTap: onPick,
              customBorder: const CircleBorder(),
              child: Container(
                width: 160,
                height: 160,
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bg,
                  shape: BoxShape.circle,
                  border: Border.all(color: ink),
                ),
                child: photo == null
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          'Tap to upload',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: bodyInk,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
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
        ),
        if (photo != null) ...[
          const SizedBox(height: 12),
          Align(
            child: TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: bodyInk,
                textStyle: const TextStyle(
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                  decorationColor: bodyInk,
                ),
              ),
              child: const Text('Choose another'),
            ),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'What are you passionate about?',
          style: TextStyle(
            color: ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'The thing you could talk about all night. This helps us match your table.',
          style: TextStyle(color: bodyInk, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('about-yourself-input'),
          controller: aboutController,
          onChanged: onAboutChanged,
          minLines: 3,
          maxLines: 4,
          maxLength: 280,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Tell us what lights you up…',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'When are you usually free?',
          style: TextStyle(
            color: ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final slot in const <(String, String)>[
              ('fri_eve', 'Friday evening'),
              ('sat_day', 'Saturday daytime'),
              ('sat_eve', 'Saturday evening'),
              ('sun_day', 'Sunday daytime'),
            ])
              FilterChip(
                label: Text(slot.$2),
                selected: availability.contains(slot.$1),
                onSelected: (_) => onToggleAvailability(slot.$1),
              ),
          ],
        ),
      ],
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : .4,
    child: Material(
      color: accent,
      shape: StadiumBorder(side: BorderSide(color: ink.withValues(alpha: .40))),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        customBorder: const StadiumBorder(),
        child: SizedBox(
          width: double.infinity,
          height: 49,
          child: Center(
            child: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                : Text(
                    label,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}

const _welcomeTitle = TextStyle(
  fontFamily: 'Georgia',
  color: ink,
  fontSize: 30,
  height: 1.25,
  fontWeight: FontWeight.w500,
  letterSpacing: -.25,
);

const _stepTitle = TextStyle(
  fontFamily: 'Georgia',
  color: ink,
  fontSize: 24,
  height: 1.25,
  fontWeight: FontWeight.w500,
  letterSpacing: -.2,
);

const _body = TextStyle(color: bodyInk, fontSize: 14, height: 1.62);
