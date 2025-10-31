import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/models/yolo_result.dart';

import '../core/vision/detection_geometry.dart';
import '../models/depth_navigation.dart';

class DepthNavigationService {
  DepthNavigationService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'navigation/depth';
  final MethodChannel _channel;

  Future<DepthNavigationResult?> processDetections({
    required List<YOLOResult> detections,
    required int imageWidth,
    required int imageHeight,
  }) async {
    if (detections.isEmpty) return null;
    if (imageWidth <= 0 || imageHeight <= 0) return null;

    final serialized = <Map<String, dynamic>>[];
    for (final detection in detections) {
      final map = _serializeDetection(detection, imageWidth: imageWidth, imageHeight: imageHeight);
      if (map != null) serialized.add(map);
    }

    if (serialized.isEmpty) return null;

    try {
      final response = await _channel.invokeMapMethod<String, dynamic>('processDetections', {
        'viewWidth': imageWidth,
        'viewHeight': imageHeight,
        'detections': serialized,
      });
      if (response == null) return null;
      return DepthNavigationResult.fromMap(response);
    } on PlatformException {
      return null;
    }
  }

  Map<String, dynamic>? _serializeDetection(
    YOLOResult result, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final rect = extractBoundingBox(result);
    if (rect == null) return null;

    final label = extractLabel(result);
    final confidence = extractConfidence(result) ?? 0.0;

    double left = rect.left;
    double top = rect.top;
    double right = rect.right;
    double bottom = rect.bottom;

    if (right <= left || bottom <= top) {
      return null;
    }

    // Normalize coordinates when they appear to be expressed in pixels.
    final width = extractImageWidthPx(result) ?? imageWidth;
    final height = extractImageHeightPx(result) ?? imageHeight;
    final usesPixels = max(right, bottom) > 1.0;

    final normalized = <String, double>{
      'left': (usesPixels ? left / width : left).clamp(0.0, 1.0),
      'top': (usesPixels ? top / height : top).clamp(0.0, 1.0),
      'right': (usesPixels ? right / width : right).clamp(0.0, 1.0),
      'bottom': (usesPixels ? bottom / height : bottom).clamp(0.0, 1.0),
    };

    return {
      'label': label,
      'score': confidence,
      'left': usesPixels ? left : left * width,
      'top': usesPixels ? top : top * height,
      'right': usesPixels ? right : right * width,
      'bottom': usesPixels ? bottom : bottom * height,
      'normalized': normalized,
    };
  }
}
