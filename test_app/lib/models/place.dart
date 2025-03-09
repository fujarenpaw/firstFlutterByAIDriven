import 'package:google_maps_flutter/google_maps_flutter.dart';

enum PlaceCategory {
  restaurant,
  park,
  tourist,
  cafe,
  shopping,
  other,
}

class Place {
  final String id;
  final String name;
  final PlaceCategory category;
  final LatLng location;
  final String? address;
  final String? photoUrl;
  final double? rating;

  Place({
    required this.id,
    required this.name,
    required this.category,
    required this.location,
    this.address,
    this.photoUrl,
    this.rating,
  });
} 