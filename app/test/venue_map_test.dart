import 'package:apple_maps_flutter/apple_maps_flutter.dart';
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
      MaterialApp(
        home: Scaffold(
          body: VenueMap(
            venue,
            geocode: (_) async => throw StateError('offline'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(venue.hasLocation, isFalse);
    expect(find.text('2801 Mission St'), findsOneWidget);
  });

  testWidgets('an address-only venue resolves into a real MapKit surface', (
    tester,
  ) async {
    const venue = VenueOption(
      id: 'reference-cafe',
      name: 'Reference Cafe',
      address: '123 Mission St, San Francisco',
      pitch: 'quiet enough to talk',
      categories: ['cafe'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VenueMap(
            venue,
            geocode: (_) async => const LatLng(37.79, -122.39),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppleMap), findsOneWidget);
    expect(find.text('Directions'), findsOneWidget);
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
