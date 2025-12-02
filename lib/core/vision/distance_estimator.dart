import 'package:flutter/foundation.dart';

/// Estimates real-world distance for detected objects using the pinhole camera
/// model. The estimator assumes bounding boxes are normalized to [0, 1] with
/// respect to the model input frame.
class DistanceEstimator {
  DistanceEstimator({
    required this.focalPx,
    Map<String, double>? realHeightsOverride,
  }) : realHeightsMeters = {
          'person': 1.7,
          'bottle': 0.25,
          'cup': 0.10,
          ...?realHeightsOverride,
        };

  /// Calibrated focal length expressed in pixels.
  final double focalPx;

  /// Map of known object heights (in metres) keyed by detection label.
  final Map<String, double> realHeightsMeters;

  /// Computes the estimated distance in metres for a detection.
  ///
  /// Returns `null` if the class has no known height, the bounding box is
  /// invalid, or the resulting distance is not finite.
  double? distanceMeters({
    required String detectedClass,
    required double bboxHeightRelative,
    required int imageHeightPx,
  }) {
    if (bboxHeightRelative.isNaN || bboxHeightRelative.isInfinite) {
      return null;
    }
    final realHeight = realHeightsMeters[detectedClass];
    if (realHeight == null) return null;
    if (imageHeightPx <= 1) return null;

    final clampedRelative = bboxHeightRelative.clamp(0.0, 1.0);
    final bboxHeightPx = clampedRelative * imageHeightPx;
    if (bboxHeightPx <= 1) return null;

    final distance = (realHeight * focalPx) / bboxHeightPx;
    if (distance.isNaN || distance.isInfinite || distance <= 0) {
      return null;
    }
    return distance;
  }

  /// Convenience helper for logging.
  @visibleForTesting
  double computeDistanceForPixels({
    required String detectedClass,
    required double bboxHeightPx,
  }) {
    final realHeight = realHeightsMeters[detectedClass];
    if (realHeight == null || bboxHeightPx <= 1) return double.nan;
    return (realHeight * focalPx) / bboxHeightPx;
  }
}
