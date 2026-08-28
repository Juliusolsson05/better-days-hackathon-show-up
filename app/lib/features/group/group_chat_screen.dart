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

  /// Subscribed ONCE, here, rather than in build().
  ///
  /// build() runs far more often than it looks: this screen sits inside a
  /// ListenableBuilder on AppState in app.dart, so every notifyListeners() rebuilds it,
  /// and the keyboard animating up rebuilds it once per frame. Calling
  /// repo.watchMessages() from build() is invisible against MockRepository, which hands
  /// back the same broadcast controller every time -- but SupabaseRepository opens a NEW
  /// realtime channel per call, so the chat quietly accumulated a channel per rebuild and
  /// held them for the life of the screen. `late final` so the subscription starts on
  /// first build rather than before the group is readable.
  ///
  /// The group id is captured once, which is correct because a group is immutable for the
  /// life of this screen -- reshuffling produces a new group, and with it a new screen.
  late final Stream<List<Message>> _messages = widget.state.repo.watchMessages(
    widget.state.group!.id,
  );

  /// How many messages the last build rendered, so a rebuild that changed nothing does not
  /// yank a reader back down. See [_toBottom].
  int _lastCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// True once this user has said something in this group, so the funnel event fires
  /// once per session rather than once per message.
  bool _hasSpoken = false;

  @override
  void initState() {
    super.initState();
    // Fired here rather than in build(), which runs on every keyboard frame.
    widget.state.repo.track('chat_opened', groupId: widget.state.group!.id);
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final groupId = widget.state.group!.id;

    // The failure is already visible -- sendMessage marks the optimistic bubble failed and
    // re-emits, so the user sees it and can retry. Swallowing here stops the same failure
    // ALSO surfacing as an unhandled async error, which in release goes to Sentry as noise
    // and in debug throws a red screen over a chat that is behaving correctly.
    unawaited(widget.state.repo.sendMessage(groupId, text).catchError((_) {}));

    if (!_hasSpoken) {
      _hasSpoken = true;
      // The funnel question this answers: does a group that talks before the meetup show
      // up more than one that does not? Only the silent -> speaking transition is
      // interesting, so this is not emitted per message.
      widget.state.repo.track('chat_first_message', groupId: groupId);
    }
    _input.clear();
  }

  /// Follow the conversation, but never fight the reader.
  ///
  /// This used to jump on every build, which meant scrolling up to re-read what someone
  /// said was undone by the next keyboard frame. Two guards fix that: only move when a
  /// message actually arrived, and only when the reader was already near the bottom --
  /// i.e. reading live rather than looking back. Someone scrolled up stays scrolled up.
  void _toBottom(int count) {
    final grew = count > _lastCount;
    _lastCount = count;
    if (!grew || !_scroll.hasClients) return;
    const nearBottom = 120.0;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels > nearBottom &&
        position.pixels > 0) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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
              stream: _messages,
              builder: (context, snap) {
                final msgs = snap.data ?? const <Message>[];
                _toBottom(msgs.length);
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
            Avatar(m.avatar, size: 30, imageUrl: m.authorPhotoUrl),
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
                // A message in flight is dimmed rather than badged: the send almost always
                // succeeds, and a spinner on every bubble for 300ms is more noise than
                // information. Failure is the case worth interrupting for.
                Opacity(
                  opacity: m.status == MessageStatus.sending ? 0.55 : 1,
                  child: Container(
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
                ),
                if (m.status == MessageStatus.failed)
                  _RetryRow(
                    m,
                    onRetry: () {
                      widget.state.repo.retryMessage(widget.state.group!.id, m);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown under a message that did not send.
///
/// The product reason this is not a silent drop: this is a loneliness app, and the worst
/// version of a failed send is one where a user believes they reached out and nobody
/// answered, when in fact nothing was ever delivered. Being told beats being ghosted by
/// your own phone.
class _RetryRow extends StatelessWidget {
  final Message message;
  final VoidCallback onRetry;
  const _RetryRow(this.message, {required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, right: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          'Not sent',
          style: TextStyle(
            fontSize: 12,
            color: Colors.redAccent.withValues(alpha: 0.9),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onRetry,
          child: const Text(
            'Retry',
            style: TextStyle(
              fontSize: 12,
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}
