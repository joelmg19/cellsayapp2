import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'distance_estimator.dart';

/// Loads the calibration data from assets and exposes a configured
/// [DistanceEstimator].
class DistanceEstimatorProvider {
  DistanceEstimatorProvider({AssetBundle? bundle})
      : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  DistanceEstimator? _cached;
  Future<DistanceEstimator?>? _loading;

  Future<DistanceEstimator?> load() {
    final cached = _cached;
    if (cached != null) return SynchronousFuture(cached);
    final loading = _loading;
    if (loading != null) return loading;
    final future = _loadInternal();
    _loading = future;
    return future;
  }

  Future<DistanceEstimator?> _loadInternal() async {
    try {
      final jsonString = await _bundle.loadString('assets/config/calibration.json');
      final data = json.decode(jsonString) as Map<String, dynamic>;
      final focalValue = data['focalPx'];
      final focal = _toDouble(focalValue);
      if (focal == null || focal <= 0) {
        debugPrint('DistanceEstimatorProvider: invalid focalPx=$focalValue');
        return null;
      }

      final overrides = <String, double>{};
      final heights = data['realHeightsMeters'];
      if (heights is Map) {
        for (final entry in heights.entries) {
          final key = entry.key.toString();
          final value = _toDouble(entry.value);
          if (value != null && value > 0) {
            overrides[key] = value;
          }
        }
      }

      final estimator = DistanceEstimator(
        focalPx: focal,
        realHeightsOverride: overrides.isEmpty ? null : overrides,
      );
      _cached = estimator;
      return estimator;
    } catch (error, stackTrace) {
      debugPrint('DistanceEstimatorProvider: failed to load calibration - $error');
      debugPrint('$stackTrace');
      return null;
    } finally {
      _loading = null;
    }
  }

  double? _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
