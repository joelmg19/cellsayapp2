import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'depth_inference_service.dart';

class DepthProcessingResult {
  const DepthProcessingResult({
    required this.overlayBytes,
    required this.nearestDistance,
    required this.centerDistance,
  });

  final Uint8List? overlayBytes;
  final double? nearestDistance;
  final double? centerDistance;
}

class DepthProcessingWorker {
  DepthProcessingWorker({
    this.modelAssetPath = 'assets/models/depth_anything.tflite',
    this.sampleStep = 2,
    this.minDistanceMeters = 0.3,
    this.maxDistanceMeters = 8.0,
  });

  final String modelAssetPath;
  final int sampleStep;
  final double minDistanceMeters;
  final double maxDistanceMeters;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  final _pending = <int, Completer<DepthProcessingResult?>>{};
  int _sequence = 0;
  bool _starting = false;
  final List<Uint8List> _planeBuffers = <Uint8List>[];

  Future<void> start() async {
    if (_isolate != null || _starting) return;
    _starting = true;

    final responsePort = ReceivePort();
    _receivePort = responsePort;
    final modelData = await rootBundle.load(modelAssetPath);
    final config = _IsolateConfiguration(
      responsePort.sendPort,
      modelData.buffer.asUint8List(),
      sampleStep,
      minDistanceMeters,
      maxDistanceMeters,
    );

    _isolate = await Isolate.spawn<_IsolateConfiguration>(
      _DepthProcessingIsolate.entryPoint,
      config,
      debugName: 'DepthProcessingIsolate',
    );

    _subscription = responsePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _starting = false;
      } else if (message is _IsolateResponse) {
        final completer = _pending.remove(message.sequenceId);
        if (completer != null) {
          completer.complete(message.result);
        }
      }
    });

    // wait until sendPort ready
    while (_sendPort == null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> stop() async {
    _sendPort?.send(const _StopMessage());
    _sendPort = null;
    await _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _pending.values.forEach((c) => c.complete(null));
    _pending.clear();
  }

  Future<DepthProcessingResult?> process(CameraImage image) async {
    if (_sendPort == null) {
      if (_starting) {
        while (_starting && _sendPort == null) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } else {
        await start();
      }
    }
    final sendPort = _sendPort;
    if (sendPort == null) return null;

    final sequenceId = _sequence++;
    final completer = Completer<DepthProcessingResult?>();
    _pending[sequenceId] = completer;

    final planes = <_PlaneMessage>[];
    for (var i = 0; i < image.planes.length; i++) {
      final plane = image.planes[i];
      if (_planeBuffers.length <= i) {
        _planeBuffers.add(Uint8List(plane.bytes.length));
      } else if (_planeBuffers[i].length != plane.bytes.length) {
        _planeBuffers[i] = Uint8List(plane.bytes.length);
      }
      final buffer = _planeBuffers[i];
      buffer.setRange(0, plane.bytes.length, plane.bytes);
      planes.add(
        _PlaneMessage(
          bytesPerRow: plane.bytesPerRow,
          bytesPerPixel: plane.bytesPerPixel ?? 1,
          bytes: Uint8List.sublistView(buffer, 0, plane.bytes.length),
        ),
      );
    }

    sendPort.send(
      _ProcessFrameMessage(
        sequenceId: sequenceId,
        width: image.width,
        height: image.height,
        planes: planes,
      ),
    );

    return completer.future;
  }
}

class _IsolateConfiguration {
  const _IsolateConfiguration(
    this.mainSendPort,
    this.modelData,
    this.sampleStep,
    this.minDistanceMeters,
    this.maxDistanceMeters,
  );

  final SendPort mainSendPort;
  final Uint8List modelData;
  final int sampleStep;
  final double minDistanceMeters;
  final double maxDistanceMeters;
}

class _ProcessFrameMessage {
  const _ProcessFrameMessage({
    required this.sequenceId,
    required this.width,
    required this.height,
    required this.planes,
  });

  final int sequenceId;
  final int width;
  final int height;
  final List<_PlaneMessage> planes;
}

class _PlaneMessage {
  const _PlaneMessage({
    required this.bytesPerRow,
    required this.bytesPerPixel,
    required this.bytes,
  });

  final int bytesPerRow;
  final int bytesPerPixel;
  final Uint8List bytes;
}

class _StopMessage {
  const _StopMessage();
}

class _IsolateResponse {
  const _IsolateResponse(this.sequenceId, this.result);

  final int sequenceId;
  final DepthProcessingResult? result;
}

class _DepthProcessingIsolate {
  const _DepthProcessingIsolate(this.config);

  final _IsolateConfiguration config;

  static Future<void> entryPoint(_IsolateConfiguration config) async {
    final isolate = _DepthProcessingIsolate(config);
    await isolate._run();
  }

  Future<void> _run() async {
    final port = ReceivePort();
    config.mainSendPort.send(port.sendPort);

    final depthService = DepthInferenceService(
      modelAssetPath: config.modelData.isEmpty
          ? 'assets/models/depth_anything.tflite'
          : '',
      sampleStep: config.sampleStep,
      minDistanceMeters: config.minDistanceMeters,
      maxDistanceMeters: config.maxDistanceMeters,
    );
    await depthService.initialize(modelBuffer: config.modelData);

    final processor = _DepthFrameProcessor(depthService);

    await for (final message in port) {
      if (message is _ProcessFrameMessage) {
        final result = await processor.process(message);
        config.mainSendPort
            .send(_IsolateResponse(message.sequenceId, result));
      } else if (message is _StopMessage) {
        break;
      }
    }

    await depthService.dispose();
  }
}

