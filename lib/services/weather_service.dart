import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Represents simplified weather information for accessibility feedback.
class WeatherInfo {
  WeatherInfo({
    required this.temperatureC,
    this.windSpeed,
    this.description,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  final double temperatureC;
  final double? windSpeed;
  final String? description;
  final DateTime fetchedAt;

  String formatSummary() {
    final roundedTemp = temperatureC.toStringAsFixed(1);
    final wind = windSpeed != null ? ', viento ${windSpeed!.toStringAsFixed(1)} m/s' : '';
    final desc = description != null ? ' - ${description!}' : '';
    return '$roundedTemp°C$wind$desc';
  }
}

/// Service that fetches weather data using the public Open-Meteo API.
class WeatherService {
  WeatherService({http.Client? client, GeolocatorPlatform? geolocator})
      : _client = client ?? http.Client(),
        _geolocator = geolocator ?? GeolocatorPlatform.instance;

  static const double _kDefaultLatitude = -33.4489; // Santiago, Chile.
  static const double _kDefaultLongitude = -70.6693;

  final http.Client _client;
  final GeolocatorPlatform _geolocator;

  double _latitude = _kDefaultLatitude;
  double _longitude = _kDefaultLongitude;
  bool _hasResolvedLocation = false;

  void setCoordinates(double latitude, double longitude) {
    _latitude = latitude;
    _longitude = longitude;
    _hasResolvedLocation = true;
  }

  Future<WeatherInfo?> loadCurrentWeather() async {
    await _ensureCoordinates();

    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast?latitude=$_latitude&longitude=$_longitude&current_weather=true',
    );

    try {
      final response = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final current = data['current_weather'];
      if (current is! Map<String, dynamic>) {
        return null;
      }

      final temp = _toDouble(current['temperature']);
      if (temp == null) {
        return null;
      }
      final wind = _toDouble(current['windspeed']);
      final weatherCode = current['weathercode'];
      final description = _mapWeatherCode(weatherCode);

      return WeatherInfo(
        temperatureC: temp,
        windSpeed: wind,
        description: description,
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _client.close();
  }

  Future<void> _ensureCoordinates() async {
    if (_hasResolvedLocation) return;
    _hasResolvedLocation = true;

    try {
      final serviceEnabled = await _geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      LocationPermission permission = await _geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await _geolocator.getCurrentPosition();
      _latitude = position.latitude;
      _longitude = position.longitude;
    } catch (_) {
      _latitude = _kDefaultLatitude;
      _longitude = _kDefaultLongitude;
    }
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  String? _mapWeatherCode(dynamic code) {
    if (code is! num) return null;
    final value = code.toInt();
    if (value == 0) return 'cielo despejado';
    if (value <= 3) return 'parcialmente nublado';
    if (value <= 48) return 'niebla ligera';
    if (value <= 55) return 'llovizna';
    if (value <= 65) return 'lluvia moderada';
    if (value <= 67) return 'lluvia helada';
    if (value <= 75) return 'nieve';
    if (value <= 82) return 'lluvia intensa';
    if (value <= 95) return 'tormenta';
    return 'condiciones severas';
  }
}
