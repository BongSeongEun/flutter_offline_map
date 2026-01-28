import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MaterialApp(home: MapScreen()));

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapLibreMapController? mapController;
  String? _styleString;
  String? _errorMessage;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _prepareOfflineMap();
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
            initialCameraPosition: const CameraPosition(
              target: LatLng(37.5665, 126.9780), // 서울 좌표
              zoom: 14.0,
            ),
            styleString: _styleString!,
            myLocationEnabled: true,
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