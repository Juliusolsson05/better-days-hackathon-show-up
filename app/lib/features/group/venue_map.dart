import 'package:apple_maps_flutter/apple_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
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
typedef VenueGeocoder = Future<LatLng?> Function(String address);

class VenueMap extends StatefulWidget {
  final VenueOption venue;
  final double height;
  const VenueMap(this.venue, {super.key, this.height = 160, this.geocode});

  /// The injected seam makes the native address lookup deterministic in widget tests. Production
  /// always uses Apple's geocoder, so reference fixtures gain real coordinates without hard-coded
  /// guesses or a second map provider/API key.
  final VenueGeocoder? geocode;

  @override
  State<VenueMap> createState() => _VenueMapState();
}

class _VenueMapState extends State<VenueMap> {
  LatLng? _target;
  var _resolving = false;
  var _resolutionEpoch = 0;

  VenueOption get venue => widget.venue;

  @override
  void initState() {
    super.initState();
    _target = _explicitTarget;
    if (_target == null) _resolveAddress();
  }

  @override
  void didUpdateWidget(covariant VenueMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.venue.id == venue.id &&
        oldWidget.venue.address == venue.address &&
        oldWidget.venue.lat == venue.lat &&
        oldWidget.venue.lng == venue.lng) {
      return;
    }
    _target = _explicitTarget;
    if (_target == null) _resolveAddress();
  }

  LatLng? get _explicitTarget =>
      venue.hasLocation ? LatLng(venue.lat!, venue.lng!) : null;

  Future<void> _resolveAddress() async {
    if (venue.address.trim().isEmpty) return;
    final epoch = ++_resolutionEpoch;
    _resolving = true;
    final venueId = venue.id;
    try {
      final resolved = widget.geocode != null
          ? await widget.geocode!(venue.address)
          : await _geocodeAddress(venue.address);
      // A venue can change while CLGeocoder is in flight. Applying the old result would put the
      // new venue's title on the previous venue's pin, which is worse than showing no map.
      if (mounted && epoch == _resolutionEpoch && venue.id == venueId) {
        setState(() => _target = resolved);
      }
    } catch (_) {
      // Native geocoding is rate-limited and can be unavailable offline. The address remains a
      // useful, honest fallback; the map retries naturally if this widget is reconstructed.
    } finally {
      if (mounted && epoch == _resolutionEpoch && venue.id == venueId) {
        setState(() => _resolving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    if (target == null) return _Fallback(venue.address, resolving: _resolving);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            AppleMap(
              key: ValueKey(
                '${venue.id}:${target.latitude}:${target.longitude}',
              ),
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
                onPressed: () => _openDirections(venue, target),
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

Future<LatLng?> _geocodeAddress(String address) async {
  final matches = await Geocoding().locationFromAddress(address);
  if (matches.isEmpty) return null;
  final first = matches.first;
  return LatLng(first.latitude, first.longitude);
}

/// `maps.apple.com` rather than the `maps://` scheme: the https form is handled by Apple
/// Maps on device and degrades to the web map anywhere else, so it cannot dead-end.
Future<void> _openDirections(VenueOption v, LatLng target) async {
  final uri = Uri.https('maps.apple.com', '/', {
    'll': '${target.latitude},${target.longitude}',
    'q': v.name,
    'dirflg':
        'w', // walking; these are neighbourhood venues, not cross-town trips
  });
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _Fallback extends StatelessWidget {
  final String address;
  final bool resolving;
  const _Fallback(this.address, {required this.resolving});

  @override
  Widget build(BuildContext context) => Container(
    height: 84,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      color: bg,
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (resolving) ...[
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Text(
            address,
            textAlign: TextAlign.center,
            style: const TextStyle(color: bodyInk),
          ),
        ),
      ],
    ),
  );
}
