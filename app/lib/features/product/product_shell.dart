import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../group/venue_map.dart';
import 'reference_data.dart';

/// The mock's two-tab shell is presentation state, not a new domain phase. Keeping it here
/// avoids contorting the time-based backend lifecycle merely to represent tab selection.
class ProductShell extends StatefulWidget {
  const ProductShell(this.state, {super.key});
  final AppState state;

  @override
  State<ProductShell> createState() => _ProductShellState();
}

class _ProductShellState extends State<ProductShell> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: IndexedStack(
        index: _tab,
        children: [
          ExploreView(onJoined: () => setState(() => _tab = 1)),
          MyGroupsView(state: widget.state),
        ],
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: bg,
          border: Border(top: BorderSide(color: line)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            _TabButton('Explore', _tab == 0, () => setState(() => _tab = 0)),
            const SizedBox(width: 8),
            _TabButton('My groups', _tab == 1, () => setState(() => _tab = 1)),
          ],
        ),
      ),
    ),
  );
}

class _TabButton extends StatelessWidget {
  const _TabButton(this.label, this.active, this.onTap);
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: active ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? ink : mutedInk,
          ),
        ),
      ),
    ),
  );
}

class ExploreView extends StatelessWidget {
  const ExploreView({super.key, required this.onJoined});
  final VoidCallback onJoined;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: _PageTitle('EXPLORE', 'Tables looking for one more'),
      ),
      Expanded(
        child: PageView.builder(
          controller: PageController(viewportFraction: .78),
          padEnds: true,
          itemCount: exploreTables.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 32),
            child: _ExploreCard(exploreTables[index], onJoined),
          ),
        ),
      ),
    ],
  );
}

class _ExploreCard extends StatelessWidget {
  const _ExploreCard(this.table, this.onJoined);
  final ExploreTable table;
  final VoidCallback onJoined;

  @override
  Widget build(BuildContext context) {
    final members = table.memberIds.map(memberById).toList();
    final left = 6 - members.length;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x18000000),
            blurRadius: 28,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(table.icon, size: 40, color: ink),
          const SizedBox(height: 12),
          Text(table.interest, style: displayStyle(26)),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
          const _Eyebrow('MEMBERS'),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              physics: const ClampingScrollPhysics(),
              children: [
                for (final member in members) _MemberRow(member),
                if (left > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: line),
                          ),
                          child: Text(
                            '+$left',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '$left ${left == 1 ? 'spot' : 'spots'} left',
                          style: const TextStyle(
                            fontSize: 14,
                            color: mutedInk,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          FilledButton(onPressed: onJoined, child: const Text('Join group')),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow(this.member);
  final ReferenceMember member;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        _Photo(member.photo, 40),
        const SizedBox(width: 12),
        Text(
          member.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class MyGroupsView extends StatelessWidget {
  const MyGroupsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
    children: [
      const _PageTitle('MY GROUPS', 'Your tables'),
      const SizedBox(height: 20),
      Container(
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            _GroupRow(
              Icons.local_cafe_rounded,
              'Books + slow coffee',
              'Sunday - 4:30 PM',
              2,
              () => _open(context, const GroupHubScreen()),
            ),
            const Divider(),
            _GroupRow(
              Icons.hiking_rounded,
              'Hiking',
              'Sat, Sep 5 - 8:00 AM',
              0,
              () => _open(context, const GroupHubScreen(locked: true)),
            ),
            const Divider(),
            _GroupRow(
              Icons.casino_rounded,
              'Board games',
              'Today - 6:30 PM',
              0,
              () => _open(context, const GroupHubScreen(dayOf: true)),
            ),
          ],
        ),
      ),
    ],
  );

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

class _GroupRow extends StatelessWidget {
  const _GroupRow(this.icon, this.title, this.when, this.unread, this.onTap);
  final IconData icon;
  final String title, when;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: displayStyle(17),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const _AvatarStack(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        when,
                        style: const TextStyle(fontSize: 12, color: mutedInk),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (unread > 0)
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$unread',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 20, color: mutedInk),
        ],
      ),
    ),
  );
}

class GroupHubScreen extends StatefulWidget {
  const GroupHubScreen({super.key, this.locked = false, this.dayOf = false});
  final bool locked, dayOf;
  @override
  State<GroupHubScreen> createState() => _GroupHubScreenState();
}

class _GroupHubScreenState extends State<GroupHubScreen> {
  String? voted;

