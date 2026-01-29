import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/place.dart';

class MapScreen extends StatefulWidget {
  final List<Place> places;
  final Place? selected;

  const MapScreen({
    super.key,
    required this.places,
    this.selected,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapLibreMapController? mapController;
  String? _styleString;
  String? _errorMessage;
  bool _isLoading = true;
  bool _styleLoaded = false;
  final List<Circle> _placeCircles = [];

  @override
  void initState() {
    super.initState();
    _prepareOfflineMap();
  }

  @override
  void didUpdateWidget(MapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.places != widget.places || oldWidget.selected != widget.selected) {
      _renderRecommendedPlaces();
    }
  }

  Future<void> _prepareOfflineMap() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mapDir = Directory('${appDir.path}/map');
      final fontsDir = Directory('${appDir.path}/fonts');

      // 디렉토리 생성
      if (!await mapDir.exists()) {
        await mapDir.create(recursive: true);
      }
      if (!await fontsDir.exists()) {
        await fontsDir.create(recursive: true);
      }

      // MBTiles 파일 복사
      final mbtilesFile = File('${mapDir.path}/south-korea.mbtiles');
      if (!await mbtilesFile.exists()) {
        final mbtilesData = await rootBundle.load('assets/map/south-korea.mbtiles');
        await mbtilesFile.writeAsBytes(mbtilesData.buffer.asUint8List());
      }

      // 폰트 파일들 복사
      await _copyFonts(fontsDir.path);

      // style.json 로드 및 경로 수정
      final styleJson = await rootBundle.loadString('assets/map/style.json');
      final styleMap = json.decode(styleJson) as Map<String, dynamic>;

      // MBTiles 절대 경로로 수정
      final sources = styleMap['sources'] as Map<String, dynamic>;
      final openmaptiles = sources['openmaptiles'] as Map<String, dynamic>;
      openmaptiles['url'] = 'mbtiles://${mbtilesFile.path}';

      // 폰트(glyphs) 절대 경로로 수정 (file:// 프로토콜 필수)
      styleMap['glyphs'] = 'file://${fontsDir.path}/{fontstack}/{range}.pbf';

      setState(() {
        _styleString = json.encode(styleMap);
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('오프라인 맵 준비 오류: $e');
      debugPrint('스택트레이스: $stackTrace');
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _copyFonts(String fontsDir) async {
    // Noto_Sans_KR_Thin 폰트 복사
    final fontDir = Directory('$fontsDir/Noto_Sans_KR_Thin');
    if (!await fontDir.exists()) {
      await fontDir.create(recursive: true);
    }

    // 전체 유니코드 범위 (0-65535)를 256 단위로 생성
    for (int start = 0; start < 65536; start += 256) {
      final end = start + 255;
      final range = '$start-$end';
      final assetPath = 'assets/fonts/Noto_Sans_KR_Thin/$range.pbf';

      try {
        final fontFile = File('${fontDir.path}/$range.pbf');
        if (!await fontFile.exists()) {
          final fontData = await rootBundle.load(assetPath);
          await fontFile.writeAsBytes(fontData.buffer.asUint8List());
        }
      } catch (e) {
        // 해당 범위 파일이 없으면 무시 (모든 범위가 있는 것은 아님)
      }
    }
  }

  void _onMapCreated(MapLibreMapController controller) {
    mapController = controller;
    _requestLocationPermission();
  }

  void _onStyleLoaded() {
    _styleLoaded = true;
    _renderRecommendedPlaces();
  }

  Future<void> _renderRecommendedPlaces() async {
    if (!_styleLoaded || mapController == null) return;
    await _clearPlaceCircles();
    if (widget.places.isEmpty) return;

    for (final place in widget.places) {
      final isSelected = widget.selected?.name == place.name;
      final circle = await mapController!.addCircle(
        CircleOptions(
          geometry: LatLng(place.latitude, place.longitude),
          circleRadius: isSelected ? 10.0 : 8.0,
          circleColor: isSelected ? '#E53935' : '#1E88E5',
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#FFFFFF',
        ),
      );
      _placeCircles.add(circle);
    }

    final focus = widget.selected ?? widget.places.first;
    mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(focus.latitude, focus.longitude),
        12.5,
      ),
    );
  }

  Future<void> _clearPlaceCircles() async {
    if (_placeCircles.isEmpty) return;
    for (final circle in _placeCircles) {
      await mapController?.removeCircle(circle);
    }
    _placeCircles.clear();
  }

  Future<void> _requestLocationPermission() async {
    final status = await Permission.location.request();
    if (status.isGranted) {
      _getCurrentLocation();
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 현재 위치로 카메라 이동
      mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          15.0,
        ),
      );

      // 현재 위치에 파란색 원 표시
      mapController?.addCircle(
        CircleOptions(
          geometry: LatLng(position.latitude, position.longitude),
          circleRadius: 8.0,
          circleColor: '#4285F4',
          circleStrokeWidth: 3.0,
          circleStrokeColor: '#FFFFFF',
        ),
      );
    } catch (e) {
      debugPrint('위치 가져오기 오류: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('오프라인 맵 준비 중...'),
            ],
          ),
        ),
      );
    }

    if (_styleString == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('맵 스타일 로드 실패', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Text(_errorMessage ?? '알 수 없는 오류', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            initialCameraPosition: const CameraPosition(
              target: LatLng(33.3617, 126.5292), // 제주 중심 근사
              zoom: 11.0,
            ),
            styleString: _styleString!,
            myLocationEnabled: true,
          ),
          if (widget.places.isNotEmpty)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '추천 장소 ${widget.places.length}곳',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: widget.places
                            .map((place) => Chip(label: Text(place.name)))
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            bottom: 30,
            right: 20,
            child: FloatingActionButton(
              onPressed: _getCurrentLocation,
              backgroundColor: Colors.white,
              child: const Icon(Icons.my_location, color: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }
}
