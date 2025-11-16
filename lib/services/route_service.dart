import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class CancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

class PlaceSuggestion {
  final String name;
  final String address;
  final LatLng point;

  PlaceSuggestion({required this.name, required this.address, required this.point});
}

class RouteInstruction {
  final String message;
  final LatLng pivot;
  final double distanceMeters;

  RouteInstruction({required this.message, required this.pivot, required this.distanceMeters});
}

enum RouteProfile { walk, drive, transit }

class RoutePlan {
  final List<LatLng> path;
  final List<RouteInstruction> instructions;
  final double distanceMeters;
  final double durationSeconds;
  final RouteProfile profile;

  RoutePlan({
    required this.path,
    required this.instructions,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.profile,
  });
}

class RouteService {
  RouteService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final _cache = _LruCache<String, List<PlaceSuggestion>>(32);

  static const _userAgent = 'CellSay Ruta/1.0 (+https://cellsay.cl)';

  Future<List<PlaceSuggestion>> searchPlaces(
    String query, {
    LatLng? bias,
    CancellationToken? token,
  }) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final cacheKey = '${normalized}_${bias?.latitude.toStringAsFixed(2) ?? 'x'}_${bias?.longitude.toStringAsFixed(2) ?? 'y'}';
    final cached = _cache.get(cacheKey);
    if (cached != null) {
      return cached;
    }
    final params = <String, String>{
      'format': 'jsonv2',
      'accept-language': 'es',
      'limit': '8',
      'countrycodes': 'cl',
      'addressdetails': '1',
      'namedetails': '1',
      'dedupe': '1',
      'q': normalized,
    };
    if (bias != null) {
      params['lat'] = bias.latitude.toString();
      params['lon'] = bias.longitude.toString();
    }
    final nominatimUri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    List<PlaceSuggestion> places = const [];
    try {
      final response = await _getWithRetries(nominatimUri, token: token);
      if (token?.isCancelled ?? false) {
        return const [];
      }
      if (response != null && response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is List) {
          places =
              body.map<PlaceSuggestion?>((raw) => _mapNominatimPlace(raw)).whereType<PlaceSuggestion>().toList();
        }
      } else if (response != null && response.statusCode != 200) {
        developer.log('Nominatim error ${response.statusCode}: ${response.body}', name: '[ROUTE]');
      }
    } catch (e, st) {
      developer.log('Nominatim exception $e', name: '[ROUTE]', stackTrace: st);
    }
    if ((places.isEmpty) && !(token?.isCancelled ?? false)) {
      try {
        places = await _fetchPhoton(normalized, bias: bias, token: token);
      } catch (e, st) {
        developer.log('Photon fallback error $e', name: '[ROUTE]', stackTrace: st);
      }
    }
    if (token?.isCancelled ?? false) {
      return const [];
    }
    if (places.isNotEmpty) {
      _cache.set(cacheKey, places);
    }
    return places;
  }

  Future<RoutePlan?> buildRoute({
    required LatLng origin,
    required LatLng destination,
    RouteProfile profile = RouteProfile.walk,
  }) async {
    final osrmProfile = profile == RouteProfile.drive ? 'driving' : 'foot';
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/$osrmProfile/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}'
      '?overview=full&geometries=geojson&steps=true&annotations=true',
    );
    try {
      final response = await _client
          .get(url, headers: const {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final routes = body['routes'];
        if (routes is List && routes.isNotEmpty) {
          final best = routes.first;
          final geometry = best['geometry'];
          final coordinates = geometry?['coordinates'];
          final List<LatLng> path = [
            if (coordinates is List)
              for (final pair in coordinates)
                if (pair is List && pair.length >= 2) LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble()),
          ];
          final instructions = _extractInstructions(best);
          return RoutePlan(
            path: path,
            instructions: instructions,
            distanceMeters: (best['distance'] as num?)?.toDouble() ?? 0,
            durationSeconds: (best['duration'] as num?)?.toDouble() ?? 0,
            profile: profile,
          );
        }
      } else {
        developer.log('OSRM responded ${response.statusCode}', name: '[ROUTE]');
      }
    } catch (e, st) {
      developer.log('Route build error $e', name: '[ROUTE]', stackTrace: st);
    }
    if (profile == RouteProfile.transit) {
      return null;
    }
    return _buildValhallaRoute(origin: origin, destination: destination, profile: profile);
  }

  Future<RoutePlan?> _buildValhallaRoute({
    required LatLng origin,
    required LatLng destination,
    required RouteProfile profile,
  }) async {
    final uri = Uri.parse('https://valhalla1.openstreetmap.de/route');
    final body = {
      'locations': [
        {'lat': origin.latitude, 'lon': origin.longitude},
        {'lat': destination.latitude, 'lon': destination.longitude},
      ],
      'costing': profile == RouteProfile.drive ? 'auto' : 'pedestrian',
      'directions_options': {
        'language': 'es-ES',
        'units': 'kilometers',
      },
      'shape_format': 'polyline6',
    };
    try {
      final response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json', 'User-Agent': _userAgent},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        developer.log('Valhalla responded ${response.statusCode}', name: '[ROUTE]');
        return null;
      }
      final decoded = jsonDecode(response.body);
      final trip = decoded['trip'];
      if (trip is! Map) return null;
      final legs = trip['legs'];
      if (legs is! List || legs.isEmpty) return null;
      final firstLeg = legs.first;
      final shape = firstLeg['shape']?.toString();
      final List<LatLng> path = shape == null ? [] : _decodeValhallaShape(shape);
      final instructions = _extractValhallaInstructions(firstLeg, path);
      return RoutePlan(
        path: path,
        instructions: instructions,
        distanceMeters: (trip['summary']?['length'] as num? ?? 0) * 1000,
        durationSeconds: ((trip['summary']?['time'] as num?) ?? 0).toDouble(),
        profile: profile,
      );
    } catch (e, st) {
      developer.log('Valhalla request failed $e', name: '[ROUTE]', stackTrace: st);
      return null;
    }
  }

  Future<http.Response?> _getWithRetries(Uri uri, {CancellationToken? token, int retries = 2}) async {
    var delay = const Duration(milliseconds: 500);
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (token?.isCancelled ?? false) {
        return null;
      }
      try {
        final response = await _client
            .get(uri, headers: const {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 7));
        if (response.statusCode == 429 && attempt < retries) {
          await Future.delayed(delay);
          delay *= 2;
          continue;
        }
        if (response.statusCode >= 500 && attempt < retries) {
          await Future.delayed(delay);
          delay *= 2;
          continue;
        }
        return response;
      } catch (e, st) {
        developer.log('Nominatim request failed $e', name: '[ROUTE]', stackTrace: st);
        if (attempt == retries) rethrow;
        await Future.delayed(delay);
        delay *= 2;
      }
    }
    return null;
  }

  Future<List<PlaceSuggestion>> _fetchPhoton(
    String query, {
    LatLng? bias,
    CancellationToken? token,
  }) async {
    final params = <String, String>{
      'q': query,
      'lang': 'es',
      'limit': '8',
      'osm_tag': 'amenity:*,highway:*,place:*',
    };
    if (bias != null) {
      params['lat'] = bias.latitude.toString();
      params['lon'] = bias.longitude.toString();
    }
    final uri = Uri.https('photon.komoot.io', '/api/', params);
    final response = await _client
        .get(uri, headers: const {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 7));
    if (token?.isCancelled ?? false) return const [];
    if (response.statusCode != 200) {
      developer.log('Photon responded ${response.statusCode}', name: '[ROUTE]');
      return const [];
    }
    final Map<String, dynamic> body = jsonDecode(response.body);
    final features = body['features'];
    if (features is! List) return const [];
    return features
        .map<PlaceSuggestion?>((feature) => _mapPhotonPlace(feature))
        .whereType<PlaceSuggestion>()
        .toList();
  }

  PlaceSuggestion? _mapNominatimPlace(dynamic raw) {
    final lat = double.tryParse(raw['lat']?.toString() ?? '');
    final lon = double.tryParse(raw['lon']?.toString() ?? '');
    if (lat == null || lon == null) return null;
    final addressMap = raw['address'];
    final address = _normalizeAddress(addressMap is Map ? addressMap : null, raw['display_name']?.toString());
    final namedetails = raw['namedetails'];
    final primaryName = namedetails is Map
        ? (namedetails['name'] ?? namedetails['official_name'] ?? namedetails['short_name'])?.toString()
        : null;
    final display = primaryName ?? address.split(',').first;
    return PlaceSuggestion(
      name: display.trim().isEmpty ? 'Destino' : display,
      address: address,
      point: LatLng(lat, lon),
    );
  }

  PlaceSuggestion? _mapPhotonPlace(dynamic feature) {
    if (feature is! Map) return null;
    final geometry = feature['geometry'];
    final coords = geometry is Map ? geometry['coordinates'] : null;
    if (coords is! List || coords.length < 2) return null;
    final properties = feature['properties'];
    final lat = (coords[1] as num?)?.toDouble();
    final lon = (coords[0] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    final name = properties is Map ? (properties['name'] ?? properties['street'] ?? 'Destino') : 'Destino';
    final address = _normalizeAddress(
      properties is Map
          ? {
              'road': properties['street'],
              'house_number': properties['housenumber'],
              'city': properties['city'] ?? properties['locality'],
              'state': properties['state'],
            }
          : null,
      properties is Map ? properties['name']?.toString() : null,
    );
    return PlaceSuggestion(
      name: name.toString(),
      address: address,
      point: LatLng(lat, lon),
    );
  }

  String _normalizeAddress(Map<dynamic, dynamic>? address, String? fallback) {
    final parts = <String>[];
    void add(String? value) {
      if (value == null) return;
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (!parts.any((existing) => existing.toLowerCase() == trimmed.toLowerCase())) {
        parts.add(trimmed);
      }
    }

    if (address != null) {
      add(address['road']?.toString() ?? address['pedestrian']?.toString());
      add(address['house_number']?.toString());
      add(address['neighbourhood']?.toString() ?? address['suburb']?.toString());
      add(address['city_district']?.toString() ?? address['city']?.toString() ?? address['town']?.toString());
      add(address['state']?.toString() ?? address['region']?.toString());
      final country = address['country_code']?.toString().toUpperCase();
      if (country == 'CL' || (address['country']?.toString().toLowerCase() == 'chile')) {
        add('Chile');
      }
    }
    if (parts.isEmpty && fallback != null) {
      parts.add(fallback);
    }
    return parts.join(', ');
  }

  List<RouteInstruction> _extractInstructions(dynamic rawRoute) {
    final List<RouteInstruction> instructions = [];
    final legs = rawRoute['legs'];
    if (legs is! List) return instructions;
    for (final leg in legs) {
      final steps = leg['steps'];
      if (steps is! List) continue;
      for (final step in steps) {
        final maneuver = step['maneuver'] ?? {};
        final modifier = maneuver['modifier']?.toString() ?? '';
        final type = maneuver['type']?.toString() ?? '';
        final name = step['name']?.toString() ?? '';
        final location = maneuver['location'];
        final List<double> coords = location is List
            ? [
                (location[1] as num?)?.toDouble() ?? 0,
                (location[0] as num?)?.toDouble() ?? 0,
              ]
            : [0, 0];
        final lat = coords[0];
        final lon = coords[1];
        final distance = (step['distance'] as num?)?.toDouble() ?? 0;
        final message = _instructionFor(type: type, modifier: modifier, roadName: name, distance: distance);
        instructions.add(
          RouteInstruction(
            message: message,
            pivot: LatLng(lat, lon),
            distanceMeters: distance,
          ),
        );
      }
    }
    return instructions;
  }

  List<RouteInstruction> _extractValhallaInstructions(dynamic leg, List<LatLng> path) {
    final List<RouteInstruction> instructions = [];
    if (leg is! Map) return instructions;
    final maneuvers = leg['maneuvers'];
    if (maneuvers is! List) return instructions;
    for (final maneuver in maneuvers) {
      if (maneuver is! Map) continue;
      final text = maneuver['instruction']?.toString() ?? '';
      final length = (maneuver['length'] as num?)?.toDouble() ?? 0;
      final index = (maneuver['begin_shape_index'] as num?)?.toInt() ?? 0;
      final pivot = (index >= 0 && index < path.length)
          ? path[index]
          : LatLng(
              (maneuver['lat'] as num? ?? 0).toDouble(),
              (maneuver['lon'] as num? ?? 0).toDouble(),
            );
      final normalized = text.isEmpty ? 'Sigue el recorrido.' : text;
      instructions.add(
        RouteInstruction(
          message: normalized,
          pivot: pivot,
          distanceMeters: length * 1000,
        ),
      );
    }
    return instructions;
  }

  List<LatLng> _decodeValhallaShape(String shape) {
    final points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lon = 0;
    while (index < shape.length) {
      final resultLat = _decodeValhallaValue(shape, index);
      index = resultLat.$2;
      lat += resultLat.$1;

      final resultLon = _decodeValhallaValue(shape, index);
      index = resultLon.$2;
      lon += resultLon.$1;

      points.add(LatLng(lat / 1e6, lon / 1e6));
    }
    return points;
  }

  (int, int) _decodeValhallaValue(String encoded, int startIndex) {
    int result = 0;
    int shift = 0;
    int index = startIndex;
    int b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1F) << shift;
      shift += 5;
    } while (b >= 0x20 && index < encoded.length);
    final delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    return (delta, index);
  }

  String _instructionFor({required String type, required String modifier, required String roadName, required double distance}) {
    final meters = distance.toStringAsFixed(0);
    switch (type) {
      case 'depart':
        return 'Inicia tu recorrido y avanza $meters metros por $roadName.';
      case 'arrive':
        return 'Has llegado a tu destino.';
      case 'turn':
      case 'new name':
        final direction = _mapDirection(modifier);
        return 'En $meters metros ${direction.isEmpty ? 'continúa' : 'gira $direction'} hacia $roadName.';
      case 'roundabout':
        return 'Entra a la rotonda y toma la salida hacia $roadName.';
      case 'end of road':
        return 'Al final de la calle, continúa hacia $roadName.';
      default:
        if (roadName.toLowerCase().contains('crosswalk') || roadName.toLowerCase().contains('paso')) {
          return 'Cruza la calle con precaución y continúa $meters metros.';
        }
        return 'Sigue $meters metros hacia $roadName.';
    }
  }

  String _mapDirection(String modifier) {
    switch (modifier) {
      case 'left':
        return 'a la izquierda';
      case 'right':
        return 'a la derecha';
      case 'slight left':
        return 'levemente a la izquierda';
      case 'slight right':
        return 'levemente a la derecha';
      case 'straight':
        return 'de frente';
      default:
        return '';
    }
  }
}

class _LruCache<K, V> {
  _LruCache(this.capacity);

  final int capacity;
  final _map = LinkedHashMap<K, V>();

  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key);
    if (value != null) {
      _map[key] = value;
    }
    return value;
  }

  void set(K key, V value) {
    if (_map.length >= capacity && !_map.containsKey(key)) {
      _map.remove(_map.keys.first);
    } else if (_map.containsKey(key)) {
      _map.remove(key);
    }
    _map[key] = value;
  }
}
