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

  List<Member> get _others =>
      widget.state.group!.members.where((m) => m.id != 'me').toList();

  Future<void> _next() async {
    final g = widget.state.group!;
    setState(() => _busy = true);
    if (_step == 0) {
      await widget.state.repo.submitReflection(
        g.id,
        _learned.text.trim(),
        wasFallback: _fallback,
      );
    } else if (_step == 1) {
      await widget.state.repo.submitAttendance(g.id, _showedUp);
    } else {
      await widget.state.repo.selectContacts(g.id, _selected);
      await widget.state.loadContacts();
      return;
    }
    setState(() {
      _step++;
      _busy = false;
    });
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
          child: FilledButton(
            onPressed: _busy ? null : _next,
            child: Text(_step == 2 ? 'Done' : 'Next'),
          ),
        ),
      ),
    );
  }

  Widget _reflection() {
    final a = widget.state.assignment;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          _fallback
              ? 'No problem. What did you learn about anyone else?'
              : 'What did you learn from ${a?.targetName ?? 'your person'}?',
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
        // The PRD's fallback: if your target did not show, answer about anyone else.
        if (!_fallback)
          TextButton(
            onPressed: () => setState(() => _fallback = true),
            child: Text('${a?.targetName ?? 'They'} did not show up'),
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
                  onChanged: (v) =>
                      setState(() => _showedUp[_others[i].id] = v),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  secondary: Avatar(_others[i].avatar),
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
                  onChanged: (v) => setState(
                    () => v!
                        ? _selected.add(_others[i].id)
                        : _selected.remove(_others[i].id),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  controlAffinity: ListTileControlAffinity.trailing,
                  secondary: Avatar(_others[i].avatar),
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
