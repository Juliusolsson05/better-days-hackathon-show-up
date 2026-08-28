import 'dart:async';

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
  Timer? _groupRefresh;
  bool _refreshingGroup = false;

  /// Supabase creates a new realtime channel every time watchMessages is called, so the
  /// stream belongs to this State object's lifecycle rather than build(). A ListenableBuilder,
  /// keyboard animation, or viewport change can rebuild this screen many times without the
  /// user navigating; subscribing in build would leak channels and duplicate deliveries.
  ///
  /// `late` also matters: State.widget is not attached while the State constructor runs.
  /// The initializer is evaluated on first use, after Flutter has attached the immutable
  /// group for this screen's lifetime.
  late final Stream<List<Message>> _messages = widget.state.repo.watchMessages(
    widget.state.group!.id,
  );

  /// The previous message count lets [_toBottom] distinguish a conversation update from
  /// an unrelated rebuild. Without that distinction, opening the keyboard would pull a user
  /// away from an older message they intentionally scrolled up to read.
  int _lastCount = 0;
  bool _hasSpoken = false;

  @override
  void initState() {
    super.initState();
    final groupId = widget.state.group!.id;

    // Analytics records entering the actual product surface, not how often Flutter paints it.
    // Repository.track is fire-and-forget by contract so a telemetry outage cannot block chat.
    unawaited(widget.state.repo.track('chat_opened', groupId: groupId));

    // The no-show verdict only exists after peers submit attendance. Checking when chat opens
    // makes the private acknowledgement reachable after a cold start, while waiting one frame
    // avoids presenting a modal before this route owns a valid Navigator context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAckNoShow());

    if (widget.state.group!.chosenVenueId == null) {
      // Ballots are private, so an earlier voter receives no realtime row when somebody else's
      // final vote selects the winner. Poll the small shared Group projection instead of making
      // private votes observable merely to trigger UI. The final voter refreshes immediately;
      // everyone else converges within ten seconds.
      _groupRefresh = Timer.periodic(const Duration(seconds: 10), (_) {
        if (widget.state.group?.chosenVenueId != null) {
          _groupRefresh?.cancel();
          return;
        }
        unawaited(_refreshGroupProjection());
      });
    }
  }

  Future<void> _refreshGroupProjection() async {
    // Timer.periodic does not wait for its callback. Without this guard, a slow mobile request can
    // overlap the next tick and make an older response overwrite a newer chosen-venue result.
    if (_refreshingGroup) return;
    _refreshingGroup = true;
    try {
      await widget.state.refreshGroup();
      if (widget.state.group?.chosenVenueId != null) _groupRefresh?.cancel();
    } catch (_) {
      // Chat remains live while this best-effort projection refresh retries on the next tick.
    } finally {
      _refreshingGroup = false;
    }
  }

  @override
  void dispose() {
    _groupRefresh?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _maybeAckNoShow() async {
    final groupId = widget.state.group!.id;
    final prefs = await SharedPreferences.getInstance();
    final key = 'noshow_ack_$groupId';
    if (prefs.getBool(key) ?? false) return;
    if (!await widget.state.repo.wasMarkedNoShow(groupId)) return;
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const NoShowSheet(),
    );

    // Repeating an absence acknowledgement on every launch would turn a neutral product
    // response into punishment. Scope the receipt to the group because a later meetup is a
    // distinct event and may have a distinct attendance outcome.
    await prefs.setBool(key, true);
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final groupId = widget.state.group!.id;

    // Delivery failure is represented by the optimistic bubble itself. Swallowing the Future
    // here prevents the same expected network failure from also becoming an unhandled zone
    // error; the repository emits MessageStatus.failed and preserves the idempotent retry key.
    unawaited(widget.state.repo.sendMessage(groupId, text).catchError((_) {}));

    if (!_hasSpoken) {
      _hasSpoken = true;
      // Only the silent-to-speaking transition answers the funnel question. Per-message events
      // would measure prolific people instead of whether a formed group started interacting.
      unawaited(
        widget.state.repo.track('chat_first_message', groupId: groupId),
      );
    }
    _input.clear();
  }

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

  void _openGroup() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => GroupInfoScreen(widget.state)),
  );

  @override
  Widget build(BuildContext context) {
    final group = widget.state.group!;
    final when = DateFormat('EEEE, h:mm a').format(group.eventAt);
    return Scaffold(
      appBar: AppBar(
        // The title is the roster entry point, mirroring familiar group-chat products without
        // introducing the standalone profile surface the product deliberately excludes.
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
          _VenueShortcut(group: group, onTap: _openGroup),
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: _messages,
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <Message>[];
                _toBottom(messages.length);
                return ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) => _bubble(messages[index]),
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

  Widget _bubble(Message message) {
    if (message.kind == MessageKind.venueVote) {
      return VenueVoteCard(widget.state);
    }
    if (message.kind == MessageKind.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          message.body,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, height: 1.4, color: mutedInk),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: message.isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!message.isMine) ...[
            // The signed URL is intentionally separate from the durable emoji fallback.
            // Storage URLs expire; losing the fallback would turn a normal refresh boundary
            // into a broken identity marker in the conversation.
            Avatar(message.avatar, size: 30, imageUrl: message.authorPhotoUrl),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: message.isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!message.isMine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 2),
                    child: Text(
                      message.authorName,
                      style: const TextStyle(fontSize: 12, color: mutedInk),
                    ),
                  ),
                // Sending is dimmed rather than badged because it is the common, brief state.
                // Failure is the state worth interrupting for: a silent drop can feel exactly
                // like being ignored, which is especially damaging for this product's premise.
                Opacity(
                  opacity: message.status == MessageStatus.sending ? 0.55 : 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: message.isMine ? accent : surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      message.body,
                      style: const TextStyle(height: 1.35, color: ink),
                    ),
                  ),
                ),
                if (message.status == MessageStatus.failed)
                  _RetryRow(
                    message,
                    onRetry: () {
                      // retryMessage reuses clientMsgId, so a timed-out request that actually
                      // reached Postgres cannot create a duplicate when the user taps Retry.
                      unawaited(
                        widget.state.repo.retryMessage(
                          widget.state.group!.id,
                          message,
                        ),
                      );
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
        const Text('Not sent', style: TextStyle(fontSize: 12, color: negative)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onRetry,
          child: const Text(
            'Retry',
            style: TextStyle(
              fontSize: 12,
              color: inkDeep,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Keeps the meetup destination discoverable without inventing a result for an open vote.
///
/// An earlier presentation used the first option whenever chosenVenue was null. That made a
/// candidate look finalized and quietly overruled the anonymous ballot. The row keeps the PR's
/// strong visual entry point, but names a place only after Postgres records the winning option.
class _VenueShortcut extends StatelessWidget {
  const _VenueShortcut({required this.group, required this.onTap});

  final Group group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final venue = group.chosenVenue;
    final hasOptions = group.venueOptions.isNotEmpty;
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
                  child: Icon(
                    venue == null
                        ? Icons.how_to_vote_outlined
                        : Icons.map_outlined,
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
                        venue?.name ?? 'Choose where you’ll meet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        venue?.address ??
                            (hasOptions
                                ? '${group.venueOptions.length} options are ready'
                                : 'Venue options are being prepared'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  venue == null ? 'View vote' : 'View map',
                  style: const TextStyle(
                    color: inkDeep,
                    fontWeight: FontWeight.w700,
                  ),
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
