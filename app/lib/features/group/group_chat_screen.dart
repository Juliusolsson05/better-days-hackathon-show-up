import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import 'group_info_screen.dart';
import 'question_sheet.dart';
import 'venue_vote_card.dart';

/// The product surface. Group formation and the chat opening are the same event, so this
/// is what a matched user lands on -- there is no lobby or roster screen in between.
class GroupChatScreen extends StatefulWidget {
  final AppState state;
  const GroupChatScreen(this.state, {super.key});
  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _groupRefresh;

  @override
  void initState() {
    super.initState();
    // Earlier voters cannot read anyone else's ballot (by design), so their screen receives
    // no row-level event when the final person votes. Refresh the tiny group projection rather
    // than weakening ballot privacy merely to make Realtime observable. Ten seconds is quick
    // enough for a result while keeping this far below chat traffic.
    _groupRefresh = Timer.periodic(
      const Duration(seconds: 10),
      (_) => widget.state.refreshGroup(),
    );
  }

  @override
  void dispose() {
    _groupRefresh?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.state.repo.sendMessage(widget.state.group!.id, text);
    _input.clear();
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scroll.jumpTo(_scroll.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.state.group!;
    final when = DateFormat('EEEE, h:mm a').format(g.eventAt);
    return Scaffold(
      appBar: AppBar(
        // Tapping the group name opens members, the way WhatsApp does it. There is no
        // standalone profile page anywhere in this product.
        title: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => GroupInfoScreen(widget.state)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your group', style: TextStyle(fontSize: 17)),
              Text(
                when,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Your question',
            icon: const Icon(Icons.lightbulb_outline),
            onPressed: () => showModalBottomSheet(
              context: context,
              backgroundColor: surface,
              isScrollControlled: true,
              builder: (_) => QuestionSheet(widget.state),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: widget.state.repo.watchMessages(g.id),
              builder: (context, snap) {
                final msgs = snap.data ?? const <Message>[];
                _toBottom();
                return ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _bubble(msgs[i]),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message the group',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    style: IconButton.styleFrom(backgroundColor: accent),
                    icon: const Icon(Icons.arrow_upward, color: Colors.black),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(Message m) {
    if (m.kind == MessageKind.venueVote) return VenueVoteCard(widget.state);
    if (m.kind == MessageKind.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          m.body,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: m.isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!m.isMine) ...[
            Avatar(m.avatar, size: 30),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: m.isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!m.isMine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 2),
                    child: Text(
                      m.authorName,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: m.isMine ? accent : surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    m.body,
                    style: TextStyle(
                      height: 1.35,
                      color: m.isMine ? Colors.black : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
