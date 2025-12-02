import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/models/yolo_result.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';
import 'package:ultralytics_yolo/yolo_streaming_config.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

import '../../core/vision/detection_geometry.dart';

class MoneyDetectorOfflineScreen extends StatefulWidget {
  const MoneyDetectorOfflineScreen({super.key});

  @override
  State<MoneyDetectorOfflineScreen> createState() =>
      _MoneyDetectorOfflineScreenState();
}

class _MoneyDetectorOfflineScreenState
    extends State<MoneyDetectorOfflineScreen> {
  static const String _assetModelPath = 'assets/models/best_float16money.tflite';

  final FlutterTts _tts = FlutterTts();
  final YOLOViewController _yoloController = YOLOViewController();
  final Duration _voiceCooldown = const Duration(seconds: 4);
  final Map<String, int> _labelToValue = const {
    'billete_1000': 1000,
    'billete_2000': 2000,
    'billete_5000': 5000,
    'billete_10000': 10000,
    'billete_20000': 20000,
    'clp_1000': 1000,
    'clp_2000': 2000,
    'clp_5000': 5000,
    'clp_10000': 10000,
    'clp_20000': 20000,
  };

  List<YOLOResult> _detections = const [];
  Map<String, int> _classCounts = const {};
  int _currentTotal = 0;
  String? _modelPath;
  bool _isPreparingModel = true;
  String? _errorMessage;
  DateTime _lastVoice = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastAnnouncedTotal = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _initTts();
    await _prepareModel();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('es-ES');
    await _tts.setSpeechRate(0.9);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _prepareModel() async {
    setState(() {
      _isPreparingModel = true;
      _errorMessage = null;
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final filePath = p.join(dir.path, 'best_float16money.tflite');
      final modelFile = File(filePath);
      if (!await modelFile.exists()) {
        final data = await rootBundle.load(_assetModelPath);
        final buffer = data.buffer.asUint8List();
        await modelFile.writeAsBytes(buffer, flush: true);
      }
      if (!mounted) return;
      setState(() {
        _modelPath = filePath;
        _isPreparingModel = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'No se pudo preparar el modelo offline.';
        _isPreparingModel = false;
      });
    }
  }

  void _handleStreamingData(Map<String, dynamic> data) {
    if (!mounted) return;
    final detections = <YOLOResult>[];
    final rawDetections = data['detections'];
    if (rawDetections is List) {
      for (final detection in rawDetections) {
        if (detection is Map) {
          try {
            detections.add(
              YOLOResult.fromMap(
                detection.map((key, value) => MapEntry('$key', value)),
              ),
            );
          } catch (_) {
            continue;
          }
        }
      }
    }
    final summary = _summarizeDetections(detections);
    setState(() {
      _detections = detections;
      _classCounts = summary.counts;
      _currentTotal = summary.total;
    });
    unawaited(_announceTotal(summary.total));
  }

  ({Map<String, int> counts, int total}) _summarizeDetections(
    List<YOLOResult> detections,
  ) {
    final counts = <String, int>{};
    int total = 0;
    for (final detection in detections) {
      final label = extractLabel(detection);
      if (label == null) continue;
      if (!_labelToValue.containsKey(label)) continue;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    counts.forEach((label, count) {
      final value = _labelToValue[label] ?? 0;
      total += value * count;
    });
    return (counts: counts, total: total);
  }

  Future<void> _announceTotal(int total) async {
    if (total <= 0 && _lastAnnouncedTotal <= 0) return;

    final now = DateTime.now();
    final bool totalChanged = total != _lastAnnouncedTotal;
    final bool cooldownReached = now.difference(_lastVoice) >= _voiceCooldown;

    if (!totalChanged && !cooldownReached) {
      return;
    }

    final phrase = 'El total es $total pesos.';
    await _tts.speak(phrase);
    _lastVoice = DateTime.now();
    _lastAnnouncedTotal = total;
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dinero sin Internet'),
        actions: [
          IconButton(
            tooltip: 'Reintentar',
            onPressed: _isPreparingModel ? null : _prepareModel,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildBody() {
    if (_isPreparingModel) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Preparando modelo offline...'),
          ],
        ),
      );
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_rounded, size: 52, color: Colors.amber.shade700),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _prepareModel,
                icon: const Icon(Icons.refresh),
                label: const Text('Intentar de nuevo'),
              ),
            ],
          ),
        ),
      );
    }
    if (_modelPath == null) {
      return const Center(child: Text('No se encontró el modelo.'));
    }

    return Stack(
      children: [
        Positioned.fill(
          child: YOLOView(
            controller: _yoloController,
            modelPath: _modelPath!,
            task: YOLOTask.detect,
            streamingConfig: const YOLOStreamingConfig.custom(
              includeDetections: true,
              includeOriginalImage: false,
              includeProcessingTimeMs: false,
              includeFps: false,
              includeClassifications: false,
            ),
            onStreamingData: _handleStreamingData,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _MoneyDetectionsPainter(_detections),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _DetectionsPanel(
                total: _currentTotal,
                classCounts: _classCounts,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MoneyDetectionsPainter extends CustomPainter {
  _MoneyDetectionsPainter(this.detections);

  final List<YOLOResult> detections;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final textStyle = TextStyle(
      color: Colors.greenAccent.shade100,
      fontSize: 14,
      background: Paint()
        ..color = Colors.black.withOpacity(0.55)
        ..style = PaintingStyle.fill,
    );

    for (final detection in detections) {
      Rect? rect = detection.normalizedBox;
      rect ??= extractBoundingBox(detection);
      if (rect == null) continue;

      if (rect.right > 1 || rect.bottom > 1) {
        final imageWidth = extractImageWidthPx(detection);
        final imageHeight = extractImageHeightPx(detection);
        if (imageWidth != null && imageWidth > 0 && imageHeight != null && imageHeight > 0) {
          rect = Rect.fromLTRB(
            rect.left / imageWidth,
            rect.top / imageHeight,
            rect.right / imageWidth,
            rect.bottom / imageHeight,
          );
        }
      }

      final scaledRect = Rect.fromLTRB(
        rect.left.clamp(0.0, 1.0) * size.width,
        rect.top.clamp(0.0, 1.0) * size.height,
        rect.right.clamp(0.0, 1.0) * size.width,
        rect.bottom.clamp(0.0, 1.0) * size.height,
      );

      canvas.drawRect(scaledRect, paint);

      final label = extractLabel(detection);
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(scaledRect.left, scaledRect.top - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _MoneyDetectionsPainter oldDelegate) {
    return oldDelegate.detections != detections;
  }
}

class _DetectionsPanel extends StatelessWidget {
  const _DetectionsPanel({
    required this.total,
    required this.classCounts,
  });

  final int total;
  final Map<String, int> classCounts;

  String _formatCurrency(int amount) {
    if (amount <= 0) return 'CLP 0';
    final digits = amount.toString().split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i != 0 && i % 3 == 0) {
        buffer.write('.');
      }
      buffer.write(digits[i]);
    }
    final formatted = buffer.toString().split('').reversed.join();
    return 'CLP $formatted';
  }

  @override
  Widget build(BuildContext context) {
    final hasDetections = classCounts.isNotEmpty && total > 0;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasDetections
                    ? 'Total detectado: ${_formatCurrency(total)}'
                    : 'Sin billetes detectados',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (hasDetections)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: classCounts.entries.map((entry) {
                    final label = entry.key.replaceAll('_', ' ');
                    return Chip(
                      label: Text('$label · ${entry.value}'),
                      backgroundColor: Colors.white.withOpacity(0.12),
                      labelStyle: const TextStyle(color: Colors.white),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Colors.white24),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  }).toList(),
                )
              else
                const Text(
                  'Apunta la cámara a los billetes para detectar el monto total.',
                  style: TextStyle(color: Colors.white70),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
