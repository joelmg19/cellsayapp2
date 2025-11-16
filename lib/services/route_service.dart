import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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

class RoutePlan {
  final List<LatLng> path;
  final List<RouteInstruction> instructions;
  final double distanceMeters;
  final double durationSeconds;

  RoutePlan({
    required this.path,
    required this.instructions,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

class RouteService {
  RouteService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _userAgent = 'CellSay Ruta/1.0 (+https://cellsay.cl)';

  Future<List<PlaceSuggestion>> searchPlaces(String query) async {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search?format=json&limit=6&addressdetails=1&q=${Uri.encodeQueryComponent(query)}',
    );
    final response = await _client.get(url, headers: const {'User-Agent': _userAgent});
    if (response.statusCode != 200) {
      return [];
    }
    final data = jsonDecode(response.body);
    if (data is! List) return [];
    return data.map((raw) {
      final lat = double.tryParse(raw['lat']?.toString() ?? '') ?? 0;
      final lon = double.tryParse(raw['lon']?.toString() ?? '') ?? 0;
      final display = raw['display_name']?.toString() ?? 'Destino';
      final name = raw['namedetails']?['name']?.toString() ?? display.split(',').first;
      return PlaceSuggestion(
        name: name,
        address: display,
        point: LatLng(lat, lon),
      );
    }).toList();
  }

  Future<RoutePlan?> buildRoute({required LatLng origin, required LatLng destination}) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/foot/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}'
      '?overview=full&geometries=geojson&steps=true&annotations=true',
    );
    final response = await _client.get(url, headers: const {'User-Agent': _userAgent});
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    final routes = body['routes'];
    if (routes is! List || routes.isEmpty) return null;
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
    );
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
