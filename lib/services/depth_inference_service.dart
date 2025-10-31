import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Represents a single depth map prediction from the depth model.
///
/// The [data] buffer stores raw depth predictions in row-major order with a
/// length of [width] * [height]. The values are kept as floating point numbers
/// regardless of the underlying model precision to simplify downstream
/// processing.
class DepthFrame {
  DepthFrame({
    required this.width,
    required this.height,
    required this.data,
    required this.minValue,
    required this.maxValue,
    required this.minDistanceMeters,
    required this.maxDistanceMeters,
    this.sampleStep = 2,
  });

  final int width;
  final int height;
  final Float32List data;
  final double minValue;
  final double maxValue;
  final double minDistanceMeters;
  final double maxDistanceMeters;
  final int sampleStep;

  bool get isValidRange => maxValue > minValue && width > 0 && height > 0;

  /// Returns the raw depth value at the provided coordinates.
  double? valueAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return null;
    }
    final value = data[y * width + x];
    if (value.isNaN || value.isInfinite) {
      return null;
    }
    return value;
  }

  /// Computes the average raw depth value inside a normalized bounding box.
  double? averageRawDepth(Rect normalizedBox) {
    if (!isValidRange) return null;

    final leftPx = (normalizedBox.left.clamp(0.0, 1.0) * width).floor();
    final topPx = (normalizedBox.top.clamp(0.0, 1.0) * height).floor();
    final rightPx = (normalizedBox.right.clamp(0.0, 1.0) * width).ceil();
    final bottomPx = (normalizedBox.bottom.clamp(0.0, 1.0) * height).ceil();

    final clampedLeft = max(0, min(width - 1, leftPx));
    final clampedTop = max(0, min(height - 1, topPx));
    final clampedRight = max(clampedLeft + 1, min(width, rightPx));
    final clampedBottom = max(clampedTop + 1, min(height, bottomPx));

    double sum = 0;
    int count = 0;

    for (int y = clampedTop; y < clampedBottom; y += sampleStep) {
      for (int x = clampedLeft; x < clampedRight; x += sampleStep) {
        final value = this.valueAt(x, y);
        if (value == null) continue;
        sum += value;
        count++;
      }
    }

    if (count == 0) return null;
    return sum / count;
  }

  /// Converts a raw depth value into an estimated physical distance.
  double? convertRawToDistance(double rawValue) {
    if (!isValidRange) return null;
    final normalized = ((rawValue - minValue) / (maxValue - minValue))
        .clamp(0.0, 1.0);
    if (normalized.isNaN || normalized.isInfinite) {
      return null;
    }
    final distance =
        minDistanceMeters + normalized * (maxDistanceMeters - minDistanceMeters);
    if (distance.isNaN || distance.isInfinite) {
      return null;
    }
    return distance;
  }

  /// Estimates a distance in metres for a detection using the depth map.
  double? estimateDistance(Rect normalizedBox) {
    final raw = averageRawDepth(normalizedBox);
    if (raw == null) return null;
    return convertRawToDistance(raw);
  }
}

/// Service responsible for running the depth Anything TFLite model.
class DepthInferenceService {
  DepthInferenceService({
    this.modelAssetPath = 'assets/models/depth_anything.tflite',
    this.sampleStep = 2,
    this.minDistanceMeters = 0.3,
    this.maxDistanceMeters = 8.0,
  });

  final String modelAssetPath;
  final int sampleStep;
  final double minDistanceMeters;
  final double maxDistanceMeters;

  Interpreter? _interpreter;
  List<int>? _inputShape;
  List<int>? _outputShape;
  TfLiteType? _inputType;
  TfLiteType? _outputType;
  bool _isProcessing = false;
  bool _initializationAttempted = false;

  bool get isInitialized => _interpreter != null;

