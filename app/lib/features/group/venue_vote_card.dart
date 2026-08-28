import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';

/// The vote lives inside the chat as a message, not on its own screen -- the PRD makes
/// the chat the only surface.
///
/// Voting is anonymous: the tally is shown, never who voted for what. The repository enforces
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final group = widget.state.group!;
    if (!group.venueVoteOpen && group.venueStatus != VenueStatus.chosen) {
      // Legacy venues reuse the venue presentation model, but they were selected before the
      // anonymous-ballot protocol existed. Avoid even issuing ballot reads for their synthetic id;
      // most importantly, the same state gate below prevents that id from ever being written.
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final vote = await widget.state.repo.myVenueVote(group.id);
      final tally = await widget.state.repo.venueTally(group.id);
      if (!mounted) return;
      setState(() {
        _myVote = vote;
        _tally = tally;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the vote.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _vote(String optionId) async {
    final group = widget.state.group!;
    if (_voting || !group.venueVoteOpen) return;

    final confirmedVote = _myVote;
    setState(() {
      // Selection is optimistic so a tap feels immediate, but confirmedVote is retained because
      // the repository -- not this widget -- decides whether the ballot actually committed.
      _myVote = optionId;
      _voting = true;
      _error = null;
    });
    try {
      await widget.state.repo.castVenueVote(group.id, optionId);
      // Re-read both values after a successful write. Locally incrementing a tally would leak a
      // stale count whenever another member voted concurrently.
      await _load();
      // The final ballot chooses the winner in the same database transaction as the vote. The
      // card's tally is not enough to reveal that server-owned transition, so refresh the shared
      // Group before the user opens group info or the map.
      await widget.state.refreshGroup();
    } catch (_) {
      if (mounted) {
        setState(() {
          _myVote = confirmedVote;
          _error = 'Your vote did not save. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.state.group!;
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
                  group.chosenVenue == null
                      ? 'Where should you go?'
                      : '${group.chosenVenue!.name} selected',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            group.venueVoteOpen
                ? 'Anonymous. Nobody sees who picked what.'
                : 'The result is shared. Individual ballots stay private.',
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
          else if (group.venueOptions.isEmpty)
            const Text(
              'Grounded venue options are still being prepared.',
              style: TextStyle(color: bodyInk),
            )
          else if (_error != null && _tally.isEmpty)
            TextButton(onPressed: _load, child: Text('${_error!} Retry'))
          else ...[
            for (final venue in group.venueOptions)
              _option(venue, _tally[venue.id] ?? 0),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _option(VenueOption venue, int votes) {
    final mine = _myVote == venue.id;
    final finalized = !widget.state.group!.venueVoteOpen;
    final selected = widget.state.group!.chosenVenue?.id == venue.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(inputRadius),
        onTap: _voting || finalized ? null : () => _vote(venue.id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? accentPale : bg,
            borderRadius: BorderRadius.circular(inputRadius),
            border: Border.all(
              color: mine || selected ? inkDeep : Colors.transparent,
              width: mine || selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      venue.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (selected) ...[
                    const Icon(Icons.check_circle, size: 17, color: positive),
                    const SizedBox(width: 7),
                  ],
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
                venue.pitch,
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
