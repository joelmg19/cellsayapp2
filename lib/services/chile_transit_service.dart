import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

enum TransitMode { bus, metro, train }

class TransitVehicle {
  final String id;
  final TransitMode mode;
  final String lineName;
  final LatLng position;
  final double? bearing;
  final DateTime? timestamp;
  final double? distanceToUser;
  final String provider;

  const TransitVehicle({
    required this.id,
    required this.mode,
    required this.lineName,
    required this.position,
    required this.provider,
    this.bearing,
    this.timestamp,
    this.distanceToUser,
  });
}

class ChileTransitService {
  ChileTransitService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _userAgent = 'CellSay Ruta/1.0 (+https://cellsay.cl)';
  static const _sources = [
    (
      'https://gtfs.red.cl/vehiclePositions?format=json',
      TransitMode.bus,
      'Red (Micro)',
    ),
    (
      'https://www.metro.cl/gtfs-rt/vehiclePositions.pb?format=json',
      TransitMode.metro,
      'Metro de Santiago',
    ),
    (
      'https://api.xor.cl/micro/vehiclePositions?format=json',
      TransitMode.train,
      'MetroTren / buses rurales',
    ),
  ];

  Future<List<TransitVehicle>> fetchVehicles({required LatLng userPosition, double radiusMeters = 2000}) async {
    final futures = _sources.map((source) => _download(source, userPosition, radiusMeters));
    final results = await Future.wait(futures, eagerError: false);
    return results.expand((v) => v).toList()
      ..sort((a, b) => (a.distanceToUser ?? double.infinity).compareTo(b.distanceToUser ?? double.infinity));
  }

  Future<List<TransitVehicle>> _download(
    (String url, TransitMode mode, String provider) source,
    LatLng user,
    double radius,
  ) async {
    final uri = Uri.parse(source.$1);
    final resp = await _client.get(uri, headers: const {'User-Agent': _userAgent});
    if (resp.statusCode != 200) {
      return [];
    }
    final dynamic body = jsonDecode(resp.body);
    final entities = body is Map ? body['entity'] : body;
    if (entities is! List) return [];
    final List<TransitVehicle> parsed = [];
    for (final entity in entities) {
      final vehicle = entity['vehicle'] ?? entity['tripUpdate'];
      final position = vehicle?['position'] ?? entity['position'];
      if (position == null) continue;
      final lat = (position['latitude'] as num?)?.toDouble();
      final lon = (position['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final distance = Geolocator.distanceBetween(user.latitude, user.longitude, lat, lon);
      if (distance > radius) continue;
      final id = (vehicle?['vehicle']?['id'] ?? entity['id'] ?? 'vehiculo').toString();
      final bearing = (position['bearing'] as num?)?.toDouble();
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        ((vehicle?['timestamp'] ?? entity['timestamp'] ?? 0) as num).toInt() * 1000,
        isUtc: true,
      );
      final route = (vehicle?['trip']?['route_id'] ?? vehicle?['trip']?['trip_id'] ?? '').toString();
      parsed.add(
        TransitVehicle(
          id: id,
          mode: source.$2,
          lineName: route.isEmpty ? 'Servicio' : route,
          position: LatLng(lat, lon),
          provider: source.$3,
          bearing: bearing,
          timestamp: timestamp.millisecondsSinceEpoch == 0 ? null : timestamp,
          distanceToUser: distance,
        ),
      );
    }
    return parsed;
  }
}