  Future<void> initialize() async {
    if (_interpreter != null || _initializationAttempted) return;
    _initializationAttempted = true;

    try {
      final options = InterpreterOptions()
        ..threads = Platform.isAndroid ? 4 : 2;
      final modelData = await rootBundle.load(modelAssetPath);
      _interpreter = await Interpreter.fromBuffer(
        modelData.buffer.asUint8List(),
        options: options,
      );
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);
      _inputShape = inputTensor.shape;
      _outputShape = outputTensor.shape;
      _inputType = inputTensor.type;
      _outputType = outputTensor.type;
    } catch (error, stackTrace) {
      debugPrint('DepthInferenceService: failed to initialize model - $error');
      debugPrint('$stackTrace');
      _interpreter?.close();
      _interpreter = null;
      _initializationAttempted = false;
    }
  }

  Future<void> dispose() async {
    _interpreter?.close();
    _interpreter = null;
  }

  Future<DepthFrame?> estimateDepth(Uint8List imageBytes) async {
    if (_interpreter == null) {
      await initialize();
      if (_interpreter == null) {
        return null;
      }
    }

    if (_isProcessing) return null;
    _isProcessing = true;
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) {
        debugPrint('DepthInferenceService: unable to decode image');
        return null;
      }

      final inputShape = _inputShape ?? _interpreter!.getInputTensor(0).shape;
      final targetHeight = _dimensionFromShape(inputShape, axisFromEnd: 3);
      final targetWidth = _dimensionFromShape(inputShape, axisFromEnd: 2);
      final targetChannels = _dimensionFromShape(inputShape, axisFromEnd: 1);

      final resized = img.copyResize(
        decoded,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear,
      );

      final input = _prepareInputTensor(
        resized,
        targetChannels,
        _inputType ?? TfLiteType.float32,
      );

      final outputContainer = _createOutputContainer();
      _interpreter!.run(input, outputContainer);

      final parsed = _parseOutput(outputContainer);
      if (parsed == null) return null;

      return DepthFrame(
        width: parsed.width,
        height: parsed.height,
        data: parsed.buffer,
        minValue: parsed.minValue,
        maxValue: parsed.maxValue,
        minDistanceMeters: minDistanceMeters,
        maxDistanceMeters: maxDistanceMeters,
        sampleStep: sampleStep,
      );
    } catch (error, stackTrace) {
      debugPrint('DepthInferenceService: estimation error - $error');
      debugPrint('$stackTrace');
      return null;
    } finally {
      _isProcessing = false;
    }
  }

  int _dimensionFromShape(List<int> shape, {required int axisFromEnd}) {
    if (shape.isEmpty) return 1;
    final index = shape.length - axisFromEnd;
    if (index < 0 || index >= shape.length) {
      return shape.isNotEmpty ? shape.last : 1;
    }
    return shape[index];
  }

  dynamic _prepareInputTensor(
    img.Image image,
    int channels,
    TfLiteType inputType,
  ) {
    final height = image.height;
    final width = image.width;

    dynamic channelValues(int pixel) {
      final r = img.getRed(pixel);
      final g = img.getGreen(pixel);
      final b = img.getBlue(pixel);
      if (channels <= 1) {
        final luminance = img.getLuminanceRgb(r, g, b);
        return [luminance];
      }
      if (inputType == TfLiteType.float32) {
        return [r / 255.0, g / 255.0, b / 255.0];
      }
      return [r, g, b];
    }

    final result = List.generate(
      1,
      (_) => List.generate(height, (y) {
        return List.generate(width, (x) {
          final pixel = image.getPixel(x, y);
          final values = channelValues(pixel);
          if (inputType == TfLiteType.float32) {
            return values.map((value) {
              if (value is num) {
                return value.toDouble();
              }
              return 0.0;
            }).toList(growable: false);
          }
          return values.map((value) {
            if (value is num) {
              return value.toInt();
            }
            return 0;
          }).toList(growable: false);
        }).toList(growable: false);
      }).toList(growable: false),
    );

    return result;
  }

  List<dynamic> _createOutputContainer() {
    final outputShape = _outputShape ?? _interpreter!.getOutputTensor(0).shape;
    final height = _dimensionFromShape(outputShape, axisFromEnd: 3);
    final width = _dimensionFromShape(outputShape, axisFromEnd: 2);
    final channels = _dimensionFromShape(outputShape, axisFromEnd: 1);

    return [
      List.generate(height, (_) {
        return List.generate(width, (_) {
          if ((_outputType ?? TfLiteType.float32) == TfLiteType.float32) {
            if (channels <= 1) {
              return [0.0];
            }
            return List<double>.filled(channels, 0.0);
          }
          if (channels <= 1) {
            return [0];
          }
          return List<int>.filled(channels, 0);
        });
      }),
    ];
  }

  _ParsedDepthOutput? _parseOutput(List<dynamic> outputContainer) {
    if (outputContainer.isEmpty) return null;
    final rawOutput = outputContainer.first;
    if (rawOutput is! List) return null;
    final height = rawOutput.length;
    if (height == 0) return null;

    final firstRow = rawOutput.first;
    if (firstRow is! List) return null;
    final width = firstRow.length;
    if (width == 0) return null;

    final buffer = Float32List(height * width);
    double minValue = double.infinity;
    double maxValue = -double.infinity;

    for (int y = 0; y < height; y++) {
      final row = rawOutput[y];
      if (row is! List) continue;
      for (int x = 0; x < width; x++) {
        if (x >= row.length) continue;
        final cell = row[x];
        double? value;
        if (cell is List && cell.isNotEmpty) {
          final element = cell.first;
          if (element is num) {
            value = element.toDouble();
          }
        } else if (cell is num) {
          value = cell.toDouble();
        }
        if (value == null || value.isNaN || value.isInfinite) {
          continue;
        }
        buffer[y * width + x] = value;
        if (value < minValue) minValue = value;
        if (value > maxValue) maxValue = value;
      }
    }

    if (!minValue.isFinite || !maxValue.isFinite) {
      return null;
    }

    return _ParsedDepthOutput(
      width: width,
      height: height,
      buffer: buffer,
      minValue: minValue,
      maxValue: maxValue,
    );
  }
}

class _ParsedDepthOutput {
  const _ParsedDepthOutput({
    required this.width,
    required this.height,
    required this.buffer,
    required this.minValue,
    required this.maxValue,
  });

  final int width;
  final int height;
  final Float32List buffer;
  final double minValue;
  final double maxValue;
}

