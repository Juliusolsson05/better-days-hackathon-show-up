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
  const OnboardingScreen(this.state, {super.key, this.pickPhoto});

  /// The platform picker is injected only by widget tests. Keeping the seam at the OS boundary
  /// lets tests exercise the approved photo step without weakening its required-photo contract.
  final PhotoPicker? pickPhoto;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _interests = [
    'climbing',
    'music',
    'photography',
    'baking',
    'chess',
    'running',
    'anime',
    'gardening',
    'board games',
    'cycling',
    'pottery',
    'birding',
  ];
  static const _avatars = ['🧗', '🎧', '📷', '🍞', '♟️', '🏃', '🌱', '🎨'];
  static const _slots = ['fri_eve', 'sat_day', 'sat_eve', 'sun_day'];

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _passion = TextEditingController();
  final _customTag = TextEditingController();
  final _picked = <String>{};
  // PRD: pick from the fixed set "plus write your own (pokemon, anime, whatever)".
  final _extraTags = <String>[];
  final _avail = <String>{'fri_eve'};
  String _avatar = '🧗';
  XFile? _photo;
  bool _busy = false;

  String? get _normalizedPhone => normalizeSfPhone(_phone.text);

  // Photo and phone are not decoration: the former makes the matched group feel like people,
  // and the latter is the endpoint of mutual contact exchange. Letting either be absent creates
  // a profile that can enter matching but cannot complete the product loop.
  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _passion.text.trim().length > 10 &&
      _picked.isNotEmpty &&
      _avail.isNotEmpty &&
      _photo != null &&
      _normalizedPhone != null;

  static const _maxExtraTags = 8;

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
      if (picked != null && mounted) {
        setState(() => _photo = picked);
      }
    } catch (_) {
      // Permission denied, or the picker channel threw. Nothing actionable to show
      // beyond letting them try again.
      if (mounted) {
        _toast('Could not open your photos. Check the app permission.');
      }
    }
  }

  void _addCustomTag() {
    // Collapse whitespace, drop a leading '#', cap the length so one tag can't blow out
    // the chip row.
    final tag = _customTag.text
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^#+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (tag.isEmpty) return;
    if (_picked.contains(tag)) {
      _customTag.clear();
      return;
    }
    if (_extraTags.length >= _maxExtraTags) {
      _toast('That is plenty of interests to match on.');
      return;
    }
    setState(() {
      final known = _interests.contains(tag) || _extraTags.contains(tag);
      if (!known) {
        _extraTags.add(tag.length > 24 ? tag.substring(0, 24) : tag);
      }
      _picked.add(known ? tag : _extraTags.last);
      _customTag.clear();
    });
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final p = await widget.state.repo.submitProfile(
        displayName: _name.text.trim(),
        avatar: _avatar,
        passion: _passion.text.trim(),
        tags: _picked.toList(),
        city: 'SF',
        availability: _avail.toList(),
        phone: _normalizedPhone!,
        photoPath: _photo?.path,
      );
      await widget.state.completeOnboarding(p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final offline =
          e.toString().toLowerCase().contains('socket') ||
          e.toString().toLowerCase().contains('clientexception');
      _toast(
        offline
            ? "Couldn't reach the server. Check your connection and try again."
            : "Couldn't create your profile. Give it another go.",
      );
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _passion.dispose();
    _customTag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The approved mock is intentionally available only in the gated reference build. Its three
    // steps do not collect the private phone and matching prose required by the live Supabase
    // contract, so silently using it in production would trade visual parity for invalid profiles.
    // Keeping both presentations at this boundary makes the preview exact without weakening the
    // backend-capable flow while those missing fields await an approved product design.
    if (widget.state.referenceUiPreview) {
      return _ReferenceOnboarding(widget.state, pickPhoto: widget.pickPhoto);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Show Up')),
      body: ListView(
        // Scrolling away from a field should close its keyboard.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        children: [
          const ScreenIntro(
            'You go alone.\nSo does everyone else.',
            'Four to six people, matched on what you are into.',
          ),
          const SizedBox(height: 32),

          const _Label('What should people call you?'),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              hintText: 'First name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 24),

          const _Label('Your phone number'),
          Text(
            'Only people you choose who also choose you will ever see it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phone,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(hintText: '(415) 555-0123'),
          ),
          const SizedBox(height: 24),

          const _Label('Add a photo'),
          Text(
            'A clear photo of you — this is how the group recognizes each other.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Semantics(
            button: true,
            label: _photo == null ? 'Add a photo' : 'Change photo',
            child: GestureDetector(
              onTap: _pickPhoto,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _photo == null ? ink : positive,
                    width: 2,
                  ),
                  image: _photo == null
                      ? null
                      : DecorationImage(
                          image: FileImage(File(_photo!.path)),
                          fit: BoxFit.cover,
                        ),
                ),
                child: _photo == null
                    ? const Icon(Icons.add_a_photo_outlined, color: ink)
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 24),

          const _Label('Pick a chat icon'),
          Wrap(
            spacing: 10,
            children: [
              for (final a in _avatars)
                GestureDetector(
                  onTap: () => setState(() => _avatar = a),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _avatar == a ? inkDeep : Colors.transparent,
                        width: 2,
                      ),
                      color: _avatar == a ? accentPale : Colors.transparent,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Avatar(a),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),

          const _Label('What are you into?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final i in [..._interests, ..._extraTags])
                FilterChip(
                  label: Text(i),
                  selected: _picked.contains(i),
                  onSelected: (v) =>
                      setState(() => v ? _picked.add(i) : _picked.remove(i)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customTag,
                  onSubmitted: (_) => _addCustomTag(),
                  maxLength: 24,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Add your own: anime, pokemon, whatever',
                    isDense: true,
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _addCustomTag, icon: const Icon(Icons.add)),
            ],
          ),
          const SizedBox(height: 24),

          // The free-text field is what the embedding is actually built from.
          const _Label('What are you passionate about?'),
          TextField(
            controller: _passion,
            maxLines: 4,
            maxLength: 280,
            onChanged: (_) => setState(() {}),
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText:
                  'The thing you would talk about all night if someone let you.',
            ),
          ),
          const SizedBox(height: 24),

          const _Label('When are you free?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _slots)
                FilterChip(
                  label: Text(s.replaceAll('_', ' ')),
                  selected: _avail.contains(s),
                  onSelected: (v) =>
                      setState(() => v ? _avail.add(s) : _avail.remove(s)),
                ),
            ],
          ),
          const SizedBox(height: 32),

          FilledButton(
            onPressed: _valid && !_busy ? _submit : null,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                : const Text('Find me a group'),
          ),
        ],
      ),
    );
  }
}

