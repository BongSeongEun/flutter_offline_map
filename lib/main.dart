import 'package:flutter/material.dart';
import 'models/place.dart';
import 'screens/chat_screen.dart';
import 'screens/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OfflineMapApp());
}

class OfflineMapApp extends StatelessWidget {
  const OfflineMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '제주 AI 가이드',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
        fontFamily: 'Pretendard',
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;
  List<Place> _recommendedPlaces = const [];
  Place? _selectedPlace;

  void _handlePlacesUpdated(List<Place> places) {
    setState(() {
      _recommendedPlaces = places;
      _selectedPlace = places.isNotEmpty ? places.first : null;
    });
  }

  void _showMapTab() {
    setState(() => _currentIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      MapScreen(
        places: _recommendedPlaces,
        selected: _selectedPlace,
      ),
      ChatScreen(
        onPlacesUpdated: _handlePlacesUpdated,
        onShowMap: _showMapTab,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: '지도',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: '채팅',
          ),
        ],
      ),
    );
  }
}