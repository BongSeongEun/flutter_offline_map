import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/place.dart';

class PlaceIndexService {
  static final PlaceIndexService _instance = PlaceIndexService._internal();
  factory PlaceIndexService() => _instance;
  PlaceIndexService._internal();

  bool _isLoaded = false;
  final List<Place> _places = [];
  final Map<String, Place> _byName = {};

  Future<void> load() async {
    if (_isLoaded) return;
    final jsonString = await rootBundle.loadString('assets/data/jeju_data.json');
    final List<dynamic> jsonData = jsonDecode(jsonString);

    for (final raw in jsonData) {
      if (raw is! Map<String, dynamic>) continue;
      final name = (raw['title'] ?? '').toString().trim();
      final mapx = _toDouble(raw['mapx']);
      final mapy = _toDouble(raw['mapy']);
      if (name.isEmpty || mapx == null || mapy == null) continue;
      final address = (raw['address'] ?? '').toString();

      final place = Place(
        name: name,
        latitude: mapy,
        longitude: mapx,
        address: address,
      );
      _places.add(place);
      _byName.putIfAbsent(name, () => place);
    }
    _isLoaded = true;
  }

  Future<Place?> findByName(String name) async {
    await load();
    return _byName[name];
  }

  Future<List<Place>> findMatchesInText(
    String text, {
    int maxResults = 3,
  }) async {
    await load();
    if (text.trim().isEmpty) return const [];

    final matches = <Place>[];
    for (final place in _places) {
      if (text.contains(place.name)) {
        matches.add(place);
        if (matches.length >= maxResults) break;
      }
    }
    return matches;
  }

  double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
