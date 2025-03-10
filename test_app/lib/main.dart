import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'services/route_service.dart';
import 'models/place.dart';

Future<void> main() async {
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print('Error loading .env file: $e');
    // デフォルトの環境変数を設定
    dotenv.env['GOOGLE_MAPS_API_KEY'] = 'YOUR_DEFAULT_API_KEY';
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Google Maps Clone',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _controller;
  Position? _currentPosition;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final RouteService _routeService = RouteService();
  LatLng? _destinationLocation;
  List<Place> _waypoints = [];
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isSearching = false;

  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(35.6812, 139.7671), // 東京の座標
    zoom: 14.0,
  );

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      print('位置情報サービスが無効です');
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print('位置情報の権限が拒否されました');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      print('位置情報の権限が永続的に拒否されました');
      return;
    }

    try {
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
      
      if (!mounted) return;
      
      setState(() {
        _currentPosition = position;
        _updateCurrentLocationMarker();
      });

      if (_controller != null) {
        await _controller!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(position.latitude, position.longitude),
              zoom: 15.0,
            ),
          ),
        );
      }
    } catch (e) {
      print('現在地の取得に失敗: $e');
    }
  }

  void _updateCurrentLocationMarker() {
    if (_currentPosition == null) return;
    
    _markers.removeWhere(
      (marker) => marker.markerId == const MarkerId('currentLocation'),
    );
    
    _markers.add(
      Marker(
        markerId: const MarkerId('currentLocation'),
        position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        infoWindow: const InfoWindow(title: '現在地'),
      ),
    );
  }

  Future<void> _generateRoute(int? additionalTime) async {
    if (_currentPosition == null || _destinationLocation == null) {
      print('ルート生成エラー: 出発地または目的地が設定されていません');
      return;
    }

    try {
      print('ルート生成開始: 追加時間=$additionalTime分');
      final result = await _routeService.generateRoute(
        origin: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        destination: _destinationLocation!,
        additionalTime: additionalTime,
      );

      if (!mounted) return;

      setState(() {
        _polylines.clear();
        _polylines.addAll(result['polylines'] as Set<Polyline>);
        _waypoints = result['waypoints'] as List<Place>;
        
        // 既存の経由地点マーカーを削除
        _markers.removeWhere((marker) => marker.markerId.value.startsWith('waypoint_'));
        
        // 新しい経由地点のマーカーを追加
        for (var waypoint in _waypoints) {
          _markers.add(
            Marker(
              markerId: MarkerId('waypoint_${waypoint.id}'),
              position: waypoint.location,
              infoWindow: InfoWindow(
                title: waypoint.name,
                snippet: waypoint.category.toString(),
              ),
            ),
          );
        }
      });
    } catch (e) {
      print('ルート生成エラー: $e');
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isSearching = true;
    });

    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json'
        '?input=$query'
        '&types=establishment|point_of_interest'
        '&language=ja'
        '&components=country:jp'
        '&key=${dotenv.env['GOOGLE_MAPS_API_KEY']}'
      );

      final response = await http.get(url);
      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        setState(() {
          _searchResults = data['predictions'];
          _isSearching = false;
        });
      }
    } catch (e) {
      print('Error searching places: $e');
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _selectSearchResult(dynamic prediction) async {
    try {
      final placeId = prediction['place_id'];
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/details/json'
        '?place_id=$placeId'
        '&fields=geometry'
        '&key=${dotenv.env['GOOGLE_MAPS_API_KEY']}'
      );

      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK') {
          final location = data['result']['geometry']['location'];
          final latLng = LatLng(location['lat'], location['lng']);

          setState(() {
            _destinationLocation = latLng;
            _searchResults = [];
            _searchController.clear();
            
            // マーカーを追加
            _markers.add(
              Marker(
                markerId: const MarkerId('destination'),
                position: latLng,
                infoWindow: InfoWindow(title: prediction['description']),
              ),
            );
          });

          // 地図を移動
          _controller?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: latLng,
                zoom: 15,
              ),
            ),
          );
        }
      }
    } catch (e) {
      print('Error getting place details: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _initialPosition,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            markers: _markers,
            polylines: _polylines,
            onMapCreated: (GoogleMapController controller) {
              _controller = controller;
            },
            onTap: (LatLng location) {
              setState(() {
                _destinationLocation = location;
                _markers.add(
                  Marker(
                    markerId: const MarkerId('destination'),
                    position: location,
                    infoWindow: const InfoWindow(title: '目的地'),
                  ),
                );
              });
            },
            liteModeEnabled: false,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            mapToolbarEnabled: false,
            compassEnabled: true,
          ),
          // 検索バー
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.search),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              decoration: const InputDecoration(
                                hintText: '場所を検索',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(vertical: 15),
                              ),
                              onChanged: _searchPlaces,
                            ),
                          ),
                          if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchResults = [];
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_searchResults.isNotEmpty)
                    Expanded(
                      child: Card(
                        margin: const EdgeInsets.only(top: 8),
                        child: ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final prediction = _searchResults[index];
                            return ListTile(
                              leading: const Icon(Icons.location_on),
                              title: Text(prediction['description']),
                              onTap: () => _selectSearchResult(prediction),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // ルートボタンと経由地点の表示
          if (_destinationLocation != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton(
                            onPressed: () => _generateRoute(null),
                            child: const Text('最短ルート'),
                          ),
                          ElevatedButton(
                            onPressed: () => _generateRoute(15),
                            child: const Text('+15分'),
                          ),
                          ElevatedButton(
                            onPressed: () => _generateRoute(30),
                            child: const Text('+30分'),
                          ),
                          ElevatedButton(
                            onPressed: () => _generateRoute(60),
                            child: const Text('+60分'),
                          ),
                        ],
                      ),
                      if (_waypoints.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text('経由地点:', style: TextStyle(fontWeight: FontWeight.bold)),
                        ...List.generate(
                          _waypoints.length,
                          (index) => ListTile(
                            title: Text(_waypoints[index].name),
                            subtitle: Text(_waypoints[index].category.toString()),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _getCurrentLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
