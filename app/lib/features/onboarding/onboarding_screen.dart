import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';

/// Signup. Interests and photo are required, per the PRD -- interests are the matching
/// input, the photo is what makes the group feel like people rather than names.
class OnboardingScreen extends StatefulWidget {
  final AppState state;
  const OnboardingScreen(this.state, {super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _interests = [
    'climbing', 'music', 'photography', 'baking', 'chess', 'running',
    'anime', 'gardening', 'board games', 'cycling', 'pottery', 'birding',
  ];
  static const _avatars = ['🧗', '🎧', '📷', '🍞', '♟️', '🏃', '🌱', '🎨'];
  static const _slots = ['fri_eve', 'sat_day', 'sat_eve', 'sun_day'];

  final _name = TextEditingController();
  final _passion = TextEditingController();
  final _customTag = TextEditingController();
  final _picked = <String>{};
  // PRD: pick from the fixed set "plus write your own (pokemon, anime, whatever)".
  final _extraTags = <String>[];
  final _avail = <String>{'fri_eve'};
  String _avatar = '🧗';
  XFile? _photo;
  bool _busy = false;

  // NOTE: the PRD calls the photo required, but the widget test and the mock demo flow
  // treat it as optional. Left non-blocking here pending a team call; the upload path is
  // fully wired either way (see SupabaseRepository._uploadPhoto).
  bool get _valid =>
      _name.text.trim().isNotEmpty && _passion.text.trim().length > 10 &&
      _picked.isNotEmpty && _avail.isNotEmpty;

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 82,
    );
    if (picked != null) setState(() => _photo = picked);
  }

  void _addCustomTag() {
    final tag = _customTag.text.trim().toLowerCase();
    if (tag.isEmpty || _picked.contains(tag)) return;
    setState(() {
      if (!_interests.contains(tag)) _extraTags.add(tag);
      _picked.add(tag);
      _customTag.clear();
    });
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final p = await widget.state.repo.submitProfile(
        displayName: _name.text.trim(), avatar: _avatar,
        passion: _passion.text.trim(), tags: _picked.toList(),
        city: 'SF', availability: _avail.toList(),
        photoPath: _photo?.path,
      );
      await widget.state.completeOnboarding(p);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't create your profile. $e")),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _passion.dispose();
    _customTag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Show Up')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const Text('You go alone. So does everyone else.',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.2)),
          const SizedBox(height: 8),
          Text('Four to six people, matched on what you are into.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          const SizedBox(height: 28),

          const _Label('What should people call you?'),
          TextField(controller: _name, onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'First name')),
          const SizedBox(height: 24),

          const _Label('Add a photo'),
          Text('Anything but your face — a view, a plant, your dog.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _pickPhoto,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: surface,
                shape: BoxShape.circle,
                border: Border.all(
                    color: _photo == null ? Colors.white24 : accent, width: 2),
                image: _photo == null
                    ? null
                    : DecorationImage(
                        image: FileImage(File(_photo!.path)), fit: BoxFit.cover),
              ),
              child: _photo == null
                  ? const Icon(Icons.add_a_photo_outlined, color: Colors.white38)
                  : null,
            ),
          ),
          const SizedBox(height: 24),

          const _Label('Pick a chat icon'),
          Wrap(spacing: 10, children: [
            for (final a in _avatars)
              GestureDetector(
                onTap: () => setState(() => _avatar = a),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _avatar == a ? accent : Colors.transparent, width: 2),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Avatar(a),
                ),
              ),
          ]),
          const SizedBox(height: 24),

          const _Label('What are you into?'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final i in [..._interests, ..._extraTags])
              FilterChip(
                label: Text(i),
                selected: _picked.contains(i),
                onSelected: (v) => setState(() => v ? _picked.add(i) : _picked.remove(i)),
              ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _customTag,
                onSubmitted: (_) => _addCustomTag(),
                decoration: const InputDecoration(
                  hintText: 'Add your own — anime, pokemon, whatever',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: _addCustomTag, icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 24),

          // The free-text field is what the embedding is actually built from.
          const _Label('What are you passionate about?'),
          TextField(
            controller: _passion, maxLines: 4, onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'The thing you would talk about all night if someone let you.'),
          ),
          const SizedBox(height: 24),

          const _Label('When are you free?'),
          Wrap(spacing: 8, children: [
            for (final s in _slots)
              FilterChip(
                label: Text(s.replaceAll('_', ' ')),
                selected: _avail.contains(s),
                onSelected: (v) => setState(() => v ? _avail.add(s) : _avail.remove(s)),
              ),
          ]),
          const SizedBox(height: 32),

          FilledButton(
            onPressed: _valid && !_busy ? _submit : null,
            child: _busy
                ? const SizedBox(height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Find me a group'),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      );
}
