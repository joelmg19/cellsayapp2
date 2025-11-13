import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
// Mantener image ^4.x en línea con flutter_launcher_icons 0.14.4 para evitar choques.
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../../services/depth_inference_service.dart';

/// Displays a live camera preview with depth estimation using the
/// `DepthInferenceService` model.
class DepthCameraScreen extends StatefulWidget {
  const DepthCameraScreen({super.key});

  @override
  State<DepthCameraScreen> createState() => _DepthCameraScreenState();
}

class _DepthCameraScreenState extends State<DepthCameraScreen> {
  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isProcessingFrame = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  final DepthInferenceService _depthService = DepthInferenceService();

  Uint8List? _depthOverlay;
  double? _nearestDistance;
  double? _centerDistance;

  static const _processingInterval = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La cámara no está disponible.')),
        );
      }
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró una cámara.')),
        );
      }
      return;
    }

    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await controller.initialize();

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      _cameraController = controller;
      _cameraReady = true;
    });

    await controller.startImageStream(_handleCameraFrame);
  }

  Future<void> _handleCameraFrame(CameraImage image) async {
    if (_isProcessingFrame) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < _processingInterval) {
      return;
    }

    _isProcessingFrame = true;
    _lastProcessed = now;

    try {
      final jpegBytes = _convertYuvToJpeg(image);
      final depthFrame = await _depthService.estimateDepth(jpegBytes);
      if (depthFrame != null && mounted) {
        final overlay = await _createDepthOverlay(depthFrame);
        final metrics = _extractDepthMetrics(depthFrame);
        if (!mounted) return;
        setState(() {
          _depthOverlay = overlay;
          _nearestDistance = metrics.nearestDistance;
          _centerDistance = metrics.centerDistance;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('DepthCameraScreen: error procesando frame - $error');
      debugPrint('$stackTrace');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<Uint8List> _createDepthOverlay(DepthFrame frame) async {
    final depthImage = img.Image(width: frame.width, height: frame.height);
    final range = (frame.maxValue - frame.minValue).abs();
    final safeRange = range == 0 ? 1.0 : range;

    for (int y = 0; y < frame.height; y++) {
      for (int x = 0; x < frame.width; x++) {
        final value = frame.valueAt(x, y);
        final normalized = value == null
            ? 0.0
            : ((value - frame.minValue) / safeRange).clamp(0.0, 1.0);
        final color = _colorForNormalizedValue(normalized);
        depthImage.setPixelRgba(x, y, color[0], color[1], color[2], 180);
      }
    }

    return Uint8List.fromList(img.encodePng(depthImage));
  }

  _DepthMetrics _extractDepthMetrics(DepthFrame frame) {
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

  Uint8List _convertYuvToJpeg(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final rgbImage = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yp = yPlane.bytes[y * yPlane.bytesPerRow + x];
        final uvIndex =
            (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * (uPlane.bytesPerPixel ?? 1);

        final up = uPlane.bytes[uvIndex];
        final vp = vPlane.bytes[uvIndex];

        int r = (yp + 1.370705 * (vp - 128)).clamp(0, 255).toInt();
        int g =
            (yp - 0.698001 * (vp - 128) - 0.337633 * (up - 128)).clamp(0, 255).toInt();
        int b = (yp + 1.732446 * (up - 128)).clamp(0, 255).toInt();

        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return Uint8List.fromList(img.encodeJpg(rgbImage, quality: 90));
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    unawaited(_depthService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profundidad en tiempo real')),
      body: _cameraReady && _cameraController != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(_cameraController!),
                if (_depthOverlay != null)
                  Opacity(
                    opacity: 0.6,
                    child: Image.memory(
                      _depthOverlay!,
                      fit: BoxFit.cover,
                    ),
                  ),
                _buildDepthInfo(),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildDepthInfo() {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        );
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.65),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Mediciones de profundidad', style: style),
            const SizedBox(height: 8),
            Text(
              _nearestDistance != null
                  ? 'Objeto más cercano: ${_nearestDistance!.toStringAsFixed(2)} m'
                  : 'Buscando profundidad…',
              style: style,
            ),
            const SizedBox(height: 4),
            Text(
              _centerDistance != null
                  ? 'Distancia al centro: ${_centerDistance!.toStringAsFixed(2)} m'
                  : 'Sin datos en el centro',
              style: style,
            ),
          ],
        ),
      ),
    );
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
