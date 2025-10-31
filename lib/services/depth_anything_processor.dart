import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class DepthAnalysis {
  const DepthAnalysis({
    required this.imageWidth,
    required this.imageHeight,
    required this.depth,
  });

  final int imageWidth;
  final int imageHeight;
  final DepthAnythingResult? depth;
}

class DepthAnythingResult {
  DepthAnythingResult({
    required this.width,
    required this.height,
    required this.values,
    required this.minValue,
    required this.maxValue,
  });

  final int width;
  final int height;
  final Float32List values;
  final double minValue;
  final double maxValue;

  double? metersForBox(
    Rect rect,
    int viewWidth,
    int viewHeight, {
    int stride = 4,
  }) {
    if (width <= 0 || height <= 0 || viewWidth <= 0 || viewHeight <= 0) {
      return null;
    }

    final normalizedLeft = _clamp(rect.left / viewWidth, 0.0, 1.0);
    final normalizedTop = _clamp(rect.top / viewHeight, 0.0, 1.0);
    final normalizedRight = _clamp(rect.right / viewWidth, 0.0, 1.0);
    final normalizedBottom = _clamp(rect.bottom / viewHeight, 0.0, 1.0);

    if (normalizedLeft >= normalizedRight || normalizedTop >= normalizedBottom) {
      return null;
    }

    final startX = (normalizedLeft * width).floor().clamp(0, width - 1);
    final endX = (normalizedRight * width).floor().clamp(startX, width - 1);
    final startY = (normalizedTop * height).floor().clamp(0, height - 1);
    final endY = (normalizedBottom * height).floor().clamp(startY, height - 1);
    final step = math.max(1, stride);

    final samples = <double>[];
    for (var y = startY; y <= endY; y += step) {
      final rowOffset = y * width;
      for (var x = startX; x <= endX; x += step) {
        final value = values[rowOffset + x];
        if (value.isFinite) {
          samples.add(value.toDouble());
        }
      }
    }

    if (samples.isEmpty) {
      return null;
    }

    samples.sort();
    final median = samples[samples.length ~/ 2];
    return _approximateMeters(median);
  }

  double _approximateMeters(double depthValue) {
    final clamped = _clamp(depthValue, minValue, maxValue);
    final normalized = (maxValue > minValue)
        ? (clamped - minValue) / (maxValue - minValue)
        : 0.5;
    final inverted = 1.0 - _clamp(normalized, 0.0, 1.0);
    const minDistance = 0.5;
    const maxDistance = 5.0;
    return minDistance + inverted * (maxDistance - minDistance);
  }

  double _clamp(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

class DepthAnythingProcessor {
  DepthAnythingProcessor._(
    this._interpreter,
    this._inputShape,
    this._outputShape,
  )   : _inputHeight = _inputShape.length > 1 ? _inputShape[1] : 0,
        _inputWidth = _inputShape.length > 2 ? _inputShape[2] : 0,
        _inputChannels = _inputShape.length > 3 ? _inputShape[3] : 0,
        _outputHeight = _outputShape.length > 1 ? _outputShape[_outputShape.length - 3] : 0,
        _outputWidth = _outputShape.length > 2 ? _outputShape[_outputShape.length - 2] : 0,
        _outputChannels = _outputShape.length > 3 ? _outputShape[_outputShape.length - 1] : 1;

  final Interpreter _interpreter;
  final List<int> _inputShape;
  final List<int> _outputShape;
  final int _inputHeight;
  final int _inputWidth;
  final int _inputChannels;
  final int _outputHeight;
  final int _outputWidth;
  final int _outputChannels;

  static Future<DepthAnythingProcessor> create() async {
    final interpreter = await Interpreter.fromAsset('models/depth_anything.tflite');
    return DepthAnythingProcessor._(
      interpreter,
      interpreter.getInputTensor(0).shape,
      interpreter.getOutputTensor(0).shape,
    );
  }

  Future<DepthAnalysis?> estimate({
    Uint8List? imageBytes,
    img.Image? decodedImage,
  }) async {
    final img.Image? image = decodedImage ??
        (imageBytes != null ? img.decodeImage(imageBytes) : null);
    if (image == null || image.width <= 0 || image.height <= 0) {
      return null;
    }

    final depth = _runInference(image);
    return DepthAnalysis(
      imageWidth: image.width,
      imageHeight: image.height,
      depth: depth,
    );
  }

  DepthAnythingResult? _runInference(img.Image image) {
    if (_inputHeight <= 0 || _inputWidth <= 0 || _inputChannels <= 0) {
      return null;
    }

    final resized = img.copyResize(
      image,
      width: _inputWidth,
      height: _inputHeight,
      interpolation: img.Interpolation.linear,
    );

    final input = List.generate(
      1,
      (_) => List.generate(
        _inputHeight,
        (_) => List.generate(
          _inputWidth,
          (_) => List<double>.filled(_inputChannels, 0.0),
        ),
      ),
    );

    for (var y = 0; y < _inputHeight; y++) {
      for (var x = 0; x < _inputWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final channels = input[0][y][x];
        if (_inputChannels >= 1) {
          channels[0] = pixel.rNormalized.toDouble();
        }
        if (_inputChannels >= 2) {
          channels[1] = pixel.gNormalized.toDouble();
        }
        if (_inputChannels >= 3) {
          channels[2] = pixel.bNormalized.toDouble();
        }
      }
    }

    final depthData = Float32List(_outputWidth * _outputHeight);
    double minValue = double.infinity;
    double maxValue = double.negativeInfinity;

    if (_outputShape.length == 3) {
      final output = List.generate(
        1,
        (_) => List.generate(
          _outputHeight,
          (_) => List<double>.filled(_outputWidth, 0.0),
        ),
      );
      _interpreter.run(input, output);
      var index = 0;
      for (var y = 0; y < _outputHeight; y++) {
        final row = output[0][y];
        for (var x = 0; x < _outputWidth; x++) {
          final value = row[x];
          final floatValue = value.toDouble();
          depthData[index++] = floatValue;
          if (floatValue.isFinite) {
            if (floatValue < minValue) minValue = floatValue;
            if (floatValue > maxValue) maxValue = floatValue;
          }
        }
      }
    } else {
      final channels = math.max(1, _outputChannels);
      final output = List.generate(
        1,
        (_) => List.generate(
          _outputHeight,
          (_) => List.generate(
            _outputWidth,
            (_) => List<double>.filled(channels, 0.0),
          ),
        ),
      );
      _interpreter.run(input, output);
      var index = 0;
      for (var y = 0; y < _outputHeight; y++) {
        final row = output[0][y];
        for (var x = 0; x < _outputWidth; x++) {
          final channelValues = row[x];
          final value = channelValues[0];
          final floatValue = value.toDouble();
          depthData[index++] = floatValue;
          if (floatValue.isFinite) {
            if (floatValue < minValue) minValue = floatValue;
            if (floatValue > maxValue) maxValue = floatValue;
          }
        }
      }
    }

    if (!minValue.isFinite || !maxValue.isFinite) {
      minValue = 0.0;
      maxValue = 1.0;
    }

    return DepthAnythingResult(
      width: _outputWidth,
      height: _outputHeight,
      values: depthData,
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  void close() {
    _interpreter.close();
  }
}
