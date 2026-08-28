import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import 'group_info_screen.dart';
import 'no_show_sheet.dart';
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

  @override
  void initState() {
    super.initState();
    // The flaking acknowledgement is a "come back later" surface: it can only be known
    // once the rest of the group has voted, which is after the meetup, so entering the
    // chat is where we check for it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAckNoShow());
  }

  Future<void> _maybeAckNoShow() async {
    final gid = widget.state.group!.id;
    final prefs = await SharedPreferences.getInstance();
    final key = 'noshow_ack_$gid';
    if (prefs.getBool(key) ?? false) return;
    if (!await widget.state.repo.wasMarkedNoShow(gid)) return;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      isScrollControlled: true,
      builder: (_) => const NoShowSheet(),
    );
    // Shown once per group -- an absence acknowledged every launch would be its own
    // small punishment, which is the opposite of the point.
    await prefs.setBool(key, true);
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

  void _openGroup() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => GroupInfoScreen(widget.state)),
  );

  @override
  Widget build(BuildContext context) {
    final g = widget.state.group!;
    final when = DateFormat('EEEE, h:mm a').format(g.eventAt);
    return Scaffold(
      appBar: AppBar(
        // Tapping the group name opens members, the way WhatsApp does it. There is no
        // standalone profile page anywhere in this product.
        title: InkWell(
          onTap: _openGroup,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your group', style: TextStyle(fontSize: 17)),
              Text(when, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Your question',
            icon: const Icon(Icons.lightbulb_outline),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => QuestionSheet(widget.state),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _VenueShortcut(group: g, onTap: _openGroup),
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
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _bubble(msgs[i]),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              color: surface,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                    style: IconButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: ink,
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.arrow_upward),
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
          style: const TextStyle(fontSize: 13, height: 1.4, color: mutedInk),
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
                      style: const TextStyle(fontSize: 12, color: mutedInk),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: m.isMine ? accent : surface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    m.body,
                    style: const TextStyle(height: 1.35, color: ink),
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

/// The map used to be discoverable only by knowing that the chat title was tappable.
/// That convention is familiar after someone has used WhatsApp, but it is a bad demo
/// dependency and hides the most concrete part of showing up. This row names the venue,
/// names the action, and still keeps the full map in group info where it has room.
class _VenueShortcut extends StatelessWidget {
  const _VenueShortcut({required this.group, required this.onTap});

  final Group group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final venue = group.chosenVenue ?? group.venueOptions.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(cardRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(cardRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: accentPale,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.map_outlined,
                    color: inkDeep,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        venue.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        venue.address,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'View map',
                  style: TextStyle(color: inkDeep, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: inkDeep),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
