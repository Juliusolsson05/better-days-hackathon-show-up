import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';

/// One flow, three steps, exactly as the PRD describes: what did you learn, who showed
/// up, who would you swap numbers with.
class AfterFlow extends StatefulWidget {
  final AppState state;
  const AfterFlow(this.state, {super.key});

  @override
  State<AfterFlow> createState() => _AfterFlowState();
}

class _AfterFlowState extends State<AfterFlow> {
  int _step = 0;
  final _learned = TextEditingController();
  bool _fallback = false;
  final _showedUp = <String, bool>{};
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  List<Member> get _others =>
      widget.state.group!.members.where((member) => member.id != 'me').toList();

  Future<void> _next() async {
    // Empty reflections are rejected before any network work. The database also protects its
    // shape, but keeping the person on the same step gives them an actionable recovery path.
    if (_step == 0 && _learned.text.trim().isEmpty) {
      setState(() => _error = 'Write one thing that stuck with you.');
      return;
    }

    final group = widget.state.group!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_step == 0) {
        await widget.state.repo.submitReflection(
          group.id,
          _learned.text.trim(),
          wasFallback: _fallback,
        );
      } else if (_step == 1) {
        await widget.state.repo.submitAttendance(group.id, _showedUp);
      } else {
        await widget.state.repo.selectContacts(group.id, _selected);
        // loadContacts reads the server-derived mutual set and performs the phase transition.
        // Navigating from the local selection would reveal unreciprocated choices and violate
        // the privacy contract this flow is specifically meant to preserve.
        await widget.state.loadContacts();
        return;
      }

      if (mounted) setState(() => _step++);
    } catch (_) {
      // Every step is independently durable. Staying put on failure lets a retry upsert the same
      // record instead of advancing the UI beyond data that never reached the backend.
      if (mounted) setState(() => _error = 'That did not save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    // AfterFlow may unmount when loadContacts changes the global phase. Releasing this controller
    // here avoids retaining its listener and the potentially personal reflection text afterward.
    _learned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(['What stuck', 'Who showed up', 'Numbers'][_step]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: LinearProgressIndicator(
            value: (_step + 1) / 3,
            minHeight: 2,
            backgroundColor: line,
            valueColor: const AlwaysStoppedAnimation(inkDeep),
          ),
        ),
      ),
      body: [_reflection(), _attendance(), _contacts()][_step],
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _next,
                  child: Text(_step == 2 ? 'Done' : 'Next'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reflection() {
    final assignment = widget.state.assignment;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          _fallback
              ? 'No problem. What did you learn about anyone else?'
              : 'What did you learn from ${assignment?.targetName ?? 'your person'}?',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'They will see this, and you will see theirs.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _learned,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Whatever stuck with you.',
          ),
        ),
        const SizedBox(height: 16),
        // The fallback is intentionally private and changes only the reflection's target. It must
        // not create a public accusation or skip the reflection just because the assigned person
        // was absent.
        if (!_fallback)
          TextButton(
            onPressed: () => setState(() => _fallback = true),
            child: Text('${assignment?.targetName ?? 'They'} did not show up'),
          ),
      ],
    );
  }

  Widget _attendance() {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      children: [
        Text('Who made it?', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Nothing happens to anyone who did not. This just keeps the record honest.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(cardRadius),
          ),
          child: Column(
            children: [
              for (var i = 0; i < _others.length; i++) ...[
                SwitchListTile(
                  value: _showedUp[_others[i].id] ?? true,
                  onChanged: (value) =>
                      setState(() => _showedUp[_others[i].id] = value),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  // Photos are signed by the repository because the storage bucket is private.
                  // The emoji remains Avatar's fallback, not a reason to discard that signed URL.
                  secondary: Avatar(
                    _others[i].avatar,
                    imageUrl: _others[i].photoUrl,
                  ),
                  title: Text(_others[i].displayName),
                ),
                if (i != _others.length - 1)
                  const Divider(indent: 72, endIndent: 16),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _contacts() {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Swap numbers with anyone?',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Numbers only appear if you both picked each other. Nobody is told they were not '
          'picked, including you.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(cardRadius),
          ),
          child: Column(
            children: [
              for (var i = 0; i < _others.length; i++) ...[
                CheckboxListTile(
                  value: _selected.contains(_others[i].id),
                  onChanged: (value) => setState(
                    () => value!
                        ? _selected.add(_others[i].id)
                        : _selected.remove(_others[i].id),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  controlAffinity: ListTileControlAffinity.trailing,
                  secondary: Avatar(
                    _others[i].avatar,
                    imageUrl: _others[i].photoUrl,
                  ),
                  title: Text(_others[i].displayName),
                ),
                if (i != _others.length - 1)
                  const Divider(indent: 72, endIndent: 16),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
