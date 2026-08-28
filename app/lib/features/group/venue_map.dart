import 'package:apple_maps_flutter/apple_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/models.dart';

/// The venue on a real map, inside group info.
///
/// MapKit rather than Google Maps: it ships with the OS, so there is no API key, no billing
/// account, and no Cloud project to configure before a pin can render. We are iOS-only for
/// this build, so the cross-platform argument for Google does not apply -- and Google Places
/// enrichment (ratings, photos, hours) carries caching restrictions we deliberately moved
/// away from when the venue corpus left Yelp.
///
/// Getting there is deliberately a hand-off to the system map app rather than in-app
/// navigation: Apple Maps already knows about transit, traffic and walking, and someone ten
/// minutes out wants the app they trust, not ours.
class VenueMap extends StatelessWidget {
  final VenueOption venue;
  final double height;
  const VenueMap(this.venue, {super.key, this.height = 160});

  @override
  Widget build(BuildContext context) {
    // No coordinates is a legitimate state -- a venue is still showable by address, and a
    // broken map is worse than none. pick-venues always returns them; hand-curated or
    // partially-migrated data might not.
    if (!venue.hasLocation) {
      return _Fallback(venue.address);
    }

    final target = LatLng(venue.lat!, venue.lng!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            AppleMap(
              initialCameraPosition: CameraPosition(target: target, zoom: 15.5),
              annotations: {
                Annotation(
                  annotationId: AnnotationId(venue.id),
                  position: target,
                  infoWindow: InfoWindow(
                    title: venue.name,
                    snippet: venue.address,
                  ),
                ),
              },
              // The map is a locator, not a toy. Gestures off keeps it from stealing scroll
              // from the list it sits inside, which on a phone is the difference between the
              // page scrolling and the page feeling broken.
              scrollGesturesEnabled: false,
              zoomGesturesEnabled: false,
              rotateGesturesEnabled: false,
              pitchGesturesEnabled: false,
              myLocationEnabled: false,
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: FilledButton.icon(
                onPressed: () => _openDirections(venue),
                icon: const Icon(Icons.directions, size: 18),
                label: const Text('Directions'),
                style: FilledButton.styleFrom(
                  // Directions is a primary physical-world action, so retain the restyle's
                  // full touch target even though the compact version fits more tightly.
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: accent,
                  foregroundColor: ink,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `maps.apple.com` rather than the `maps://` scheme: the https form is handled by Apple
/// Maps on device and degrades to the web map anywhere else, so it cannot dead-end.
Future<void> _openDirections(VenueOption v) async {
  final uri = Uri.https('maps.apple.com', '/', {
    'll': '${v.lat},${v.lng}',
    'q': v.name,
    'dirflg':
        'w', // walking; these are neighbourhood venues, not cross-town trips
  });
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _Fallback extends StatelessWidget {
  final String address;
  const _Fallback(this.address);

  @override
  Widget build(BuildContext context) => Container(
    height: 84,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      color: bg,
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(16),
    child: Text(
      address,
      textAlign: TextAlign.center,
      style: const TextStyle(color: bodyInk),
    ),
  );
}
