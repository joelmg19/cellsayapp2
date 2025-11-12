import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/models/yolo_result.dart';

Rect? extractBoundingBox(YOLOResult result) {
  final dynamic dynamicResult = result;
  Rect? rect;
  rect ??= _rectFromDynamic(() => dynamicResult.box as Rect?);
  rect ??= _rectFromDynamic(() => dynamicResult.boundingBox as Rect?);
  rect ??= _rectFromDynamic(() => dynamicResult.rect as Rect?);
  rect ??= _rectFromDynamic(() => dynamicResult.bbox as Rect?);
  if (rect != null) return rect;

  final map = _mapRepresentation(dynamicResult);
  if (map == null) return null;

  final left = _toDouble(map['left'] ?? map['x']);
  final top = _toDouble(map['top'] ?? map['y']);
  final right = _toDouble(map['right']);
  final bottom = _toDouble(map['bottom']);
  final width = _toDouble(map['width']);
  final height = _toDouble(map['height']);

  if ([left, top, right, bottom].every((value) => value != null)) {
    return Rect.fromLTRB(left!, top!, right!, bottom!);
  }
  if (left != null && top != null && width != null && height != null) {
    return Rect.fromLTWH(left, top, width, height);
  }
  return null;
}

String extractLabel(YOLOResult result, {String fallback = 'objeto'}) {
  try {
    final label = (result.className as String?)?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
  } catch (_) {}

  final map = _mapRepresentation(result);
  final mappedLabel = map?['className'] ?? map?['label'];
  if (mappedLabel is String && mappedLabel.trim().isNotEmpty) {
    return mappedLabel.trim();
  }
  return fallback;
}

int? extractImageHeightPx(YOLOResult result) {
  final dynamic dynamicResult = result;
  final candidates = <dynamic?>[
    _tryValue(() => dynamicResult.imageHeight),
    _tryValue(() => dynamicResult.imageHeightPx),
    _tryValue(() => dynamicResult.sourceHeight),
    _tryValue(() => dynamicResult.frameHeight),
    _tryValue(() => dynamicResult.inputHeight),
    _tryValue(() => dynamicResult.imageSize),
    _tryValue(() => dynamicResult.imageShape),
    _tryValue(() => dynamicResult.inputShape),
    _tryValue(() => dynamicResult.originalSize),
    _tryValue(() => dynamicResult.originalShape),
  ];

  final map = _mapRepresentation(dynamicResult);
  if (map != null) {
    const keys = [
      'imageHeight',
      'image_height',
      'imageHeightPx',
      'inputHeight',
      'input_height',
      'imageShape',
      'image_shape',
      'inputShape',
      'input_shape',
      'originalSize',
      'original_size',
      'originalShape',
      'original_shape',
      'sourceHeight',
      'frameHeight',
    ];
    for (final key in keys) {
      candidates.add(map[key]);
    }
    final imageSize = map['imageSize'] ?? map['image_size'];
    candidates.add(imageSize);
  }

  for (final candidate in candidates) {
    final value = _dimensionCandidateToDouble(candidate, isHeight: true);
    if (value != null && value > 1) {
      return value.round();
    }
  }
  return null;
}

