import 'dart:math';
import 'dart:ui';
import 'package:ultralytics_yolo/models/yolo_result.dart';
import '../core/vision/detection_geometry.dart';
import '../core/vision/cartel_labels.dart';
import '../models/detection_insight.dart';

Rect _normalizeRect(Rect rect) {
  final left = min(rect.left, rect.right);
  final right = max(rect.left, rect.right);
  final top = min(rect.top, rect.bottom);
  final bottom = max(rect.top, rect.bottom);
  return Rect.fromLTRB(left, top, right, bottom);
}

String _normalizeLabel(String label) => label.trim().toLowerCase();

/// Applies additional post processing to YOLO detections improving NMS
/// and extracting semantic information useful for voice feedback.
class DetectionPostProcessor {
  DetectionPostProcessor({
    double iouThreshold = 0.45,
    double closeObstacleAreaThreshold = 0.22,
  })  : _iouThreshold = iouThreshold,
        _closeObstacleAreaThreshold = closeObstacleAreaThreshold;

  final List<_TrackedDetection> _previousDetections = <_TrackedDetection>[];
  double _iouThreshold;
  double _closeObstacleAreaThreshold;

  void updateThresholds({double? iouThreshold, double? closeObstacleAreaThreshold}) {
    if (iouThreshold != null) {
      _iouThreshold = iouThreshold.clamp(0.05, 0.95);
    }
    if (closeObstacleAreaThreshold != null) {
      _closeObstacleAreaThreshold = closeObstacleAreaThreshold.clamp(0.05, 0.9);
    }
  }

  void clearHistory() {
    _previousDetections.clear();
  }

  ProcessedDetections process(List<YOLOResult> rawResults) {
    if (rawResults.isEmpty) {
      _previousDetections.clear();
      return ProcessedDetections.empty;
    }

    final candidates = <_DetectionCandidate>[];
    for (final result in rawResults) {
      try {
        candidates.add(_DetectionCandidate.fromResult(result));
      } catch (_) {
        // Ignore malformed detections that cannot be converted.
      }
    }

    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));

    final selected = <_DetectionCandidate>[];
    final closeObstacles = <String>[];
    final movementWarnings = <String>[];
    TrafficLightSignal trafficSignal = TrafficLightSignal.unknown;

    for (final candidate in candidates) {
      bool shouldSelect = true;
      for (final kept in selected) {
        final iou = _computeIoU(kept.boundingBox, candidate.boundingBox);
        final sameLabel =
            kept.normalizedLabel == candidate.normalizedLabel;
        if ((sameLabel &&
                _shouldSuppressDuplicate(kept, candidate, iou: iou)) ||
            // Guard against duplicate boxes emitted with different labels
            // by rejecting near-identical overlaps.
            iou >= 0.99) {
          shouldSelect = false;
          break;
        }
      }

      if (!shouldSelect) continue;
      selected.add(candidate);

      if (candidate.normalizedArea >= _closeObstacleAreaThreshold &&
          !isCartelLabel(candidate.label)) {
        closeObstacles.add(candidate.label);
      }

      final movementWarning = _detectMovement(candidate);
      if (movementWarning != null) {
        movementWarnings.add(movementWarning);
      }

      trafficSignal = _mergeTrafficSignal(trafficSignal, candidate.trafficLightSignal);
    }

    _updateHistory(selected);

    return ProcessedDetections(
      filteredResults: selected.map((e) => e.original).toList(),
      closeObstacleLabels: closeObstacles,
      trafficLightSignal: trafficSignal,
      movementWarnings: movementWarnings,
    );
  }

  void _updateHistory(List<_DetectionCandidate> selected) {
    _previousDetections
      ..clear()
      ..addAll(selected.map(_TrackedDetection.fromCandidate));
  }

  String? _detectMovement(_DetectionCandidate candidate) {
    final previous = _previousDetections.where(
      (tracked) => tracked.normalizedLabel == candidate.normalizedLabel,
    );

    _TrackedDetection? bestMatch;
    double bestIoU = 0;
    for (final tracked in previous) {
      final iou = _computeIoU(tracked.boundingBox, candidate.boundingBox);
      if (iou > bestIoU) {
        bestIoU = iou;
        bestMatch = tracked;
      }
    }

    if (bestMatch == null || bestIoU < 0.2) {
      return null;
    }

    final growth = candidate.normalizedArea / (bestMatch.normalizedArea + 1e-6);
    final approaching = candidate.boundingBox.center.dy < bestMatch.boundingBox.center.dy + 0.05;

    if (growth > 1.6 && approaching) {
      return '${candidate.label} acercándose rápidamente';
    }
    return null;
  }

  TrafficLightSignal _mergeTrafficSignal(
    TrafficLightSignal current,
    TrafficLightSignal candidate,
  ) {
    if (candidate == TrafficLightSignal.unknown) return current;
    if (current == TrafficLightSignal.unknown) return candidate;
    if (current == candidate) return current;
    // Prefer red over green in case of conflict for safety.
    return TrafficLightSignal.red;
  }

  double _computeIoU(Rect a, Rect b) {
    final rectA = _normalizeRect(a);
    final rectB = _normalizeRect(b);
    final intersection = rectA.intersect(rectB);
    final intersectionArea =
        max(0.0, intersection.width) * max(0.0, intersection.height);
    final areaA = max(0.0, rectA.width) * max(0.0, rectA.height);
    final areaB = max(0.0, rectB.width) * max(0.0, rectB.height);
    final union = areaA + areaB - intersectionArea + 1e-6;
    return union <= 0 ? 0 : intersectionArea / union;
  }

  bool _shouldSuppressDuplicate(
    _DetectionCandidate kept,
    _DetectionCandidate candidate, {
    required double iou,
  }) {
    if (iou >= _iouThreshold) {
      return true;
    }

    final coverage = _computeCoverageFraction(
      kept.boundingBox,
      candidate.boundingBox,
    );

    if (coverage >= 0.9) {
      return true;
    }

    if (coverage >= 0.75) {
      final Offset delta = kept.boundingBox.center - candidate.boundingBox.center;
      final double distance = sqrt(delta.dx * delta.dx + delta.dy * delta.dy);
      final double reference = min(
        _rectDiagonal(kept.boundingBox),
        _rectDiagonal(candidate.boundingBox),
      );
      if (reference > 0 && distance <= reference * 0.2) {
        return true;
      }
    }

    return false;
  }

  double _computeCoverageFraction(Rect a, Rect b) {
    final rectA = _normalizeRect(a);
    final rectB = _normalizeRect(b);
    final intersection = rectA.intersect(rectB);
    final intersectionArea =
        max(0.0, intersection.width) * max(0.0, intersection.height);
    if (intersectionArea <= 0) {
      return 0.0;
    }

    final areaA = max(0.0, rectA.width) * max(0.0, rectA.height);
    final areaB = max(0.0, rectB.width) * max(0.0, rectB.height);
    final minArea = max(1e-6, min(areaA, areaB));
    return intersectionArea / minArea;
  }

  double _rectDiagonal(Rect rect) {
    final normalized = _normalizeRect(rect);
    final width = max(0.0, normalized.width);
    final height = max(0.0, normalized.height);
    return sqrt(width * width + height * height);
  }
}