  @override
  Widget build(BuildContext context) {
    final icon = widget.dayOf
        ? Icons.casino_rounded
        : widget.locked
        ? Icons.hiking_rounded
        : Icons.local_cafe_rounded;
    final interest = widget.dayOf
        ? 'Board games'
        : widget.locked
        ? 'Hiking'
        : 'Books + slow coffee';
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BackLabel(label: 'My groups'),
                  const SizedBox(height: 20),
                  Icon(icon, size: 40, color: ink),
                  const SizedBox(height: 8),
                  Text(interest, style: displayStyle(28)),
                  const SizedBox(height: 4),
                  Text(
                    widget.dayOf
                        ? 'Today - 6:30 PM - 3 solo'
                        : widget.locked
                        ? 'Sat, Sep 5 - 8:00 AM - 4 solo'
                        : 'Sunday - 4:30 PM - 5 solo',
                    style: const TextStyle(fontSize: 13, color: mutedInk),
                  ),
                  const SizedBox(height: 32),
                  Text("What's the conversation", style: displayStyle(18)),
                  const SizedBox(height: 12),
                  _ConversationPreview(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            GroupChatMockScreen(dayOf: widget.dayOf),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                widget.locked || widget.dayOf
                    ? 'When and where'
                    : 'Vote on when & where',
                style: displayStyle(18),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 245,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: widget.locked || widget.dayOf
                    ? 1
                    : referenceVenues.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final venue = widget.dayOf
                      ? referenceVenues[1]
                      : referenceVenues[index];
                  return _VenueCard(
                    venue,
                    selected: voted == venue.id,
                    canVote: !widget.locked && !widget.dayOf,
                    onVote: () => setState(() => voted = venue.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 30),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Meet your members', style: displayStyle(18)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 210,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: referenceMembers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _MemberCard(referenceMembers[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _PreviewLine(
            referenceMembers[2],
            'copper kettle feels right, that little window seat!',
          ),
          const SizedBox(height: 12),
          _PreviewLine(
            referenceMembers[3],
            "I'll come straight from the bookshop across the street.",
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Open chat →',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine(this.member, this.body);
  final ReferenceMember member;
  final String body;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      _Photo(member.photo, 28),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              member.name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            Text(
              body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: mutedInk),
            ),
          ],
        ),
      ),
    ],
  );
}