// --- INICIO DE MODIFICACIÓN --- (NUEVA FUNCIÓN)
int? extractImageWidthPx(YOLOResult result) {
  final dynamic dynamicResult = result;
  final candidates = <dynamic?>[
    _tryValue(() => dynamicResult.imageWidth),
    _tryValue(() => dynamicResult.imageWidthPx),
    _tryValue(() => dynamicResult.sourceWidth),
    _tryValue(() => dynamicResult.frameWidth),
    _tryValue(() => dynamicResult.inputWidth),
    _tryValue(() => dynamicResult.imageSize),
    _tryValue(() => dynamicResult.imageShape),
    _tryValue(() => dynamicResult.inputShape),
    _tryValue(() => dynamicResult.originalSize),
    _tryValue(() => dynamicResult.originalShape),
  ];

  final map = _mapRepresentation(dynamicResult);
  if (map != null) {
    const keys = [
      'imageWidth',
      'image_width',
      'imageWidthPx',
      'inputWidth',
      'input_width',
      'imageShape',
      'image_shape',
      'inputShape',
      'input_shape',
      'originalSize',
      'original_size',
      'originalShape',
      'original_shape',
      'sourceWidth',
      'frameWidth',
    ];
    for (final key in keys) {
      candidates.add(map[key]);
    }
    final imageSize = map['imageSize'] ?? map['image_size'];
    candidates.add(imageSize);
  }

  for (final candidate in candidates) {
    final value = _dimensionCandidateToDouble(candidate, isHeight: false);
    if (value != null && value > 1) {
      return value.round();
    }
  }
  return null;
}
// --- FIN DE MODIFICACIÓN ---

double? extractConfidence(YOLOResult result) {
  final dynamic dynamicResult = result;
  try {
    final value = dynamicResult.confidence;
    return _toDouble(value);
  } catch (_) {}
  try {
    final value = dynamicResult.score;
    return _toDouble(value);
  } catch (_) {}

  final map = _mapRepresentation(dynamicResult);
  if (map != null) {
    return _toDouble(map['confidence'] ?? map['score']);
  }
  return null;
}

Rect? _rectFromDynamic(Rect? Function() getter) {
  try {
    return getter();
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _mapRepresentation(dynamic value) {
  try {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry('$key', val));
    }
    final jsonValue = value?.toJson();
    if (jsonValue is Map) {
      return jsonValue.map((key, val) => MapEntry('$key', val));
    }
  } catch (_) {}
  return null;
}

double? _toDouble(dynamic value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

dynamic _tryValue(dynamic Function() getter) {
  try {
    return getter();
  } catch (_) {
    return null;
  }
}

// --- INICIO DE MODIFICACIÓN --- (FUNCIÓN ACTUALIZADA)
double? _dimensionCandidateToDouble(dynamic candidate, {required bool isHeight}) {
  if (candidate == null) return null;
  if (candidate is num) return candidate.toDouble();
  if (candidate is String) return double.tryParse(candidate);
  if (candidate is List) {
    if (candidate.isEmpty) return null;
    // Para 'shape' (alto, ancho), toma el índice correcto
    if (candidate.length > 1) {
      final val = isHeight ? candidate[0] : candidate[1];
      final parsed = _dimensionCandidateToDouble(val, isHeight: isHeight);
      if (parsed != null) return parsed;
    }
    // Para otros listados, busca recursivamente
    for (final value in candidate) {
      final parsed = _dimensionCandidateToDouble(value, isHeight: isHeight);
      if (parsed != null) return parsed;
    }
    return null;
  }
  if (candidate is Map) {
    final keys = isHeight ? ['height', 'h', 'rows'] : ['width', 'w', 'cols'];
    for (final key in keys) {
      final parsed = _dimensionCandidateToDouble(candidate[key], isHeight: isHeight);
      if (parsed != null) return parsed;
    }
  }
  if (candidate is Size) {
    return isHeight ? candidate.height : candidate.width;
  }
  if (candidate is Rect) {
    return isHeight ? candidate.height : candidate.width;
  }
  return null;
}
// --- FIN DE MODIFICACIÓN ---

/// Utility to clamp bounding boxes to a sensible range for debugging purposes.
Rect clampRect(Rect rect) {
  final left = rect.left.clamp(0.0, 1.0).toDouble();
  final top = rect.top.clamp(0.0, 1.0).toDouble();
  final right = rect.right.clamp(0.0, max(1.0, rect.right)).toDouble();
  final bottom = rect.bottom.clamp(0.0, max(1.0, rect.bottom)).toDouble();
  return Rect.fromLTRB(left, top, right, bottom);
}