class _ReferenceOnboarding extends StatefulWidget {
  const _ReferenceOnboarding(this.state, {this.pickPhoto});

  final AppState state;
  final PhotoPicker? pickPhoto;

  @override
  State<_ReferenceOnboarding> createState() => _ReferenceOnboardingState();
}

class _ReferenceOnboardingState extends State<_ReferenceOnboarding> {
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
  final _picked = <String>{};
  XFile? _photo;
  var _busy = false;

  bool get _canContinue => switch (_step) {
    0 => true,
    1 => _picked.length >= 2,
    _ => _photo != null,
  };

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
    if (_step < 2) {
      setState(() => _step += 1);
      return;
    }

    setState(() => _busy = true);
    try {
      final selectedLabels = [
        for (final interest in _interests)
          if (_picked.contains(interest.id)) interest.label,
      ];
      // The reference shell is backed exclusively by MockRepository. It still receives a real
      // Profile so the rest of AppState observes the same completion boundary as production, but
      // mock-only placeholders fill fields the approved three-step design deliberately omits.
      // This must never become a shortcut for Supabase; referenceUiPreview is gated to mocks in
      // app.dart specifically to preserve that invariant.
      final profile = await widget.state.repo.submitProfile(
        displayName: 'You',
        avatar: '🙂',
        passion: selectedLabels.join(', '),
        tags: _picked.toList(growable: false),
        city: 'SF',
        availability: const ['fri_eve'],
        phone: '+14155550123',
        photoPath: _photo!.path,
      );
      await widget.state.completeOnboarding(profile);
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
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < 3; i++) ...[
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
                    0 => const _ReferenceWelcomeStep(),
                    1 => _ReferenceInterestsStep(
                      picked: _picked,
                      onToggle: (id) => setState(
                        () => _picked.contains(id)
                            ? _picked.remove(id)
                            : _picked.add(id),
                      ),
                    ),
                    _ => _ReferencePhotoStep(
                      photo: _photo,
                      onPick: _pickPhoto,
                      onClear: () => setState(() => _photo = null),
                    ),
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),
            _ReferencePrimaryButton(
              label: _step == 2 ? 'Find my table' : 'Continue',
              enabled: _canContinue && !_busy,
              busy: _busy,
              onPressed: _continue,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : widget.state.skipOnboarding,
              style: TextButton.styleFrom(
                foregroundColor: mutedInk,
                minimumSize: const Size.fromHeight(32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: mutedInk,
                ),
              ),
              child: const Text('Skip onboarding'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ReferenceWelcomeStep extends StatelessWidget {
  const _ReferenceWelcomeStep();

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
          style: _referenceWelcomeTitle,
        ),
        SizedBox(height: 12),
        Text(
          "No plus-ones, no odd one out. You'll get one lighthearted question to ask one person, so there's nothing to figure out when you arrive.",
          style: _referenceBody,
        ),
      ],
    ),
  );
}

class _ReferenceInterestsStep extends StatelessWidget {
  const _ReferenceInterestsStep({required this.picked, required this.onToggle});

  final Set<String> picked;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What would you actually show up for?',
          style: _referenceStepTitle,
        ),
        const SizedBox(height: 8),
        const Text(
          'Pick at least two. This is how we match your table.',
          style: TextStyle(color: bodyInk, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final interest in _ReferenceOnboardingState._interests)
                  _ReferenceInterestChip(
                    emoji: interest.emoji,
                    label: interest.label,
                    selected: picked.contains(interest.id),
                    onTap: () => onToggle(interest.id),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ReferenceInterestChip extends StatelessWidget {
  const _ReferenceInterestChip({
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

class _ReferencePhotoStep extends StatelessWidget {
  const _ReferencePhotoStep({
    required this.photo,
    required this.onPick,
    required this.onClear,
  });

  final XFile? photo;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add a photo', style: _referenceStepTitle),
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
      ],
    ),
  );
}

class _ReferencePrimaryButton extends StatelessWidget {
  const _ReferencePrimaryButton({
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

const _referenceWelcomeTitle = TextStyle(
  fontFamily: 'Georgia',
  color: ink,
  fontSize: 30,
  height: 1.25,
  fontWeight: FontWeight.w500,
  letterSpacing: -.25,
);

const _referenceStepTitle = TextStyle(
  fontFamily: 'Georgia',
  color: ink,
  fontSize: 24,
  height: 1.25,
  fontWeight: FontWeight.w500,
  letterSpacing: -.2,
);

const _referenceBody = TextStyle(color: bodyInk, fontSize: 14, height: 1.62);

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
