import 'package:flutter/material.dart';

/// Presentation-only fixtures transcribed from the pinned mock. They intentionally do not
/// leak into Repository: Explore and historical groups have no backend schema yet, while
/// the active chat continues to use the real repository contracts.
class ReferenceMember {
  const ReferenceMember(
    this.id,
    this.name,
    this.photo,
    this.interests,
    this.hometown,
    this.bio,
  );
  final String id, name, photo, hometown, bio;
  final List<String> interests;
}

const referenceMembers = <ReferenceMember>[
  ReferenceMember(
    'maya',
    'Maya',
    'assets/mock/maya.jpg',
    ['Books', 'Slow coffee'],
    'Grew up in Portland, OR',
    'Moved here last spring and still learning the bus lines. Always halfway through two novels at once.',
  ),
  ReferenceMember(
    'theo',
    'Theo',
    'assets/mock/theo.jpg',
    ['Hiking', 'Film'],
    'Grew up in Austin, TX',
    'Weekend trail person, weeknight repertory cinema person. Will happily talk about the last thing he watched.',
  ),
  ReferenceMember(
    'priya',
    'Priya',
    'assets/mock/priya.jpg',
    ['Ceramics', 'Food markets'],
    'Grew up in Chennai, India',
    'Throws mugs on Tuesdays, wanders food stalls on Saturdays. Knows where the good dosa is.',
  ),
  ReferenceMember(
    'sam',
    'Sam',
    'assets/mock/sam.jpg',
    ['Books', 'Galleries'],
    'Grew up in Chicago, IL',
    'Works at the bookshop across the street from the cafe. Quiet at first, then very much not.',
  ),
  ReferenceMember(
    'you',
    'You',
    'assets/mock/nora.jpg',
    ['Slow coffee', 'Books'],
    'Grew up in Sacramento, CA',
    'Here for low-key plans with new people and a decent cup of coffee.',
  ),
];

class ReferenceVenue {
  const ReferenceVenue(
    this.id,
    this.name,
    this.blurb,
    this.photo,
    this.votes,
    this.address,
    this.neighborhood,
    this.hours,
    this.about,
  );
  final String id, name, blurb, photo, address, neighborhood, hours, about;
  final int votes;
}

const referenceVenues = <ReferenceVenue>[
  ReferenceVenue(
    'copper',
    'The Copper Kettle',
    'Corner cafe, window seats',
    'assets/mock/venue-copper.jpg',
    3,
    '123 Mission St, San Francisco',
    'Mission - 0.4 mi away',
    'Open until 8:00 PM',
    'A small corner cafe with deep window seats and slow pour-overs. Quiet enough to hear each other, busy enough that nobody feels on display.',
  ),
  ReferenceVenue(
    'lantern',
    'Lantern & Vine',
    'Wine bar with a quiet back room',
    'assets/mock/venue-lantern.jpg',
    1,
    '48 Valencia St, San Francisco',
    'Valencia - 0.9 mi away',
    'Open until 11:30 PM',
    'Low amber light and a back room you can book for a handful of people. Short natural wine list, good bread, no music you have to talk over.',
  ),
  ReferenceVenue(
    'fern',
    'Fern & Fig',
    'Plant-filled brunch spot',
    'assets/mock/venue-fern.jpg',
    0,
    '902 Folsom St, San Francisco',
    'SoMa - 1.2 mi away',
    'Open until 3:00 PM',
    'Greenhouse-bright brunch spot full of hanging plants. Long shared tables, bottomless drip coffee, easy to linger past your plates.',
  ),
];

class ExploreTable {
  const ExploreTable(this.icon, this.interest, this.memberIds);
  final IconData icon;
  final String interest;
  final List<String> memberIds;
}

const exploreTables = [
  ExploreTable(Icons.menu_book_rounded, 'Books', [
    'maya',
    'sam',
    'theo',
    'priya',
  ]),
  ExploreTable(Icons.ramen_dining_rounded, 'Food markets', [
    'priya',
    'maya',
    'sam',
  ]),
  ExploreTable(Icons.image_rounded, 'Galleries', ['theo', 'priya']),
];

ReferenceMember memberById(String id) =>
    referenceMembers.firstWhere((m) => m.id == id);