class _VenueCard extends StatelessWidget {
  const _VenueCard(
    this.venue, {
    required this.selected,
    required this.canVote,
    required this.onVote,
  });
  final ReferenceVenue venue;
  final bool selected, canVote;
  final VoidCallback onVote;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 272,
    child: Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => VenueDetailScreen(venue)),
            ),
            child: Image.asset(
              venue.photo,
              width: double.infinity,
              height: 128,
              fit: BoxFit.cover,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(venue.name, style: displayStyle(16)),
                const SizedBox(height: 4),
                Text(
                  'Sunday - 4:30 PM - ${venue.votes} votes',
                  style: const TextStyle(fontSize: 12, color: mutedInk),
                ),
                if (canVote) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 34,
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onVote,
                      child: Text(selected ? 'Voted' : 'Vote'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MemberCard extends StatelessWidget {
  const _MemberCard(this.member);
  final ReferenceMember member;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MemberDetailScreen(member)),
    ),
    child: SizedBox(
      width: 158,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(member.photo, fit: BoxFit.cover),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xC0000000)],
                  stops: [.55, 1],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Text(
                member.id == 'you' ? 'You (you)' : member.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MemberDetailScreen extends StatelessWidget {
  const MemberDetailScreen(this.member, {super.key});
  final ReferenceMember member;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const _DetailHeader('Member'),
          Expanded(
            child: ListView(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Image.asset(member.photo, fit: BoxFit.cover),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.id == 'you' ? 'You (you)' : member.name,
                        style: displayStyle(24),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        member.hometown,
                        style: const TextStyle(fontSize: 13, color: mutedInk),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        member.bio,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.55,
                          color: mutedInk,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        children: member.interests
                            .map((i) => Chip(label: Text(i)))
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class VenueDetailScreen extends StatefulWidget {
  const VenueDetailScreen(this.venue, {super.key});
  final ReferenceVenue venue;
  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  var voted = false;
  @override
  Widget build(BuildContext context) {
    final v = widget.venue;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _DetailHeader('Venue'),
            Expanded(
              child: ListView(
                children: [
                  Image.asset(
                    v.photo,
                    height: 192,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.name, style: displayStyle(24)),
                        const SizedBox(height: 4),
                        Text(
                          v.blurb,
                          style: const TextStyle(fontSize: 13, color: mutedInk),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: surface,
                            border: Border.all(color: line),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(v.address),
                              const SizedBox(height: 8),
                              Text(
                                v.neighborhood,
                                style: const TextStyle(color: mutedInk),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                v.hours,
                                style: const TextStyle(color: mutedInk),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Sunday - 4:30 PM',
                                style: TextStyle(color: mutedInk),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          v.about,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.55,
                            color: mutedInk,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // The web mock stops at venue content, but the product requirement includes a
                        // real locator. Keep MapKit inside the identical content rhythm so adding actual
                        // utility does not turn the native screen into a different composition.
                        VenueMap(
                          VenueOption(
                            id: v.id,
                            name: v.name,
                            address: v.address,
                            pitch: v.blurb,
                            categories: const ['meetup'],
                            lat: 37.7599,
                            lng: -122.4148,
                          ),
                          height: 176,
                        ),
                        const SizedBox(height: 16),
                        Chip(label: Text('${v.votes} votes')),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => setState(() => voted = true),
                          child: Text(voted ? 'Voted' : 'Vote for this spot'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GroupChatMockScreen extends StatefulWidget {
  const GroupChatMockScreen({super.key, this.dayOf = false});
  final bool dayOf;
  @override
  State<GroupChatMockScreen> createState() => _GroupChatMockScreenState();
}

class _GroupChatMockScreenState extends State<GroupChatMockScreen> {
  final controller = TextEditingController();
  final sent = <String>[];
  String? vote;
  var revealed = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          _ChatHeader(onInfo: () => _showInfo(context)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const _SystemMessage(
                  "YOU'RE IN - YOUR SEAT IS SAVED",
                  'Everyone here came alone. Say hi below when you are ready.',
                ),
                const SizedBox(height: 16),
                _ChatBubble(
                  referenceMembers[0],
                  'hey! so nervous but also excited. first one of these for me.',
                ),
                const SizedBox(height: 16),
                _ChatVenueVote(
                  vote: vote,
                  onVote: (id) => setState(() => vote = id),
                ),
                const SizedBox(height: 16),
                _ChatBubble(
                  referenceMembers[2],
                  'copper kettle feels right, that little window seat!',
                ),
                const SizedBox(height: 16),
                _ChatBubble(
                  referenceMembers[3],
                  "I'll come straight from the bookshop across the street. See you all Sunday.",
                ),
                if (widget.dayOf) ...[
                  const SizedBox(height: 16),
                  _QuestionCard(
                    revealed: revealed,
                    onReveal: () => setState(() => revealed = true),
                  ),
                ],
                for (final text in sent) ...[
                  const SizedBox(height: 16),
                  _MineBubble(text),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              decoration: BoxDecoration(
                color: surface,
                border: Border.all(color: line),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      decoration: const InputDecoration.collapsed(
                        hintText: 'Message the group…',
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      setState(() {
                        sent.add(text);
                        controller.clear();
                      });
                    },
                    icon: const Icon(Icons.arrow_upward),
                    style: IconButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
  void _showInfo(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _GroupInfoSheet(),
  );
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onInfo});
  final VoidCallback onInfo;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.chevron_left),
        ),
        GestureDetector(
          onTap: onInfo,
          child: Row(
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/mock/group-cover.jpg',
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('The Sunday Table', style: displayStyle(17)),
                  const SizedBox(height: 3),
                  const Text(
                    'Books + slow coffee - Sunday',
                    style: TextStyle(fontSize: 11, color: mutedInk),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          onPressed: onInfo,
          icon: const Icon(Icons.info_outline),
          style: IconButton.styleFrom(side: const BorderSide(color: line)),
        ),
      ],
    ),
  );
}

class _SystemMessage extends StatelessWidget {
  const _SystemMessage(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.6,
          color: mutedInk,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        body,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: mutedInk),
      ),
    ],
  );
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble(this.member, this.body);
  final ReferenceMember member;
  final String body;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      _Photo(member.photo, 32),
      const SizedBox(width: 8),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              member.name,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mutedInk,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
              ),
              child: Text(
                body,
                style: const TextStyle(fontSize: 14, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _MineBubble extends StatelessWidget {
  const _MineBubble(this.body);
  final String body;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(18),
          topRight: Radius.circular(6),
          bottomLeft: Radius.circular(18),
          bottomRight: Radius.circular(18),
        ),
      ),
      child: Text(body),
    ),
  );
}

class _ChatVenueVote extends StatelessWidget {
  const _ChatVenueVote({required this.vote, required this.onVote});
  final String? vote;
  final ValueChanged<String> onVote;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: surface,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pick the table', style: displayStyle(18)),
        const SizedBox(height: 4),
        const Text(
          'Nobody sees who voted for what.',
          style: TextStyle(fontSize: 12, color: mutedInk),
        ),
        const SizedBox(height: 12),
        for (final venue in referenceVenues)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => onVote(venue.id),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: vote == venue.id ? accentPale : bg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        venue.photo,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            venue.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            venue.blurb,
                            style: const TextStyle(
                              fontSize: 11,
                              color: mutedInk,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      vote == venue.id ? 'Voted' : '${venue.votes}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({required this.revealed, required this.onReveal});
  final bool revealed;
  final VoidCallback onReveal;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ink,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'YOUR PRIVATE QUESTION',
          style: TextStyle(
            color: accent,
            fontSize: 11,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        if (!revealed) ...[
          const Text(
            'One question, one person to ask it to. Nobody else sees it.',
            style: TextStyle(color: Color(0xBFFFFFFF), fontSize: 13),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onReveal,
            child: const Text('Reveal my question'),
          ),
        ] else ...[
          Row(
            children: [
              const _Photo('assets/mock/theo.jpg', 36),
              const SizedBox(width: 10),
              Text(
                'Ask this to\nTheo',
                style: displayStyle(15).copyWith(color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '“What is something small that makes your ordinary day feel a little better?”',
            style: displayStyle(16).copyWith(color: Colors.white),
          ),
        ],
      ],
    ),
  );
}

class _GroupInfoSheet extends StatelessWidget {
  const _GroupInfoSheet();
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: line,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('The Sunday Table', style: displayStyle(18)),
                  const Text(
                    'Books + slow coffee - Sunday',
                    style: TextStyle(fontSize: 11, color: mutedInk),
                  ),
                ],
              ),
              const Chip(label: Text('5 solo')),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final m in referenceMembers)
                Column(
                  children: [
                    _Photo(m.photo, 50),
                    const SizedBox(height: 4),
                    Text(
                      m.name,
                      style: const TextStyle(fontSize: 10, color: mutedInk),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'Everyone here signed up alone. Groups reshuffle after each meetup.',
            style: TextStyle(fontSize: 12, color: mutedInk),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accentPale,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mutual contacts',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6),
                Text(
                  'Numbers appear here only when you and someone else both chose to share. No one is told either way.',
                  style: TextStyle(fontSize: 12, color: mutedInk),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 10, 16, 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.chevron_left),
        ),
        Text(title, style: displayStyle(18)),
      ],
    ),
  );
}

class _BackLabel extends StatelessWidget {
  const _BackLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => Navigator.pop(context),
    child: Text(
      '← $label',
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: mutedInk,
      ),
    ),
  );
}

class _PageTitle extends StatelessWidget {
  const _PageTitle(this.eyebrow, this.title);
  final String eyebrow, title;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Eyebrow(eyebrow),
      const SizedBox(height: 4),
      Text(title, style: displayStyle(26)),
    ],
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.8,
      color: mutedInk,
    ),
  );
}

class _Photo extends StatelessWidget {
  const _Photo(this.path, this.size);
  final String path;
  final double size;
  @override
  Widget build(BuildContext context) => ClipOval(
    child: Image.asset(path, width: size, height: size, fit: BoxFit.cover),
  );
}

class _AvatarStack extends StatelessWidget {
  const _AvatarStack();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    height: 26,
    child: Stack(
      children: [
        for (var i = 0; i < 3; i++)
          Positioned(
            left: i * 21,
            child: Container(
              padding: const EdgeInsets.all(1),
              decoration: const BoxDecoration(
                color: surface,
                shape: BoxShape.circle,
              ),
              child: _Photo(referenceMembers[i].photo, 24),
            ),
          ),
      ],
    ),
  );
}

TextStyle displayStyle(double size) => TextStyle(
  fontFamily: 'Georgia',
  color: ink,
  fontSize: size,
  height: 1.12,
  fontWeight: FontWeight.w500,
  letterSpacing: -.25,
);