class _DetectionCandidate {
  _DetectionCandidate._({
    required this.original,
    required this.boundingBox,
    required this.confidence,
    required this.label,
    required this.normalizedLabel,
    required this.normalizedArea,
    required this.trafficLightSignal,
  });

  factory _DetectionCandidate({
    required YOLOResult original,
    required Rect boundingBox,
    required double confidence,
    required String label,
    required String normalizedLabel,
    required TrafficLightSignal trafficLightSignal,
  }) {
    final normalizedBox = _normalizeRect(boundingBox);
    final area =
        max(0.0, normalizedBox.width) * max(0.0, normalizedBox.height);
    return _DetectionCandidate._(
      original: original,
      boundingBox: normalizedBox,
      confidence: confidence,
      label: label,
      normalizedLabel: normalizedLabel,
      normalizedArea: area,
      trafficLightSignal: trafficLightSignal,
    );
  }

  final YOLOResult original;
  final Rect boundingBox;
  final double confidence;
  final String label;
  final String normalizedLabel;
  final double normalizedArea;
  final TrafficLightSignal trafficLightSignal;

  factory _DetectionCandidate.fromResult(YOLOResult result) {
    final rect = extractBoundingBox(result);
    final confidence = extractConfidence(result) ?? 0.0;
    final label = extractLabel(result);
    final normalizedLabel = _normalizeLabel(label);
    final signal = _inferTrafficLightSignal(result, label);

    if (rect == null) {
      throw ArgumentError('Detection without bounding box');
    }

    return _DetectionCandidate(
      original: result,
      boundingBox: rect,
      confidence: confidence,
      label: label,
      normalizedLabel: normalizedLabel,
      trafficLightSignal: signal,
    );
  }
}

class _TrackedDetection {
  _TrackedDetection({
    required this.label,
    required this.normalizedLabel,
    required this.boundingBox,
    required this.normalizedArea,
  });

  final String label;
  final String normalizedLabel;
  final Rect boundingBox;
  final double normalizedArea;

  factory _TrackedDetection.fromCandidate(_DetectionCandidate candidate) {
    return _TrackedDetection(
      label: candidate.label,
      normalizedLabel: candidate.normalizedLabel,
      boundingBox: candidate.boundingBox,
      normalizedArea: candidate.normalizedArea,
    );
  }
}

TrafficLightSignal _inferTrafficLightSignal(YOLOResult result, String label) {
  final normalizedLabel = label.toLowerCase();
  if (normalizedLabel.contains('semaforo') || normalizedLabel.contains('traffic')) {
    if (normalizedLabel.contains('red') || normalizedLabel.contains('rojo')) {
      return TrafficLightSignal.red;
    }
    if (normalizedLabel.contains('green') || normalizedLabel.contains('verde')) {
      return TrafficLightSignal.green;
    }
  }

  final dynamic dynamicResult = result;
  try {
    final colorValue = dynamicResult.color;
    final colorString = colorValue?.toString().toLowerCase();
    if (colorString != null) {
      if (colorString.contains('red') || colorString.contains('rojo')) {
        return TrafficLightSignal.red;
      }
      if (colorString.contains('green') || colorString.contains('verde')) {
        return TrafficLightSignal.green;
      }
    }
  } catch (_) {}

  final map = _mapRepresentation(dynamicResult);
  if (map != null) {
    final colorString = map['color']?.toString().toLowerCase();
    if (colorString != null) {
      if (colorString.contains('red') || colorString.contains('rojo')) {
        return TrafficLightSignal.red;
      }
      if (colorString.contains('green') || colorString.contains('verde')) {
        return TrafficLightSignal.green;
      }
    }
  }

  return TrafficLightSignal.unknown;
}

Map<String, dynamic>? _mapRepresentation(dynamic value) {
  try {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, dynamic val) => MapEntry('$key', val));
    }
    final jsonValue = value?.toJson();
    if (jsonValue is Map) {
      return jsonValue.map((key, dynamic val) => MapEntry('$key', val));
    }
  } catch (_) {}
  return null;
}
