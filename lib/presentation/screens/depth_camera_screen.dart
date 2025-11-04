import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/depth_processing_worker.dart';

/// Displays a live camera preview with depth estimation using the
/// `DepthProcessingWorker` to offload heavy work to an isolate.
class DepthCameraScreen extends StatefulWidget {
  const DepthCameraScreen({super.key});

  @override
  State<DepthCameraScreen> createState() => _DepthCameraScreenState();
}

class _DepthCameraScreenState extends State<DepthCameraScreen>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin<DepthCameraScreen> {
  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isProcessingFrame = false;
  bool _isStreaming = false;
  bool _isVisible = true;
  bool _permissionGranted = false;
  int _frameSkipCounter = 0;

  final DepthProcessingWorker _processingWorker = DepthProcessingWorker();

  Uint8List? _depthOverlay;
  double? _nearestDistance;
  double? _centerDistance;

  static const int _frameSkipInterval = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera(disposeController: true);
    unawaited(_processingWorker.stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopCamera(disposeController: true);
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (!mounted) return;

    if (_cameraController != null) {
      if (!_cameraReady) {
        await _cameraController!.initialize();
        _cameraReady = true;
      }
      if (!_isStreaming) {
        await _cameraController!.startImageStream(_handleCameraFrame);
        _isStreaming = true;
      }
      return;
    }

    if (!_permissionGranted) {
      final cameraStatus = await Permission.camera.request();
      _permissionGranted = cameraStatus.isGranted;
      if (!_permissionGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('La cámara no está disponible.')),
          );
        }
        return;
      }
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

    try {
      await controller.initialize();
    } catch (error, stackTrace) {
      debugPrint('DepthCameraScreen: error inicializando cámara - $error');
      debugPrint('$stackTrace');
      await controller.dispose();
      return;
    }

    if (!mounted) {
      await controller.dispose();
      return;
    }

    await _processingWorker.start();

    setState(() {
      _cameraController = controller;
      _cameraReady = true;
    });

    await controller.startImageStream(_handleCameraFrame);
    _isStreaming = true;
  }

  Future<void> _stopCamera({bool disposeController = false}) async {
    _isProcessingFrame = false;
    _frameSkipCounter = 0;
    if (_cameraController != null) {
      if (_isStreaming) {
        try {
          await _cameraController!.stopImageStream();
        } catch (error) {
          debugPrint('DepthCameraScreen: stopImageStream error - $error');
        }
        _isStreaming = false;
      }
      if (disposeController) {
        await _cameraController?.dispose();
        _cameraController = null;
        _cameraReady = false;
      }
    }
  }

  Future<void> _handleCameraFrame(CameraImage image) async {
    if (!_isVisible || _isProcessingFrame || !_cameraReady) {
      return;
    }

    if ((_frameSkipCounter++ % _frameSkipInterval) != 0) {
      return;
    }
    _frameSkipCounter = 0;

    _isProcessingFrame = true;
    try {
      final result = await _processingWorker.process(image);
      if (!mounted || result == null) return;
      if (!_isVisible) return;
      setState(() {
        _depthOverlay = result.overlayBytes;
        _nearestDistance = result.nearestDistance;
        _centerDistance = result.centerDistance;
      });
    } catch (error, stackTrace) {
      debugPrint('DepthCameraScreen: error procesando frame - $error');
      debugPrint('$stackTrace');
    } finally {
      _isProcessingFrame = false;
    }
  }

  @override
  void deactivate() {
    _isVisible = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _isVisible = true;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
                  : 'Sin datos del objeto más cercano',
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
