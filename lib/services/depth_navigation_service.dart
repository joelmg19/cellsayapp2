import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/models/yolo_result.dart';

import '../core/vision/detection_geometry.dart';
import '../models/depth_navigation.dart';
import 'depth_anything_processor.dart';

class DepthNavigationService {
  DepthNavigationService({DepthAnythingProcessor? processor})
      : _processor = processor;

  DepthAnythingProcessor? _processor;
  Future<DepthAnythingProcessor>? _initializing;

  Future<DepthNavigationResult?> processDetections({
    required List<YOLOResult> detections,
    Uint8List? imageBytes,
    img.Image? decodedImage,
  }) async {
    if (detections.isEmpty) {
      return null;
    }

    final img.Image? image = decodedImage ??
        (imageBytes != null ? img.decodeImage(imageBytes) : null);
    if (image == null || image.width <= 0 || image.height <= 0) {
      return null;
    }

    final processor = await _ensureProcessor();
    DepthAnythingResult? depthResult;
    try {
      final analysis = await processor.estimate(decodedImage: image);
      depthResult = analysis?.depth;
    } catch (error, stackTrace) {
      debugPrint('DepthNavigation: depth estimation failed: $error');
      debugPrint('$stackTrace');
    }

    return _buildNavigation(
      detections,
      depthResult,
      image.width,
      image.height,
    );
  }

  void dispose() {
    _processor?.close();
    _processor = null;
  }

  Future<DepthAnythingProcessor> _ensureProcessor() async {
    final existing = _processor;
    if (existing != null) {
      return existing;
    }
    final loading = _initializing;
    if (loading != null) {
      return loading;
    }
    final future = DepthAnythingProcessor.create();
    _initializing = future;
    final processor = await future;
    _initializing = null;
    _processor = processor;
    return processor;
  }

  DepthNavigationResult _buildNavigation(
    List<YOLOResult> detections,
    DepthAnythingResult? depth,
    int viewWidth,
    int viewHeight,
  ) {
    final obstacles = _buildObstacles(detections, depth, viewWidth, viewHeight);
    final instruction = _decideInstruction(obstacles);
    final usedDepth =
        depth != null && obstacles.any((obstacle) => obstacle.distanceMeters != null);
    return DepthNavigationResult(
      instruction: instruction,
      obstacles: obstacles,
      usedDepth: usedDepth,
    );
  }

  List<NavigationObstacle> _buildObstacles(
    List<YOLOResult> detections,
    DepthAnythingResult? depth,
    int viewWidth,
    int viewHeight,
  ) {
    if (viewWidth <= 0 || viewHeight <= 0) {
      return const <NavigationObstacle>[];
    }

    final obstacles = <NavigationObstacle>[];
    for (final detection in detections) {
      final rect = extractBoundingBox(detection);
      if (rect == null) {
        continue;
      }

      final clamped = _clampRect(rect, viewWidth, viewHeight);
      final label = extractLabel(detection);
      final distance = depth?.metersForBox(clamped, viewWidth, viewHeight);
      final approximate =
          distance == null && _approximateClose(clamped, viewWidth, viewHeight);

      obstacles.add(
        NavigationObstacle(
          label: label,
          sector: _sectorOf(clamped, viewWidth),
          distanceMeters: distance,
          isApproximate: approximate,
        ),
      );
    }
    return obstacles;
  }

  Rect _clampRect(Rect rect, int width, int height) {
    final left = rect.left.clamp(0.0, width.toDouble()).toDouble();
    final top = rect.top.clamp(0.0, height.toDouble()).toDouble();
    final right = rect.right.clamp(left + 1.0, width.toDouble()).toDouble();
    final bottom = rect.bottom.clamp(top + 1.0, height.toDouble()).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  NavigationSector _sectorOf(Rect rect, int viewWidth) {
    if (viewWidth <= 0) {
      return NavigationSector.center;
    }
    final width = viewWidth.toDouble();
    final centerX = (rect.left + rect.right) / 2.0;
    final third = width / 3.0;
    if (centerX < third) {
      return NavigationSector.left;
    }
    if (centerX > 2 * third) {
      return NavigationSector.right;
    }
    return NavigationSector.center;
  }

  bool _approximateClose(Rect rect, int viewWidth, int viewHeight) {
    final area = rect.width * rect.height;
    final totalArea = viewWidth.toDouble() * viewHeight.toDouble();
    if (totalArea <= 0) {
      return false;
    }
    final ratio = area / totalArea;
    if (ratio >= 0.15) {
      return true;
    }
    return ratio >= 0.08 && rect.bottom > viewHeight * 0.75;
  }

  String _decideInstruction(
    List<NavigationObstacle> obstacles, {
    double safeMeters = 1.2,
  }) {
    if (obstacles.isEmpty) {
      return 'Sigue derecho';
    }

    final crosswalk = _findCrosswalk(obstacles);
    if (crosswalk != null) {
      return 'Hay un paso de cebra al frente. Avanza para cruzar';
    }

    final center =
        obstacles.where((obstacle) => obstacle.sector == NavigationSector.center).toList();
    final left =
        obstacles.where((obstacle) => obstacle.sector == NavigationSector.left).toList();
    final right =
        obstacles.where((obstacle) => obstacle.sector == NavigationSector.right).toList();

    final centerBlocked = center.any((obstacle) => _isBlocking(obstacle, safeMeters));
    final leftBlocked = left.any((obstacle) => _isBlocking(obstacle, safeMeters));
    final rightBlocked = right.any((obstacle) => _isBlocking(obstacle, safeMeters));

    if (centerBlocked) {
      if (!rightBlocked) {
        return 'Sigue por la derecha';
      }
      if (!leftBlocked) {
        return 'Sigue por la izquierda';
      }
      return 'Alto, hay obstáculos alrededor';
    }

    final caution = _closestObstacle(center);
    if (caution != null) {
      final distance = caution.distanceMeters;
      if (distance != null) {
        final meters = distance.clamp(0.0, 99.9).toStringAsFixed(1);
        return 'Cuidado ${caution.label} al frente a $meters metros';
      }
      if (caution.isApproximate) {
        return 'Cuidado ${caution.label} al frente, muy cerca';
      }
      return 'Cuidado ${caution.label} al frente';
    }

    return 'Sigue derecho';
  }

  NavigationObstacle? _findCrosswalk(List<NavigationObstacle> obstacles) {
    for (final obstacle in obstacles) {
      if (obstacle.label.toLowerCase() == 'crosswalk') {
        return obstacle;
      }
    }
    return null;
  }

  NavigationObstacle? _closestObstacle(List<NavigationObstacle> obstacles) {
    NavigationObstacle? closest;
    var closestDistance = double.infinity;
    for (final obstacle in obstacles) {
      final distance = obstacle.distanceMeters;
      if (distance != null && distance.isFinite) {
        if (distance < closestDistance) {
          closestDistance = distance;
          closest = obstacle;
        }
      } else if (obstacle.isApproximate && closest == null) {
        closest = obstacle;
      }
    }
    return closest;
  }

  bool _isBlocking(NavigationObstacle obstacle, double safeMeters) {
    final distance = obstacle.distanceMeters;
    if (distance != null) {
      return distance <= safeMeters;
    }
    return obstacle.isApproximate;
  }
}
