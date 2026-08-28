import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showup/features/group/venue_map.dart';
import 'package:showup/models/models.dart';

void main() {
  // The map itself is a UiKitView and does not render off-device, so what is worth
  // protecting here is the degradation: a venue with no coordinates must still show the
  // group where it is going. Losing this silently turns group info into a dead end for
  // anyone whose venue came from hand-curated or partially-migrated data.
  testWidgets('a venue without coordinates falls back to its address', (
    tester,
  ) async {
    const venue = VenueOption(
      id: 'v9',
      name: 'Somewhere',
      address: '2801 Mission St',
      pitch: 'quiet enough to talk',
      categories: ['bar'],
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VenueMap(venue))),
    );

    expect(venue.hasLocation, isFalse);
    expect(find.text('2801 Mission St'), findsOneWidget);
  });

  test('hasLocation requires both coordinates, not either', () {
    const both = VenueOption(
      id: 'a',
      name: 'n',
      address: 'a',
      pitch: 'p',
      categories: [],
      lat: 37.75,
      lng: -122.41,
    );
    // A half-populated venue would otherwise pass hasLocation and then crash on the
    // non-null assertion when building the LatLng.
    const latOnly = VenueOption(
      id: 'b',
      name: 'n',
      address: 'a',
      pitch: 'p',
      categories: [],
      lat: 37.75,
    );

    expect(both.hasLocation, isTrue);
    expect(latOnly.hasLocation, isFalse);
  });
}
