import 'package:flutter_test/flutter_test.dart';
import 'package:showup/models/models.dart';

void main() {
  test('a legacy venue is a display destination, never a writable ballot', () {
    final group = Group(
      id: 'legacy-group',
      eventAt: DateTime(2026),
      members: const [],
      venueOptions: const [
        VenueOption(
          id: 'legacy:legacy-group',
          name: 'Kinship',
          address: '2801 Mission St',
          pitch: '',
          categories: [],
        ),
      ],
      venueStatus: VenueStatus.legacy,
      activity: 'Coffee',
    );

    expect(group.chosenVenue?.name, 'Kinship');
    expect(group.venueVoteOpen, isFalse);
    expect(group.venueNeedsRefresh, isFalse);
  });

  test('a temporarily stale chosen venue id does not crash group rendering', () {
    final group = Group(
      id: 'group',
      eventAt: DateTime(2026),
      members: const [],
      venueOptions: const [],
      activity: 'Coffee',
      chosenVenueId: 'option-not-in-this-projection-yet',
    );

    // Postgres can expose the finalized group row before a stale client has refreshed its
    // independently fetched venue options. Null deliberately means "projection not ready";
    // it must not turn a normal cross-request race into a top-level Flutter error.
    expect(group.chosenVenue, isNull);
  });
}
