import 'dart:async';
import 'dart:convert';
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
  WeatherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  double _latitude = 19.4326; // Ciudad de México por defecto.
  double _longitude = -99.1332;

  void setCoordinates(double latitude, double longitude) {
    _latitude = latitude;
    _longitude = longitude;
  }

  Future<WeatherInfo?> loadCurrentWeather() async {
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