class _DepthFrameProcessor {
  _DepthFrameProcessor(this._service);

  final DepthInferenceService _service;
  img.Image? _rgbBuffer;
  img.Image? _overlayBuffer;

  Future<DepthProcessingResult?> process(_ProcessFrameMessage message) async {
    if (message.planes.length < 3) return null;
    final rgbImage = _convertToImage(message);
    if (rgbImage == null) return null;

    final depthFrame = await _service.estimateDepthFromImage(rgbImage);
    if (depthFrame == null) return null;

    final overlay = _createOverlay(depthFrame);
    final metrics = _extractMetrics(depthFrame);

    return DepthProcessingResult(
      overlayBytes: overlay,
      nearestDistance: metrics.nearestDistance,
      centerDistance: metrics.centerDistance,
    );
  }

  img.Image? _convertToImage(_ProcessFrameMessage message) {
    final width = message.width;
    final height = message.height;
    final yPlane = message.planes[0];
    final uPlane = message.planes[1];
    final vPlane = message.planes[2];

    _rgbBuffer ??= img.Image(width: width, height: height);
    if (_rgbBuffer!.width != width || _rgbBuffer!.height != height) {
      _rgbBuffer = img.Image(width: width, height: height);
    }
    final image = _rgbBuffer!;

    final uPixelStride = max(1, uPlane.bytesPerPixel);
    final vPixelStride = max(1, vPlane.bytesPerPixel);
    for (int y = 0; y < height; y++) {
      final yRow = y * yPlane.bytesPerRow;
      final uRow = (y ~/ 2) * uPlane.bytesPerRow;
      final vRow = (y ~/ 2) * vPlane.bytesPerRow;
      for (int x = 0; x < width; x++) {
        final yValue = yPlane.bytes[yRow + x];
        final uvColumn = (x ~/ 2);
        final uIndex = uRow + uvColumn * uPixelStride;
        final vIndex = vRow + uvColumn * vPixelStride;
        final uValue = uPlane.bytes[min(uIndex, uPlane.bytes.length - 1)];
        final vValue = vPlane.bytes[min(vIndex, vPlane.bytes.length - 1)];

        final r = (yValue + 1.370705 * (vValue - 128)).clamp(0, 255).toInt();
        final g =
            (yValue - 0.698001 * (vValue - 128) - 0.337633 * (uValue - 128))
                .clamp(0, 255)
                .toInt();
        final b = (yValue + 1.732446 * (uValue - 128)).clamp(0, 255).toInt();
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return image;
  }

  Uint8List? _createOverlay(DepthFrame frame) {
    _overlayBuffer ??= img.Image(width: frame.width, height: frame.height);
    if (_overlayBuffer!.width != frame.width ||
        _overlayBuffer!.height != frame.height) {
      _overlayBuffer = img.Image(width: frame.width, height: frame.height);
    } else {
      _overlayBuffer!.fill(0);
    }

    final overlay = _overlayBuffer!;
    final range = (frame.maxValue - frame.minValue).abs();
    final safeRange = range == 0 ? 1.0 : range;

    for (int y = 0; y < frame.height; y++) {
      for (int x = 0; x < frame.width; x++) {
        final value = frame.valueAt(x, y);
        if (value == null) {
          overlay.setPixelRgba(x, y, 0, 0, 0, 0);
          continue;
        }
        final normalized = ((value - frame.minValue) / safeRange).clamp(0.0, 1.0);
        final colors = _colorForNormalizedValue(normalized);
        overlay.setPixelRgba(x, y, colors[0], colors[1], colors[2], 200);
      }
    }

    return Uint8List.fromList(img.encodePng(overlay, level: 4));
  }

  _DepthMetrics _extractMetrics(DepthFrame frame) {
    double nearest = double.infinity;
    double centerSum = 0;
    int centerCount = 0;

    final minX = (frame.width * 0.35).floor();
    final maxX = (frame.width * 0.65).ceil();
    final minY = (frame.height * 0.35).floor();
    final maxY = (frame.height * 0.65).ceil();

    for (int y = 0; y < frame.height; y += frame.sampleStep) {
      for (int x = 0; x < frame.width; x += frame.sampleStep) {
        final value = frame.valueAt(x, y);
        if (value == null) continue;
        final distance = frame.convertRawToDistance(value);
        if (distance == null) continue;
        if (distance < nearest) {
          nearest = distance;
        }
        if (x >= minX && x <= maxX && y >= minY && y <= maxY) {
          centerSum += distance;
          centerCount++;
        }
      }
    }

    final nearestDistance = nearest.isFinite ? nearest : null;
    final centerDistance = centerCount > 0 ? centerSum / centerCount : null;

    return _DepthMetrics(
      nearestDistance: nearestDistance,
      centerDistance: centerDistance,
    );
  }

  List<int> _colorForNormalizedValue(double normalized) {
    final clamped = normalized.clamp(0.0, 1.0);
    final red = (255 * (1.0 - clamped)).round().clamp(0, 255);
    final green =
        (255 * (1.0 - (2 * (clamped - 0.5)).abs())).round().clamp(0, 255);
    final blue = (255 * clamped).round().clamp(0, 255);
    return [red, green, blue];
  }
}

class _DepthMetrics {
  const _DepthMetrics({
    required this.nearestDistance,
    required this.centerDistance,
  });

  final double? nearestDistance;
  final double? centerDistance;
}
