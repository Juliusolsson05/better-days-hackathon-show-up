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
    setState(() => _myVote = optionId);
    await widget.state.repo.castVenueVote(widget.state.group!.id, optionId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.state.group!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: accentPale,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.how_to_vote_outlined,
                  size: 19,
                  color: inkDeep,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Where should you go?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Anonymous. Nobody sees who picked what.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_loading)
            for (var i = 0; i < 2; i++)
              Container(
                height: 72,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(inputRadius),
                ),
              )
          else
            for (final v in g.venueOptions) _option(v, _tally[v.id] ?? 0),
        ],
      ),
    );
  }

  Widget _option(VenueOption v, int votes) {
    final mine = _myVote == v.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _vote(v.id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? accentPale : bg,
            borderRadius: BorderRadius.circular(inputRadius),
            border: Border.all(
              color: mine ? inkDeep : Colors.transparent,
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
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: mine ? accent : surface,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$votes',
                      style: const TextStyle(
                        color: ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                v.pitch,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: bodyInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
