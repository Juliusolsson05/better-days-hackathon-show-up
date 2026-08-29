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
import 'safety_actions.dart';
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
  /// This is mutable only for an explicit recovery attempt. An errored Supabase realtime stream
  /// does not heal merely because StreamBuilder rebuilds; Retry must ask the repository for a new
  /// channel. Ordinary builds never replace it, preserving the one-subscription invariant.
  late Stream<List<Message>> _messages;

  /// The previous message count lets [_toBottom] distinguish a conversation update from
  /// an unrelated rebuild. Without that distinction, opening the keyboard would pull a user
  /// away from an older message they intentionally scrolled up to read.
  int _lastCount = 0;
  bool _hasSpoken = false;
  RsvpStatus? _rsvp;
  bool _savingRsvp = false;
  String? _rsvpError;

  @override
  void initState() {
    super.initState();
    final groupId = widget.state.group!.id;
    _messages = widget.state.repo.watchMessages(groupId);
    unawaited(_loadRsvp(groupId));

    // Analytics records entering the actual product surface, not how often Flutter paints it.
    // Repository.track is fire-and-forget by contract so a telemetry outage cannot block chat.
    unawaited(widget.state.repo.track('chat_opened', groupId: groupId));

    // The no-show verdict only exists after peers submit attendance. Checking when chat opens
    // makes the private acknowledgement reachable after a cold start, while waiting one frame
    // avoids presenting a modal before this route owns a valid Navigator context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The acknowledgement is a private, best-effort read after chat has already opened. A
      // transient RPC or preferences failure must not escape the post-frame callback as an
      // unhandled asynchronous error; reopening the room naturally retries the durable verdict.
      unawaited(_maybeAckNoShow().catchError((_) {}));
    });

    if (widget.state.group!.venueNeedsRefresh) {
      // Ballots are private, so an earlier voter receives no realtime row when somebody else's
      // final vote selects the winner. Poll the small shared Group projection instead of making
      // private votes observable merely to trigger UI. The final voter refreshes immediately;
      // everyone else converges within ten seconds.
      _groupRefresh = Timer.periodic(const Duration(seconds: 10), (_) {
        if (widget.state.group?.venueNeedsRefresh != true) {
          _groupRefresh?.cancel();
          return;
        }
        unawaited(_refreshGroupProjection());
      });
    }
  }

  Future<void> _loadRsvp(String groupId) async {
    try {
      final status = await widget.state.repo.myRsvp(groupId);
      if (mounted) setState(() => _rsvp = status);
    } catch (_) {
      if (mounted) {
        setState(() => _rsvpError = 'RSVP unavailable. Tap to retry.');
      }
    }
  }

  Future<void> _setRsvp(RsvpStatus status) async {
    setState(() {
      _savingRsvp = true;
      _rsvpError = null;
    });
    try {
      await widget.state.repo.setRsvp(widget.state.group!.id, status);
      if (mounted) setState(() => _rsvp = status);
    } catch (_) {
      if (mounted) setState(() => _rsvpError = 'That did not save. Try again.');
    } finally {
      if (mounted) setState(() => _savingRsvp = false);
    }
  }

  Future<void> _refreshGroupProjection() async {
    // Timer.periodic does not wait for its callback. Without this guard, a slow mobile request can
    // overlap the next tick and make an older response overwrite a newer chosen-venue result.
    if (_refreshingGroup) return;
    _refreshingGroup = true;
    try {
      await widget.state.refreshGroup();
      if (widget.state.group?.venueNeedsRefresh != true) {
        _groupRefresh?.cancel();
      }
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

    final shouldTrackFirstMessage = !_hasSpoken;
    if (shouldTrackFirstMessage) _hasSpoken = true;
    unawaited(() async {
      try {
        // The database write is the product fact; analytics may observe it only after it commits.
        // Emitting first-message before sendMessage completed counted failed optimistic bubbles as
        // conversation and could permanently suppress the event when the later retry succeeded.
        await widget.state.repo.sendMessage(groupId, text);
        if (shouldTrackFirstMessage) {
          await widget.state.repo.track('chat_first_message', groupId: groupId);
        }
      } catch (_) {
        // The repository already changes the optimistic bubble to failed and keeps its idempotency
        // key. Restore only this local funnel guard so a later successful send can be observed.
        if (shouldTrackFirstMessage) _hasSpoken = false;
      }
    }());
    _input.clear();
  }

  void _retryMessages() {
    // StreamBuilder cancels its subscription when the stream identity changes. Constructing the
    // replacement only from this button avoids both dead-room retries that reuse a terminated
    // channel and automatic reconnect loops that could hammer Supabase during an outage.
    setState(() {
      _messages = widget.state.repo.watchMessages(widget.state.group!.id);
    });
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
          _RsvpCard(
            status: _rsvp,
            busy: _savingRsvp,
            error: _rsvpError,
            onChanged: _setRsvp,
            onRetry: () => _loadRsvp(group.id),
          ),
          _VenueShortcut(group: group, onTap: _openGroup),
          Expanded(
            child: StreamBuilder<List<Message>>(
              // StreamBuilder deliberately retains the previous snapshot when only `stream`
              // changes. That is helpful for ordinary refreshes but would leave the old error
              // banner visible until Supabase emits its first replacement snapshot. Keying the
              // explicit retry stream starts recovery in a clean waiting state immediately.
              key: ObjectKey(_messages),
              stream: _messages,
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <Message>[];
                _toBottom(messages.length);
                return Column(
                  children: [
                    if (snapshot.hasError)
                      _MessageStreamFailure(onRetry: _retryMessages),
                    Expanded(
                      child: ListView.builder(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                        itemCount: messages.length,
                        itemBuilder: (context, index) =>
                            _bubble(messages[index]),
                      ),
                    ),
                  ],
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
                GestureDetector(
                  onLongPress: message.isMine
                      ? null
                      : () => showMemberSafetyActions(
                          context,
                          widget.state,
                          memberId: message.authorId,
                          memberName: message.authorName,
                        ),
                  child: Opacity(
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

class _MessageStreamFailure extends StatelessWidget {
  const _MessageStreamFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(inputRadius),
      border: Border.all(color: negative),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Messages lost connection.',
            style: TextStyle(color: bodyInk, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

class _RsvpCard extends StatelessWidget {
  const _RsvpCard({
    required this.status,
    required this.busy,
    required this.error,
    required this.onChanged,
    required this.onRetry,
  });

  final RsvpStatus? status;
  final bool busy;
  final String? error;
  final ValueChanged<RsvpStatus> onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accentPale,
        borderRadius: BorderRadius.circular(cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch (status) {
            RsvpStatus.confirmed => "You're in — we'll remind you.",
            RsvpStatus.declined => "You can't make this one.",
            RsvpStatus.pending => 'Can you make it?',
            null => 'Loading your RSVP…',
          }, style: const TextStyle(fontWeight: FontWeight.w700)),
          if (error != null) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: busy ? null : onRetry,
              child: Text(error!, style: const TextStyle(color: negative)),
            ),
          ],
          if (status != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: busy || status == RsvpStatus.confirmed
                        ? null
                        : () => onChanged(RsvpStatus.confirmed),
                    child: const Text("I'm in"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy || status == RsvpStatus.declined
                        ? null
                        : () => onChanged(RsvpStatus.declined),
                    child: const Text("Can't make it"),
                  ),
                ),
              ],
            ),
          ],
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
