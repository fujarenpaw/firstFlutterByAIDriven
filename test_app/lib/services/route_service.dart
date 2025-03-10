import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert';
import 'dart:math';
import '../models/place.dart';

class RouteService {
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
      print('ルート検索開始: ${origin.latitude},${origin.longitude} → ${destination.latitude},${destination.longitude}');
      print('APIキー: ${_apiKey.substring(0, 8)}...'); // APIキーの一部を表示

      final url = Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes');
      
      final requestBody = {
        'origin': {
          'location': {
            'latLng': {
              'latitude': origin.latitude,
              'longitude': origin.longitude,
            },
          },
        },
        'destination': {
          'location': {
            'latLng': {
              'latitude': destination.latitude,
              'longitude': destination.longitude,
            },
          },
        },
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_AWARE',
        'computeAlternativeRoutes': false,
        'routeModifiers': {
          'vehicleInfo': {
            'emissionType': 'GASOLINE',
          },
        },
        'languageCode': 'ja-JP',
        'units': 'METRIC',
      };

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _apiKey,
          'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline',
        },
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final encodedPolyline = route['polyline']['encodedPolyline'];
          
          // エンコードされたポリラインをデコード
          final points = _decodePolyline(encodedPolyline);
          
          if (points.isNotEmpty) {
            List<LatLng> polylineCoordinates = points
                .map((point) => LatLng(
                      point['lat'] ?? 0.0,
                      point['lng'] ?? 0.0,
                    ))
                .toList();

            polylines.add(
              Polyline(
                polylineId: const PolylineId('route'),
                color: Colors.blue,
                points: polylineCoordinates,
                width: 5,
              ),
            );
            
            print('ルート生成成功: ${points.length}ポイント');
          } else {
            print('警告: ポリラインのポイントが空です');
            throw Exception('ポリラインのポイントが空です');
          }
        } else {
          print('警告: ルートが見つかりませんでした');
          throw Exception('ルートが見つかりませんでした');
        }
      } else {
        print('Directions API エラー: ${response.statusCode}');
        print('レスポンス: ${response.body}');
        throw Exception('ルート取得エラー: ${response.statusCode}');
      }

      // 追加時間がある場合は経由地点を探索
      if (additionalTime != null) {
        print('経由地点の検索開始: 追加時間=$additionalTime分');
        waypoints = await _findWaypoints(origin, destination, additionalTime);
        print('経由地点の検索完了: ${waypoints.length}件');
      }

      return {
        'polylines': polylines,
        'waypoints': waypoints,
      };
    } catch (e, stackTrace) {
      print('RouteService エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  List<Map<String, double>> _decodePolyline(String encoded) {
    List<Map<String, double>> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);

      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add({
        'lat': lat / 1E5,
        'lng': lng / 1E5,
      });
    }

    return points;
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
          'https://places.googleapis.com/v1/places:searchNearby'
        );

        final requestBody = {
          'locationRestriction': {
            'circle': {
              'center': {
                'latitude': midPoint.latitude,
                'longitude': midPoint.longitude,
              },
              'radius': radius,
            },
          },
          'includedTypes': [category],
          'maxResultCount': 20,
        };

        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': _apiKey,
            'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress,places.rating,places.location',
          },
          body: json.encode(requestBody),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['places'] != null) {
            final places = data['places'] as List;
            for (final place in places) {
              allPlaces.add(Place(
                id: place['id'] ?? '',
                name: place['displayName']['text'] ?? '',
                category: _mapGooglePlaceTypeToCategory(category),
                location: LatLng(
                  place['location']['latitude'],
                  place['location']['longitude'],
                ),
                rating: place['rating']?.toDouble(),
              ));
            }
          }
        } else {
          print('Places API エラー: ${response.statusCode}');
          print('レスポンス: ${response.body}');
        }
      }

      // 評価順にソートして上位3件を返す
      allPlaces.sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
      return allPlaces.take(3).toList();
    } catch (e) {
      print('経由地点検索エラー: $e');
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