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
    int? routeDuration;
    
    try {
      print('ルート検索開始: ${origin.latitude},${origin.longitude} → ${destination.latitude},${destination.longitude}');
      print('APIキー: ${_apiKey.substring(0, 8)}...'); // APIキーの一部を表示

      // まず最短ルートを取得
      final directRoute = await _getDirectRoute(origin, destination);
      if (directRoute == null) {
        throw Exception('最短ルートの取得に失敗しました');
      }

      final baseDuration = directRoute['duration'];
      routeDuration = baseDuration;
      print('最短ルートの所要時間: $baseDuration分');

      // 追加時間がある場合は経由地点を探索
      if (additionalTime != null) {
        print('経由地点の検索開始: 追加時間=$additionalTime分');
        waypoints = await _findWaypoints(origin, destination, baseDuration, additionalTime);
        print('経由地点の検索完了: ${waypoints.length}件');
      }

      // 経由地点がある場合は、それらを含むルートを取得
      if (waypoints.isNotEmpty) {
        final routeWithWaypoints = await _getRouteWithWaypoints(origin, destination, waypoints);
        if (routeWithWaypoints != null) {
          polylines = routeWithWaypoints['polylines'];
          routeDuration = routeWithWaypoints['duration'];
        }
      } else {
        polylines = directRoute['polylines'];
      }

      return {
        'polylines': polylines,
        'waypoints': waypoints,
        'duration': routeDuration,
      };
    } catch (e, stackTrace) {
      print('RouteService エラー: $e');
      print('スタックトレース: $stackTrace');
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _getDirectRoute(LatLng origin, LatLng destination) async {
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
        final duration = route['duration'].toString();
        
        // エンコードされたポリラインをデコード
        final points = _decodePolyline(encodedPolyline);
        
        if (points.isNotEmpty) {
          List<LatLng> polylineCoordinates = points
              .map((point) => LatLng(
                    point['lat'] ?? 0.0,
                    point['lng'] ?? 0.0,
                  ))
              .toList();

          // 所要時間を分に変換（秒から分へ）
          int durationInMinutes;
          if (duration.endsWith('s')) {
            // 秒単位の場合
            final seconds = int.parse(duration.replaceAll('s', ''));
            durationInMinutes = (seconds / 60).ceil();
          } else {
            // 分単位の場合
            durationInMinutes = int.parse(duration);
          }

          return {
            'polylines': {
              Polyline(
                polylineId: const PolylineId('route'),
                color: Colors.blue,
                points: polylineCoordinates,
                width: 5,
              ),
            },
            'duration': durationInMinutes,
          };
        }
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getRouteWithWaypoints(
    LatLng origin,
    LatLng destination,
    List<Place> waypoints,
  ) async {
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
      'intermediates': waypoints.map((waypoint) => {
        'location': {
          'latLng': {
            'latitude': waypoint.location.latitude,
            'longitude': waypoint.location.longitude,
          },
        },
      }).toList(),
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
        final duration = route['duration'].toString();
        
        final points = _decodePolyline(encodedPolyline);
        
        if (points.isNotEmpty) {
          List<LatLng> polylineCoordinates = points
              .map((point) => LatLng(
                    point['lat'] ?? 0.0,
                    point['lng'] ?? 0.0,
                  ))
              .toList();

          // 所要時間を分に変換（秒から分へ）
          int durationInMinutes;
          if (duration.endsWith('s')) {
            // 秒単位の場合
            final seconds = int.parse(duration.replaceAll('s', ''));
            durationInMinutes = (seconds / 60).ceil();
          } else {
            // 分単位の場合
            durationInMinutes = int.parse(duration);
          }

          return {
            'polylines': {
              Polyline(
                polylineId: const PolylineId('route'),
                color: Colors.blue,
                points: polylineCoordinates,
                width: 5,
              ),
            },
            'duration': durationInMinutes,
          };
        }
      }
    }
    return null;
  }

  Future<List<Place>> _findWaypoints(
    LatLng origin,
    LatLng destination,
    int baseDuration,
    int targetAdditionalTime,
  ) async {
    try {
      final midPoint = LatLng(
        (origin.latitude + destination.latitude) / 2,
        (origin.longitude + destination.longitude) / 2,
      );
      
      final radius = _calculateSearchRadius(origin, destination);
      
      // カテゴリ一覧
      final allCategories = [
        'restaurant',
        'park',
        'tourist_attraction',
        'cafe',
        'shopping_mall',
      ];

      // 目的地のカテゴリを取得
      final destinationCategory = await _getPlaceCategory(destination);
      
      // 目的地と異なるカテゴリのみをフィルタリング
      final availableCategories = allCategories.where((category) => 
        _mapGooglePlaceTypeToCategory(category) != destinationCategory
      ).toList();

      // 所要時間に応じてカテゴリ数を決定
      final numCategories = targetAdditionalTime >= 60 ? 2 : 1;
      
      // カテゴリの検索順序を決定
      final searchOrder = _determineSearchOrder(availableCategories, numCategories);
      
      List<Place> allPlaces = [];
      
      for (final category in searchOrder) {
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
            
            // 所要時間に応じて必要な施設数を判定
            // +60分の場合は2以上、それ以外（+15分、+30分）は1以上で十分
            final requiredPlaces = targetAdditionalTime >= 60 ? 2 : 1;
            if (allPlaces.length >= requiredPlaces) {
              break;
            }
          }
        }
      }

      // 各施設までの所要時間を計算し、目標追加時間に近い施設を選択
      List<Map<String, dynamic>> placesWithDuration = [];
      for (final place in allPlaces) {
        final routeToPlace = await _getDirectRoute(origin, place.location);
        final routeFromPlace = await _getDirectRoute(place.location, destination);
        
        if (routeToPlace != null && routeFromPlace != null) {
          final totalDuration = routeToPlace['duration'] + routeFromPlace['duration'];
          final additionalDuration = totalDuration - baseDuration;
          
          placesWithDuration.add({
            'place': place,
            'duration': additionalDuration,
            'diff': (additionalDuration - targetAdditionalTime).abs(),
          });
        }
      }

      // 目標時間との差が小さい順にソート
      placesWithDuration.sort((a, b) => a['diff'].compareTo(b['diff']));
      
      // 上位3件を返す
      return placesWithDuration
          .take(3)
          .map((item) => item['place'] as Place)
          .toList();
    } catch (e) {
      print('経由地点検索エラー: $e');
      return [];
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
      case 'museum':
        return PlaceCategory.tourist;
      case 'library':
        return PlaceCategory.tourist;
      case 'art_gallery':
        return PlaceCategory.tourist;
      case 'bakery':
        return PlaceCategory.restaurant;
      case 'supermarket':
        return PlaceCategory.shopping;
      default:
        return PlaceCategory.other;
    }
  }

  // カテゴリの検索順序を決定する関数
  List<String> _determineSearchOrder(List<String> categories, int count) {
    final random = Random();
    final selected = <String>[];
    final available = List<String>.from(categories);
    
    // カテゴリの優先順位を設定（ランダムに並び替え）
    final baseCategories = [
      'restaurant',    // レストラン
      'cafe',         // カフェ
      'tourist_attraction', // 観光地
      'park',         // 公園
      'shopping_mall', // ショッピングモール
      'museum',       // 博物館
      'library',      // 図書館
      'bakery',       // パン屋
      'supermarket',  // スーパーマーケット
      'art_gallery'   // アートギャラリー
    ];
    
    // カテゴリリストをランダムに並び替え
    final priorityOrder = List<String>.from(baseCategories)..shuffle(random);
    
    // 優先順位に基づいてカテゴリを選択
    for (final priority in priorityOrder) {
      if (available.contains(priority)) {
        selected.add(priority);
        available.remove(priority);
        if (selected.length >= count) break;
      }
    }
    
    // 必要な数に達していない場合は、残りのカテゴリからランダムに選択
    while (selected.length < count && available.isNotEmpty) {
      final index = random.nextInt(available.length);
      selected.add(available.removeAt(index));
    }
    
    return selected;
  }

  // 指定された位置のカテゴリを取得する関数
  Future<PlaceCategory> _getPlaceCategory(LatLng location) async {
    try {
      final url = Uri.parse('https://places.googleapis.com/v1/places:searchNearby');
      
      final requestBody = {
        'locationRestriction': {
          'circle': {
            'center': {
              'latitude': location.latitude,
              'longitude': location.longitude,
            },
            'radius': 100, // 非常に小さい半径で検索
          },
        },
        'maxResultCount': 1,
      };

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _apiKey,
          'X-Goog-FieldMask': 'places.types',
        },
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['places'] != null && data['places'].isNotEmpty) {
          final place = data['places'][0];
          if (place['types'] != null && place['types'].isNotEmpty) {
            return _mapGooglePlaceTypeToCategory(place['types'][0]);
          }
        }
      }
    } catch (e) {
      print('カテゴリ取得エラー: $e');
    }
    
    return PlaceCategory.other; // デフォルト値
  }
} 