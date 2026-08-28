import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';

/// The vote lives inside the chat as a message, not on its own screen -- the PRD makes
/// the chat the only surface.
///
/// Voting is anonymous: the tally is shown, never who voted for what. The mock enforces
/// that by only ever returning counts, which is the same shape venue_tally() returns.
class VenueVoteCard extends StatefulWidget {
  final AppState state;
  const VenueVoteCard(this.state, {super.key});
  @override
  State<VenueVoteCard> createState() => _VenueVoteCardState();
}

class _VenueVoteCardState extends State<VenueVoteCard> {
  String? _myVote;
  Map<String, int> _tally = const {};
  bool _loading = true;
  bool _voting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final g = widget.state.group!;
    final vote = await widget.state.repo.myVenueVote(g.id);
    final tally = await widget.state.repo.venueTally(g.id);
    if (mounted) {
      setState(() {
        _myVote = vote;
        _tally = tally;
        _loading = false;
      });
    }
  }

  Future<void> _vote(String optionId) async {
    if (_voting) return;
    final previous = _myVote;
    setState(() {
      _myVote = optionId;
      _voting = true;
    });
    try {
      await widget.state.repo.castVenueVote(widget.state.group!.id, optionId);
      await _load();
      // The final ballot may have created venue_selections in the same transaction. Refresh
      // the shared Group so tapping the header immediately shows the actual result and map.
      await widget.state.refreshGroup();
    } catch (err) {
      if (!mounted) return;
      setState(() => _myVote = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save your vote: $err')));
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.state.group!;
    final total = _tally.values.fold<int>(0, (a, b) => a + b);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.how_to_vote_outlined, size: 18, color: accent),
              const SizedBox(width: 8),
              const Text(
                'Where should you go?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Anonymous — nobody sees who picked what.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            )
          else
            for (final v in g.venueOptions)
              _option(v, _tally[v.id] ?? 0, total),
        ],
      ),
    );
  }

  Widget _option(VenueOption v, int votes, int total) {
    final mine = _myVote == v.id;
    final share = total == 0 ? 0.0 : votes / total;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _voting ? null : () => _vote(v.id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: mine ? accent : Colors.white.withValues(alpha: 0.12),
              width: mine ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      v.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '$votes',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                v.pitch,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: share,
                  minHeight: 4,
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  valueColor: AlwaysStoppedAnimation(
                    mine ? accent : Colors.white24,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
