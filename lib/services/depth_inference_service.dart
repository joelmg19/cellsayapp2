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
  TensorType? _inputType;
  TensorType? _outputType;
  bool _isProcessing = false;
  bool _initializationAttempted = false;

  Float32List? _inputBufferFloat32;
  Uint8List? _inputBufferUint8;
  Float32List? _outputBufferFloat32;
  Uint8List? _outputBufferUint8;
  Float32List? _depthDataBuffer;

  bool get isInitialized => _interpreter != null;

  Future<void> initialize({Uint8List? modelBuffer}) async {
    if (_interpreter != null || _initializationAttempted) return;
    _initializationAttempted = true;

    try {
      final options = InterpreterOptions()
        ..threads = Platform.isAndroid ? 4 : 2;
      try {
        options.addDelegate(XNNPackDelegate());
      } catch (error) {
        debugPrint('DepthInferenceService: XNNPACK unavailable - $error');
      }
      if (Platform.isAndroid) {
        try {
          options.addDelegate(
            GpuDelegateV2(
              options: GpuDelegateOptionsV2(
                isPrecisionLossAllowed: false,
                inferencePreference:
                    GpuDelegateOptionsV2.inferencePreferenceSustainedSpeed,
              ),
            ),
          );
        } catch (error) {
          debugPrint('DepthInferenceService: GPU delegate unavailable - $error');
        }
      }

      final buffer = modelBuffer ??
          (await rootBundle.load(modelAssetPath)).buffer.asUint8List();

      _interpreter = await Interpreter.fromBuffer(buffer, options: options);
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
    _inputBufferFloat32 = null;
    _inputBufferUint8 = null;
    _outputBufferFloat32 = null;
    _outputBufferUint8 = null;
    _depthDataBuffer = null;
    _initializationAttempted = false;
  }

  Future<DepthFrame?> estimateDepth(Uint8List imageBytes) async {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      debugPrint('DepthInferenceService: unable to decode image');
      return null;
    }
    return estimateDepthFromImage(decoded);
  }

  Future<DepthFrame?> estimateDepthFromImage(img.Image image) async {
    if (_interpreter == null) {
      await initialize();
      if (_interpreter == null) {
        return null;
      }
    }

    if (_isProcessing) return null;
    _isProcessing = true;
    try {
      final inputShape = _inputShape ?? _interpreter!.getInputTensor(0).shape;
      final targetHeight = _dimensionFromShape(inputShape, axisFromEnd: 3);
      final targetWidth = _dimensionFromShape(inputShape, axisFromEnd: 2);
      final targetChannels = _dimensionFromShape(inputShape, axisFromEnd: 1);

      final resized = img.copyResize(
        image,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear,
      );

      final inputType = _inputType ?? TensorType.float32;
      final inputBuffer = _prepareInputBuffer(
        resized,
        targetChannels,
        inputType,
      );

      final outputShape = _outputShape ?? _interpreter!.getOutputTensor(0).shape;
      final outputChannels = _dimensionFromShape(outputShape, axisFromEnd: 1);
      final outputHeight = _dimensionFromShape(outputShape, axisFromEnd: 3);
      final outputWidth = _dimensionFromShape(outputShape, axisFromEnd: 2);
      final outputType = _outputType ?? TensorType.float32;
      final outputBuffer = _prepareOutputBuffer(
        outputHeight,
        outputWidth,
        outputChannels,
        outputType,
      );

      _interpreter!.run(inputBuffer, outputBuffer);

      final parsed = _parseOutputFromBuffer(
        outputBuffer,
        outputHeight,
        outputWidth,
        outputChannels,
        outputType,
      );
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

  dynamic _prepareInputBuffer(
    img.Image image,
    int channels,
    TensorType inputType,
  ) {
    final height = image.height;
    final width = image.width;
    final length = height * width * channels;

    if (inputType == TensorType.float32) {
      final buffer = _ensureInputFloat32(length);
      var offset = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final pixel = image.getPixel(x, y);
          if (channels <= 1) {
            buffer[offset++] =
                img.getLuminanceRgb(pixel.r, pixel.g, pixel.b) / 255.0;
          } else {
            buffer[offset++] = pixel.r / 255.0;
            buffer[offset++] = pixel.g / 255.0;
            buffer[offset++] = pixel.b / 255.0;
          }
        }
      }
      return buffer;
    }

    final buffer = _ensureInputUint8(length);
    var offset = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);
        if (channels <= 1) {
          final luminance = img.getLuminanceRgb(pixel.r, pixel.g, pixel.b);
          buffer[offset++] = luminance;
        } else {
          buffer[offset++] = pixel.r;
          buffer[offset++] = pixel.g;
          buffer[offset++] = pixel.b;
        }
      }
    }
    return buffer;
  }

  dynamic _prepareOutputBuffer(
    int height,
    int width,
    int channels,
    TensorType outputType,
  ) {
    final length = height * width * channels;
    if (outputType == TensorType.float32) {
      return _ensureOutputFloat32(length);
    }
    return _ensureOutputUint8(length);
  }

  _ParsedDepthOutput? _parseOutputFromBuffer(
    dynamic buffer,
    int height,
    int width,
    int channels,
    TensorType outputType,
  ) {
    final depthBuffer = _ensureDepthDataBuffer(height * width);
    double minValue = double.infinity;
    double maxValue = -double.infinity;

    if (outputType == TensorType.float32 && buffer is Float32List) {
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final index = (y * width + x) * channels;
          final value = buffer[index];
          if (!value.isFinite) continue;
          depthBuffer[y * width + x] = value;
          if (value < minValue) minValue = value;
          if (value > maxValue) maxValue = value;
        }
      }
    } else if (outputType == TensorType.uint8 && buffer is Uint8List) {
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final index = (y * width + x) * channels;
          final value = buffer[index].toDouble();
          depthBuffer[y * width + x] = value;
          if (value < minValue) minValue = value;
          if (value > maxValue) maxValue = value;
        }
      }
    } else {
      return null;
    }

    if (!minValue.isFinite || !maxValue.isFinite) {
      return null;
    }

    return _ParsedDepthOutput(
      width: width,
      height: height,
      buffer: Float32List.fromList(depthBuffer),
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  Float32List _ensureInputFloat32(int length) {
    final buffer = _inputBufferFloat32;
    if (buffer == null || buffer.length != length) {
      _inputBufferFloat32 = Float32List(length);
      return _inputBufferFloat32!;
    }
    return buffer;
  }

  Uint8List _ensureInputUint8(int length) {
    final buffer = _inputBufferUint8;
    if (buffer == null || buffer.length != length) {
      _inputBufferUint8 = Uint8List(length);
      return _inputBufferUint8!;
    }
    return buffer;
  }

  Float32List _ensureOutputFloat32(int length) {
    final buffer = _outputBufferFloat32;
    if (buffer == null || buffer.length != length) {
      _outputBufferFloat32 = Float32List(length);
      return _outputBufferFloat32!;
    }
    return buffer;
  }

  Uint8List _ensureOutputUint8(int length) {
    final buffer = _outputBufferUint8;
    if (buffer == null || buffer.length != length) {
      _outputBufferUint8 = Uint8List(length);
      return _outputBufferUint8!;
    }
    return buffer;
  }

  Float32List _ensureDepthDataBuffer(int length) {
    final buffer = _depthDataBuffer;
    if (buffer == null || buffer.length != length) {
      _depthDataBuffer = Float32List(length);
      return _depthDataBuffer!;
    }
    return buffer;
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

