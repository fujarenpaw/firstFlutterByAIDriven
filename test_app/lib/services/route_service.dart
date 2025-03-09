import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'dart:math';
import '../models/place.dart';

class RouteService {
  final PolylinePoints _polylinePoints = PolylinePoints();
  late final String _apiKey;

  RouteService() {
    _apiKey = dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
    if (_apiKey.isEmpty) {
      throw Exception('Google Maps APIキーが設定されていません。.envファイルを確認してください。');
    }
  }

  Future<Map<String, dynamic>> generateRoute({
    required LatLng origin,
    required LatLng destination,
    int? additionalTime, // 追加時間（分）
  }) async {
    List<Place> waypoints = [];
    Set<Polyline> polylines = {};
    
    try {
      final result = await _polylinePoints.getRouteBetweenCoordinates(
        googleApiKey: _apiKey,
        request: PolylineRequest(
          origin: PointLatLng(origin.latitude, origin.longitude),
          destination: PointLatLng(destination.latitude, destination.longitude),
          mode: TravelMode.driving,
        ),
      );

      if (result.points.isNotEmpty) {
        List<LatLng> polylineCoordinates = result.points
            .map((point) => LatLng(point.latitude, point.longitude))
            .toList();

        polylines.add(
          Polyline(
            polylineId: const PolylineId('route'),
            color: Colors.blue,
            points: polylineCoordinates,
            width: 5,
          ),
        );
      }

      // 追加時間がある場合は経由地点を探索
      if (additionalTime != null) {
        waypoints = await _findWaypoints(origin, destination, additionalTime);
      }

      return {
        'polylines': polylines,
        'waypoints': waypoints,
      };
    } catch (e) {
      rethrow;
    }
  }

  Future<List<Place>> _findWaypoints(
    LatLng origin,
    LatLng destination,
    int additionalTime,
  ) async {
    try {
      // 経由地点の検索範囲を計算
      final midPoint = LatLng(
        (origin.latitude + destination.latitude) / 2,
        (origin.longitude + destination.longitude) / 2,
      );
      
      // 検索範囲の半径を計算（メートル単位）
      final radius = _calculateSearchRadius(origin, destination);

      // 検索するカテゴリーのリスト
      final categories = [
        'restaurant',
        'park',
        'tourist_attraction',
        'cafe',
        'shopping_mall',
      ];

      List<Place> allPlaces = [];
      
      // カテゴリーごとに検索
      for (final category in categories) {
        final url = Uri.parse(
          'https://maps.googleapis.com/maps/api/place/nearbysearch/json?'
          'location=${midPoint.latitude},${midPoint.longitude}'
          '&radius=$radius'
          '&type=$category'
          '&key=$_apiKey'
        );

        final response = await http.get(url);
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['status'] == 'OK') {
            final results = data['results'] as List;
            for (final place in results) {
              allPlaces.add(Place(
                id: place['place_id'],
                name: place['name'],
                category: _mapGooglePlaceTypeToCategory(category),
                location: LatLng(
                  place['geometry']['location']['lat'],
                  place['geometry']['location']['lng'],
                ),
                rating: place['rating']?.toDouble(),
              ));
            }
          }
        }
      }

      // 評価順にソートして上位3件を返す
      allPlaces.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
      return allPlaces.take(3).toList();
    } catch (e) {
      print('Error finding waypoints: $e');
      return [];
    }
  }

  double _calculateSearchRadius(LatLng origin, LatLng destination) {
    // 出発地と目的地の距離を計算（メートル単位）
    const double earthRadius = 6371000; // 地球の半径（メートル）
    final double lat1 = origin.latitude * pi / 180;
    final double lat2 = destination.latitude * pi / 180;
    final double dLat = (destination.latitude - origin.latitude) * pi / 180;
    final double dLon = (destination.longitude - origin.longitude) * pi / 180;

    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    final double distance = earthRadius * c;

    // 検索範囲は2地点間の距離の30%とする
    return distance * 0.3;
  }

  PlaceCategory _mapGooglePlaceTypeToCategory(String googlePlaceType) {
    switch (googlePlaceType) {
      case 'restaurant':
        return PlaceCategory.restaurant;
      case 'park':
        return PlaceCategory.park;
      case 'tourist_attraction':
        return PlaceCategory.tourist;
      case 'cafe':
        return PlaceCategory.cafe;
      case 'shopping_mall':
        return PlaceCategory.shopping;
      default:
        return PlaceCategory.other;
    }
  }
} 