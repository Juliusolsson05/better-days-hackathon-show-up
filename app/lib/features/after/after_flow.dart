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
      await widget.state.repo
          .submitReflection(g.id, _learned.text.trim(), wasFallback: _fallback);
    } else if (_step == 1) {
      await widget.state.repo.submitAttendance(g.id, _showedUp);
    } else {
      await widget.state.repo.selectContacts(g.id, _selected);
      await widget.state.loadContacts();
      return;
    }
    setState(() { _step++; _busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(['What stuck', 'Who showed up', 'Numbers'][_step]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: LinearProgressIndicator(
            value: (_step + 1) / 3, minHeight: 2,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: const AlwaysStoppedAnimation(accent),
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
        padding: const EdgeInsets.all(20),
        children: [
      Text(
        _fallback
            ? 'No problem. What did you learn about anyone else?'
            : 'What did you learn from ${a?.targetName ?? 'your person'}?',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
      ),
      const SizedBox(height: 8),
      Text('They will see this, and you will see theirs.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.55))),
      const SizedBox(height: 20),
      TextField(
        controller: _learned, maxLines: 5, autofocus: true,
        decoration: const InputDecoration(hintText: 'Whatever stuck with you.'),
      ),
      const SizedBox(height: 16),
      // The PRD's fallback: if your target did not show, answer about anyone else.
      if (!_fallback)
        TextButton(
          onPressed: () => setState(() => _fallback = true),
          child: Text('${a?.targetName ?? 'They'} did not show up'),
        ),
    ]);
  }

  Widget _attendance() {
    return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: [
      const Text('Who made it?',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('Nothing happens to anyone who did not. This just keeps the record honest.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.55), height: 1.4)),
      const SizedBox(height: 20),
      for (final m in _others)
        SwitchListTile(
          value: _showedUp[m.id] ?? true,
          onChanged: (v) => setState(() => _showedUp[m.id] = v),
          activeThumbColor: accent,
          contentPadding: EdgeInsets.zero,
          secondary: Avatar(m.avatar),
          title: Text(m.displayName),
        ),
    ]);
  }

  Widget _contacts() {
    return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(20),
        children: [
      const Text('Swap numbers with anyone?',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
        'Numbers only appear if you both picked each other. Nobody is told they were not '
        'picked — including you.',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), height: 1.4),
      ),
      const SizedBox(height: 20),
      for (final m in _others)
        CheckboxListTile(
          value: _selected.contains(m.id),
          onChanged: (v) => setState(
              () => v! ? _selected.add(m.id) : _selected.remove(m.id)),
          activeColor: accent,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          secondary: Avatar(m.avatar),
          title: Text(m.displayName),
        ),
    ]);
  }
}
