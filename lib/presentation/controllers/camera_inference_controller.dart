import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// Import para ML Kit OCR, escondiendo 'ModelManager' para evitar conflicto
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    hide ModelManager;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/models/yolo_result.dart';
import 'package:ultralytics_yolo/utils/error_handler.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:image/image.dart' as img;

import '../../core/vision/cartel_labels.dart';
import '../../core/vision/detection_distance_extension.dart';
import '../../core/vision/detection_geometry.dart';
import '../../core/vision/distance_estimator.dart';
import '../../core/vision/distance_estimator_provider.dart';
import '../../models/detection_insight.dart';
import '../../models/models.dart';
import '../../models/voice_settings.dart';
import '../../services/detection_post_processor.dart';
import '../../services/depth_inference_service.dart';
import '../../services/model_manager.dart'; // Import de tu ModelManager
import '../../services/voice_announcer.dart';
import '../../services/voice_command_service.dart';
import '../../services/intent_recognizer.dart';
import '../../services/weather_service.dart';

/// Controller that manages the state and business logic for camera inference
class CameraInferenceController extends ChangeNotifier {
  final TextRecognizer _textRecognizer = TextRecognizer();
  bool _isOcrBusy = false;
  bool _isCaptureOcrActive = false;
  DateTime _lastOcrTimestamp = DateTime.now();
  String? _lastAnnouncedOcrMessage;
  DateTime? _lastAnnouncedOcrTimestamp;
  Uint8List? _cachedCartelImage;
  DateTime? _cachedCartelImageTimestamp;
  Timer? _voiceResumeTimer;

  // --- VARIABLES ORIGINALES ---
  int _detectionCount = 0;
  double _currentFps = 0.0;
  int _frameCount = 0;
  DateTime _lastFpsUpdate = DateTime.now();
  DateTime _lastResultTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastNonEmptyResult;
  ProcessedDetections _processedDetections = ProcessedDetections.empty;
  SafetyAlerts _safetyAlerts = const SafetyAlerts();
  double _confidenceThreshold;
  double _iouThreshold = 0.45;
  int _numItemsThreshold;
  SliderType _activeSlider = SliderType.none;
  ModelType _selectedModel;
  bool _isModelLoading = false;
  String? _modelPath;
  String _loadingMessage = '';
  double _downloadProgress = 0.0;
  double _currentZoomLevel = 1.0;
  bool _isFrontCamera = false;
  bool _isVoiceEnabled = true;
  double _fontScale = 1.0;
  VoiceSettings _voiceSettings = const VoiceSettings();
  String? _voiceCommandStatus;
  static const double _intentConfidenceThreshold = 0.6;
  static const double _zoomStep = 0.2;
  static const double _minZoomLevel = 1.0;
  static const double _maxZoomLevel = 6.0;
  bool _areControlsLocked = false;
  bool _isListeningForCommand = false;
  bool _isVoiceFeedbackPaused = false;
  bool _isProcessingVoiceCommand = false;
  final _yoloController = YOLOViewController();
  late final ModelManager _modelManager;
  final DetectionPostProcessor _postProcessor = DetectionPostProcessor();
  final VoiceAnnouncer _voiceAnnouncer = VoiceAnnouncer();
  final IntentRecognizer _intentRecognizer = IntentRecognizer();
  late final VoiceCommandService _voiceCommandService;
  final WeatherService _weatherService = WeatherService();
  final DistanceEstimatorProvider _distanceEstimatorProvider =
  DistanceEstimatorProvider();
  DistanceEstimator? _distanceEstimator;
  bool _loggedMissingDistanceEstimator = false;
  DepthInferenceService? _depthService;
  DepthFrame? _latestDepthFrame;
  bool _isDepthProcessingEnabled = false;
  bool _isDisposed = false;
  Future<void>? _loadingFuture;
  Timer? _statusTimer;
  DateTime _currentTime = DateTime.now();
  WeatherInfo? _weatherInfo;
  DateTime _lastWeatherFetch = DateTime.fromMillisecondsSinceEpoch(0);
  String? _connectionAlert;
  String? _cameraAlert;
  bool _isSignReaderEnabled = false;
  ModelType? _modelBeforeSignReader;
  DateTime? _lastSignToggleTimestamp;
  static const Duration _signToggleCooldown = Duration(milliseconds: 1500);
  // --- FIN DE VARIABLES ORIGINALES ---

  // --- GETTERS ORIGINALES ---
  int get detectionCount => _detectionCount;
  double get currentFps => _currentFps;
  double get confidenceThreshold => _confidenceThreshold;
  double get iouThreshold => _iouThreshold;
  int get numItemsThreshold => _numItemsThreshold;
  SliderType get activeSlider => _activeSlider;
  ModelType get selectedModel => _selectedModel;
  bool get isModelLoading => _isModelLoading;
  String? get modelPath => _modelPath;
  String get loadingMessage => _loadingMessage;
  double get downloadProgress => _downloadProgress;
  double get currentZoomLevel => _currentZoomLevel;
  bool get isFrontCamera => _isFrontCamera;
  bool get isVoiceEnabled => _isVoiceEnabled;
  double get fontScale => _fontScale;
  VoiceSettings get voiceSettings => _voiceSettings;
  bool get areControlsLocked => _areControlsLocked;
  bool get isProcessingVoiceCommand => _isProcessingVoiceCommand;
  ProcessedDetections get processedDetections => _processedDetections;
  SafetyAlerts get safetyAlerts => _safetyAlerts;
  String get formattedTime => DateFormat.Hm().format(_currentTime);
  String? get weatherSummary => _weatherInfo?.formatSummary();
  List<String> get closeObstacles => _processedDetections.closeObstacleLabels;
  List<String> get movementWarnings => _processedDetections.movementWarnings;
  TrafficLightSignal get trafficLightSignal =>
      _processedDetections.trafficLightSignal;
  String? get connectionAlert => _connectionAlert;
  String? get cameraAlert => _cameraAlert;
  String? get voiceCommandStatus => _voiceCommandStatus;
  bool get isListeningForCommand => _isListeningForCommand;
  YOLOViewController get yoloController => _yoloController;
  bool get isDepthProcessingEnabled => _isDepthProcessingEnabled;
  bool get isDepthServiceAvailable => _depthService != null;
  Uint8List? get cachedCartelImage => _cachedCartelImage;
  DateTime? get cachedCartelImageTimestamp => _cachedCartelImageTimestamp;
  bool get isSignReaderEnabled => _isSignReaderEnabled;
  ModelType get displayedModel =>
      _isSignReaderEnabled ? ModelType.Exterior : _selectedModel;
  bool get canToggleSignReader =>
      displayedModel == ModelType.Exterior &&
      !_isModelLoading &&
      !_areControlsLocked &&
      !_isProcessingVoiceCommand;
  // --- FIN DE GETTERS ORIGINALES ---

  CameraInferenceController({ModelType initialModel = ModelType.Interior})
      : _selectedModel = initialModel,
        _confidenceThreshold = _defaultConfidence(initialModel),
        _numItemsThreshold = _defaultNumItems(initialModel) {
    _voiceCommandService = VoiceCommandService(recognizer: _intentRecognizer);
    _modelManager = ModelManager(
      onDownloadProgress: (progress) {
        _downloadProgress = progress;
        notifyListeners();
      },
      onStatusUpdate: (message) {
        _loadingMessage = message;
        notifyListeners();
      },
    );
    _statusTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _onStatusTick());
    unawaited(_refreshWeather());
    unawaited(_loadDistanceEstimator());
    unawaited(_initializeDepthService());
    _yoloController.setThresholds(
      confidenceThreshold: _confidenceThreshold,
      iouThreshold: _iouThreshold,
      numItemsThreshold: _numItemsThreshold,
    );
  }

  static double _defaultConfidence(ModelType model) {
    switch (model) {
      case ModelType.Interior:
      case ModelType.Exterior:
        return 0.5;
      case ModelType.LectorCarteles:
        return 0.45;
    }
  }

  static int _defaultNumItems(ModelType model) {
    switch (model) {
      case ModelType.Interior:
      case ModelType.Exterior:
        return 30;
      case ModelType.LectorCarteles:
        return 10;
    }
  }

  /// Initialize the controller
  Future<void> initialize() async {
    await _loadModelForPlatform();
    _yoloController.setThresholds(
      confidenceThreshold: _confidenceThreshold,
      iouThreshold: _iouThreshold,
      numItemsThreshold: _numItemsThreshold,
    );
    _postProcessor.updateThresholds(iouThreshold: _iouThreshold);
  }

  /// Handle detection results and calculate FPS
  void onDetectionResults(List<YOLOResult> results, Uint8List? originalImage) {
    if (_isDisposed) return;

    _annotateDistances(results);
    _frameCount++;
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsUpdate).inMilliseconds;
    _lastResultTimestamp = now;

    if (elapsed >= 1000) {
      _currentFps = _frameCount * 1000 / elapsed;
      _frameCount = 0;
      _lastFpsUpdate = now;
    }

    final previousObstacles =
    _processedDetections.closeObstacleLabels.join('|');
    final previousMovements =
    _processedDetections.movementWarnings.join('|');
    final previousSignal = _processedDetections.trafficLightSignal;

    final processed = _postProcessor.process(results);
    final filtered = processed.filteredResults;
    final hasCartelDetections = filtered.any(
      (d) => isCartelLabel(extractLabel(d)),
    );

    bool shouldNotify = false;
    if (_selectedModel == ModelType.LectorCarteles) {
      if (!hasCartelDetections) {
        _cachedCartelImage = null;
        _cachedCartelImageTimestamp = null;
        _lastAnnouncedOcrMessage = null;
        _lastAnnouncedOcrTimestamp = null;
        shouldNotify = true;
      }
    }
    final filteredCount = filtered.length;

    if (_detectionCount != filteredCount) {
      _detectionCount = filteredCount;
      shouldNotify = true;
    }

    if (filteredCount > 0) {
      _lastNonEmptyResult = now;
      if (_cameraAlert != null) {
        _cameraAlert = null;
        shouldNotify = true;
      }
    }

    final newObstacles = processed.closeObstacleLabels.join('|');
    final newMovements = processed.movementWarnings.join('|');

    if (previousObstacles != newObstacles ||
        previousMovements != newMovements ||
        previousSignal != processed.trafficLightSignal) {
      shouldNotify = true;
    }

    if (_connectionAlert != null) {
      _connectionAlert = null;
      shouldNotify = true;
    }

    _processedDetections = processed;
    _safetyAlerts = SafetyAlerts(
      connectionAlert: _connectionAlert,
      cameraAlert: _cameraAlert,
    );

    if (shouldNotify) {
      notifyListeners();
    }

    // --- Lógica de OCR (modo captura) ---
    if (_selectedModel == ModelType.LectorCarteles &&
        originalImage != null &&
        !_isOcrBusy &&
        !_isCaptureOcrActive &&
        processed.filteredResults.isNotEmpty) {
      final now = DateTime.now();
      if (now.difference(_lastOcrTimestamp).inMilliseconds > 1500) {
        _lastOcrTimestamp = now;
        _setVoiceFeedbackPaused(true);
        _isOcrBusy = true;
        _isCaptureOcrActive = true;

        _voiceResumeTimer?.cancel();
        _voiceResumeTimer = Timer(const Duration(seconds: 8), () {
          if (_isDisposed) return;
          if (_isVoiceFeedbackPaused) {
            _setVoiceFeedbackPaused(false);
          }
        });

        unawaited(
          _captureAndReadSign(originalImage, processed, now),
        );
      }
    }
    // --- Fin Lógica de OCR ---

    unawaited(
      _voiceAnnouncer.processDetections(
        filtered,
        isVoiceEnabled: _isVoiceEnabled && !_isVoiceFeedbackPaused,
        insights: processed,
        alerts: _safetyAlerts,
      ),
    );
  }

  /// Handle performance metrics
  void onPerformanceMetrics(double fps) {
    if (_isDisposed) return;

    if ((_currentFps - fps).abs() > 0.1) {
      _currentFps = fps;
      notifyListeners();
    }
  }

  void onZoomChanged(double zoomLevel) {
    if (_isDisposed || _areControlsLocked) return;

    if ((_currentZoomLevel - zoomLevel).abs() > 0.01) {
      _currentZoomLevel = zoomLevel;
      _yoloController.setZoomLevel(zoomLevel);
      notifyListeners();
    }
  }

  void handleStreamingData(Map<String, dynamic> data) {
    if (_isDisposed) return;
    unawaited(_processStreamingData(data));
  }

  Future<void> _processStreamingData(Map<String, dynamic> data) async {
    if (_isDisposed) return;

    final fpsValue = data['fps'];
    if (fpsValue is num) {
      onPerformanceMetrics(fpsValue.toDouble());
    }

    final detectionsData = data['detections'];
    final results = <YOLOResult>[];
    if (detectionsData is List) {
      for (final detection in detectionsData) {
        if (detection is Map) {
          try {
            results.add(YOLOResult.fromMap(detection));
          } catch (error, stackTrace) {
            debugPrint(
              'CameraInferenceController: error parsing detection - $error',
            );
            debugPrint('$stackTrace');
          }
        }
      }
    }

    Uint8List? originalImage;
    final imageData = data['originalImage'];
    if (imageData is Uint8List) {
      originalImage = imageData;
    }

    if (originalImage != null && results.isNotEmpty) {
      if (_isDepthProcessingEnabled) {
        final depthService = _depthService;
        if (depthService != null) {
          final depthFrame = await depthService.estimateDepth(originalImage);
          if (_isDisposed) return;
          _latestDepthFrame = depthFrame;
        } else {
          _latestDepthFrame = null;
        }
      } else {
        _latestDepthFrame = null;
      }
    }

    if (_isDisposed) return;
    onDetectionResults(results, originalImage);
  }

  Future<void> _captureAndReadSign(
    Uint8List imageBytes,
    ProcessedDetections processed,
    DateTime detectionTime,
  ) async {
    if (_isDisposed) return;

    try {
      final cartelDetections = processed.filteredResults
          .where((d) => isCartelLabel(extractLabel(d)))
          .toList();

      if (cartelDetections.isEmpty) {
        return;
      }

      _cachedCartelImage = Uint8List.fromList(imageBytes);
      _cachedCartelImageTimestamp = detectionTime;
      if (!_isDisposed) {
        notifyListeners();
      }

      final tempDir = await getTemporaryDirectory();
      if (_isDisposed) return;

      final filePath = path.join(
        tempDir.path,
        'cartel_${detectionTime.millisecondsSinceEpoch}.jpg',
      );
      final file = File(filePath);
      await file.writeAsBytes(imageBytes, flush: true);
      if (_isDisposed) return;

      final input = InputImage.fromFilePath(filePath);

      final recognized = await _textRecognizer.processImage(input);
      if (_isDisposed) return;

      final img.Image? decoded = await compute(img.decodeImage, imageBytes);
      if (decoded == null) {
        debugPrint('OCR capture error: failed to decode image size.');
        return;
      }
      if (_isDisposed) return;

      final int w = decoded.width;
      final int h = decoded.height;

      final buffer = StringBuffer();
      for (final cartel in cartelDetections) {
        final rawCartelRect = extractBoundingBox(cartel);
        if (rawCartelRect == null) continue;

        final rect = _normalizedRect(
          rawCartelRect,
          w.toDouble(),
          h.toDouble(),
        );
        if (rect == null) continue;

        final textBuffer = StringBuffer();
        for (final block in recognized.blocks) {
          final blockRect = Rect.fromLTWH(
            block.boundingBox.left / w,
            block.boundingBox.top / h,
            block.boundingBox.width / w,
            block.boundingBox.height / h,
          );
          if (rect.overlaps(blockRect)) {
            textBuffer
              ..write(block.text.replaceAll('\n', ' '))
              ..write(' ');
          }
        }

        final text = textBuffer.toString().trim();
        if (text.isNotEmpty) {
          buffer
            ..write(text)
            ..write('. ');
        }
      }

      final announcement = buffer.toString().trim();
      final safeAnnouncement = announcement.isNotEmpty
          ? announcement
          : recognized.text.replaceAll('\n', ' ').trim();

      final String finalAnnouncement = safeAnnouncement.isNotEmpty
          ? 'Cartel detectado. Dice: $safeAnnouncement'
          : 'Cartel detectado, pero no se pudo leer texto.';
      final trimmedAnnouncement = finalAnnouncement.trim();

      debugPrint(
        'OCR/VOICE -> finalAnnouncement="$trimmedAnnouncement" (len=${trimmedAnnouncement.length})',
      );

      final now = DateTime.now();
      if (_lastAnnouncedOcrMessage == trimmedAnnouncement &&
          _lastAnnouncedOcrTimestamp != null &&
          now.difference(_lastAnnouncedOcrTimestamp!) <
              const Duration(seconds: 10)) {
        debugPrint(
          'OCR/VOICE -> bloqueado por antispam (mismo mensaje <10s).',
        );
        return;
      }

      _lastAnnouncedOcrMessage = trimmedAnnouncement;
      _lastAnnouncedOcrTimestamp = now;

      await _announceSystemMessage(
        trimmedAnnouncement,
        force: true,
        bypassCooldown: true,
      );
      debugPrint('OCR/VOICE -> speak enqueued');
    } catch (e) {
      debugPrint('OCR capture error: $e');
    } finally {
      _isOcrBusy = false;
      _isCaptureOcrActive = false;
      _voiceResumeTimer?.cancel();
      _voiceResumeTimer = null;
      if (_isVoiceFeedbackPaused) {
        if (_isDisposed) {
          _isVoiceFeedbackPaused = false;
        } else {
          _setVoiceFeedbackPaused(false);
        }
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  Rect? _normalizedRect(Rect rect, double imageWidth, double imageHeight) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return null;
    }

    const double tolerance = 1e-3;
    final isAlreadyNormalized = rect.left >= -tolerance &&
        rect.top >= -tolerance &&
        rect.right <= 1.0 + tolerance &&
        rect.bottom <= 1.0 + tolerance;

    if (isAlreadyNormalized) {
      return rect;
    }

    Rect scaled = Rect.fromLTRB(
      rect.left / imageWidth,
      rect.top / imageHeight,
      rect.right / imageWidth,
      rect.bottom / imageHeight,
    );

    scaled = Rect.fromLTRB(
      scaled.left.clamp(0.0, 1.0),
      scaled.top.clamp(0.0, 1.0),
      scaled.right.clamp(0.0, 1.0),
      scaled.bottom.clamp(0.0, 1.0),
    );

    if (scaled.width <= 0 || scaled.height <= 0) {
      return null;
    }

    return scaled;
  }

  void _annotateDistances(List<YOLOResult> results) {
    if (results.isEmpty) return;

    final estimator = _distanceEstimator;
    final depthFrame = _latestDepthFrame;

    if (estimator == null && depthFrame == null) {
      if (!_loggedMissingDistanceEstimator) {
        debugPrint(
          'DistanceEstimator: estimador no disponible y sin mapa de profundidad, se omiten las distancias.',
        );
        _loggedMissingDistanceEstimator = true;
      }
      for (final result in results) {
        result.distanceM = null;
      }
      return;
    }

    for (final result in results) {
      final label = extractLabel(result).toLowerCase();
      double? depthDistance;
      if (depthFrame != null) {
        depthDistance = depthFrame.estimateDistance(result.normalizedBox);
        if (depthDistance != null) {
          debugPrint(
            'DepthInference: clase=$label depthDistance=${depthDistance.toStringAsFixed(2)}m',
          );
        }
      }

      double? geometricDistance;
      if (estimator != null) {
        geometricDistance =
            _estimateGeometricDistance(result, estimator, label);
      }

      result.distanceM =
          _combineDistanceEstimates(depthDistance, geometricDistance);
    }
  }

  double? _combineDistanceEstimates(double? depth, double? geometric) {
    if (depth != null && geometric != null) {
      return (depth * 0.7) + (geometric * 0.3);
    }
    return depth ?? geometric;
  }

  double? _estimateGeometricDistance(
      YOLOResult result,
      DistanceEstimator estimator,
      String label,
      ) {
    final rect = extractBoundingBox(result);
    // --- INICIO DE CORRECCIÓN (FALLBACK) ---
    final imageHeight = extractImageHeightPx(result) ?? 480;
    // --- FIN DE CORRECCIÓN (FALLBACK) ---

    if (rect == null) {
      debugPrint('DistanceEstimator: sin bounding box para $label.');
      return null;
    }

    if (imageHeight <= 0) { // Quitado el chequeo de null
      debugPrint('DistanceEstimator: sin altura de imagen para $label.');
      return null;
    }

    var bboxHeightRelative = rect.height;
    if (bboxHeightRelative.isNaN ||
        bboxHeightRelative.isInfinite ||
        bboxHeightRelative <= 0) {
      debugPrint(
          'DistanceEstimator: altura inválida de bounding box para $label.');
      return null;
    }

    double bboxHeightPx;
    if (bboxHeightRelative > 1.0) {
      bboxHeightPx = bboxHeightRelative;
      bboxHeightRelative = bboxHeightPx / imageHeight;
    } else {
      bboxHeightRelative = bboxHeightRelative.clamp(0.0, 1.0);
      bboxHeightPx = bboxHeightRelative * imageHeight;
    }

    if (bboxHeightPx <= 1) {
      debugPrint(
        'DistanceEstimator: bounding box muy pequeño para $label (bboxHeightPx=${bboxHeightPx.toStringAsFixed(2)}).',
      );
      return null;
    }

    final distance = estimator.distanceMeters(
      detectedClass: label,
      bboxHeightRelative: bboxHeightRelative,
      imageHeightPx: imageHeight,
    );

    if (distance == null) {
      debugPrint(
        'DistanceEstimator: no se puede estimar distancia para $label (bboxHeightPx=${bboxHeightPx.toStringAsFixed(2)}).',
      );
    } else {
      debugPrint(
        'DistanceEstimator: clase=$label bboxHeightPx=${bboxHeightPx.toStringAsFixed(2)} distanceM=${distance.toStringAsFixed(2)}.',
      );
    }

    return distance;
  }

  void toggleSlider(SliderType type) {
    if (_isDisposed || _areControlsLocked) return;

    final newValue = _activeSlider == type ? SliderType.none : type;
    if (newValue != _activeSlider) {
      _activeSlider = newValue;
      notifyListeners();
    }
  }

  void updateSliderValue(double value) {
    if (_isDisposed || _areControlsLocked) return;

    bool changed = false;
    switch (_activeSlider) {
      case SliderType.numItems:
        final newValue = value.toInt();
        if (_numItemsThreshold != newValue) {
          _numItemsThreshold = newValue;
          _yoloController.setNumItemsThreshold(_numItemsThreshold);
          changed = true;
        }
        break;
      case SliderType.confidence:
        if ((_confidenceThreshold - value).abs() > 0.01) {
          _confidenceThreshold = value;
          _yoloController.setConfidenceThreshold(value);
          changed = true;
        }
        break;
      case SliderType.iou:
        if ((_iouThreshold - value).abs() > 0.01) {
          _iouThreshold = value;
          _yoloController.setIoUThreshold(value);
          _postProcessor.updateThresholds(iouThreshold: value);
          changed = true;
        }
        break;
      default:
        break;
    }

    if (changed) {
      notifyListeners();
    }
  }

  void setZoomLevel(double zoomLevel) {
    if (_isDisposed || _areControlsLocked) return;

    if ((_currentZoomLevel - zoomLevel).abs() > 0.01) {
      _currentZoomLevel = zoomLevel;
      _yoloController.setZoomLevel(zoomLevel);
      notifyListeners();
    }
  }

  void flipCamera() {
    if (_isDisposed || _areControlsLocked) return;

    _isFrontCamera = !_isFrontCamera;
    if (_isFrontCamera) _currentZoomLevel = 1.0;
    _yoloController.switchCamera();
    notifyListeners();
  }

  void toggleVoice({bool announce = true}) {
    if (_isDisposed || _areControlsLocked) return;

    _isVoiceEnabled = !_isVoiceEnabled;
    if (!_isVoiceEnabled) {
      unawaited(_voiceAnnouncer.stop());
    }
    final status =
    _isVoiceEnabled ? 'Narración activada.' : 'Narración desactivada.';
    _voiceCommandStatus = status;
    if (announce) {
      unawaited(
        _announceSystemMessage(
          status,
          force: true,
          bypassCooldown: true,
        ),
      );
    }
    notifyListeners();
  }

  void increaseFontScale() {
    if (_isDisposed || _areControlsLocked) return;

    final newScale = (_fontScale + 0.1).clamp(0.8, 2.0);
    if ((newScale - _fontScale).abs() > 0.01) {
      _fontScale = newScale;
      _voiceCommandStatus = 'Tamaño de texto aumentado.';
      notifyListeners();
    }
  }

  void decreaseFontScale() {
    if (_isDisposed || _areControlsLocked) return;

    final newScale = (_fontScale - 0.1).clamp(0.8, 2.0);
    if ((newScale - _fontScale).abs() > 0.01) {
      _fontScale = newScale;
      _voiceCommandStatus = 'Tamaño de texto reducido.';
      notifyListeners();
    }
  }

  Future<void> repeatLastInstruction() => _voiceAnnouncer.repeatLastMessage();

  void toggleControlsLock() {
    if (_isDisposed) return;

    _areControlsLocked = !_areControlsLocked;
    if (_areControlsLocked && _activeSlider != SliderType.none) {
      _activeSlider = SliderType.none;
    }
    if (_areControlsLocked && _isListeningForCommand) {
      unawaited(_cancelVoiceCommand());
    }
    notifyListeners();
  }

  void onVoiceCommandRequested() {
    if (_isDisposed || _areControlsLocked) return;

    if (_isListeningForCommand) {
      unawaited(_cancelVoiceCommand());
    } else {
      unawaited(_startVoiceCommand());
    }
  }

  void onVoiceCommandHoldStart() {
    if (_isDisposed || _areControlsLocked) return;

    if (_voiceCommandService.isListening || _isListeningForCommand) {
      return;
    }

    unawaited(_startVoiceCommand());
  }

  void onVoiceCommandHoldEnd() {
    if (_isDisposed) return;

    if (_areControlsLocked) {
      if (_isListeningForCommand || _voiceCommandService.isListening) {
        unawaited(_cancelVoiceCommand());
      }
      return;
    }

    if (_voiceCommandService.isListening) {
      _isListeningForCommand = false;
      _voiceCommandStatus = 'Procesando comando...';
      notifyListeners();
      unawaited(_voiceCommandService.stopListening());
    } else if (_isListeningForCommand) {
      _isListeningForCommand = false;
      _voiceCommandStatus = null;
      _setVoiceFeedbackPaused(false);
      notifyListeners();
      unawaited(_voiceCommandService.cancelListening());
    }
  }

  void updateVoiceSettings(VoiceSettings settings) {
    if (_isDisposed) return;

    _voiceSettings = settings;
    unawaited(_voiceAnnouncer.updateSettings(settings));
    _voiceCommandStatus = 'Configuración de voz actualizada.';
    notifyListeners();
  }

  Future<void> refreshWeather() async {
    await _refreshWeather(force: true);
  }

  Future<void> handleVoiceCommand(IntentRecognitionResult result) async {
    if (_isDisposed) return;

    final confidence = result.score;
    if (confidence < _intentConfidenceThreshold) {
      await _handleUnrecognizedVoiceCommand();
      return;
    }

    final label = result.label.toLowerCase();
    String? feedback;
    var recognized = true;

    switch (result.group) {
      case IntentGroup.camaraRepetir:
        feedback = 'Repitiendo la última instrucción.';
        await repeatLastInstruction();
        break;
      case IntentGroup.camaraTexto:
        if (_labelIndicatesDecrease(label)) {
          decreaseFontScale();
          feedback = 'Tamaño de texto reducido.';
        } else {
          increaseFontScale();
          feedback = 'Tamaño de texto aumentado.';
        }
        break;
      case IntentGroup.camaraVoz:
        final enable = _labelIndicatesEnable(label);
        final disable = _labelIndicatesDisable(label);
        if (enable && !_isVoiceEnabled) {
          toggleVoice(announce: false);
          feedback = 'Narración activada.';
        } else if (disable && _isVoiceEnabled) {
          toggleVoice(announce: false);
          feedback = 'Narración desactivada.';
        } else if (enable && _isVoiceEnabled) {
          feedback = 'La narración ya está activada.';
        } else if (disable && !_isVoiceEnabled) {
          feedback = 'La narración ya estaba desactivada.';
        } else {
          recognized = false;
        }
        break;
      case IntentGroup.camaraAyuda:
        feedback =
            'Puedes pedirme que repita instrucciones, cambiar el tamaño de texto, activar o desactivar la narración, controlar el lector de carteles, ajustar el zoom, preguntar la hora o consultar el clima.';
        break;
      case IntentGroup.camaraZoom:
        final zoomOut =
            _labelIndicatesDecrease(label) || label.contains('aleja') || label.contains('alejar');
        _adjustZoomLevel(zoomOut ? -_zoomStep : _zoomStep);
        feedback = zoomOut ? 'Alejando zoom.' : 'Acercando zoom.';
        break;
      case IntentGroup.camaraLectorCarteles:
        feedback = _handleSignReaderCommand(label);
        if (feedback == null) {
          recognized = false;
        }
        break;
      case IntentGroup.menu:
        feedback = 'Opciones disponibles: Dinero, Objetos, Profundidad, Lectura, Hora y Clima.';
        break;
      case IntentGroup.hora:
        feedback = 'Son las $formattedTime.';
        break;
      case IntentGroup.clima:
        feedback = 'Actualizando clima.';
        unawaited(refreshWeather());
        break;
      case IntentGroup.dinero:
      case IntentGroup.profundidad:
      case IntentGroup.lectura:
        feedback = 'Para cambiar de modo regresa al menú principal.';
        break;
      case IntentGroup.objetos:
        feedback = _buildDetectionSummary();
        break;
      case IntentGroup.unknown:
        recognized = false;
        break;
    }

    if (!recognized) {
      await _handleUnrecognizedVoiceCommand();
      return;
    }

    _voiceCommandStatus = feedback;
    notifyListeners();

    if (feedback != null) {
      await _announceSystemMessage(
        feedback,
        force: true,
        bypassCooldown: true,
      );
    }
  }

  Future<void> _handleUnrecognizedVoiceCommand() async {
    _voiceCommandStatus = 'Comando no reconocido.';
    notifyListeners();
    await _announceSystemMessage(
      'No entendí el comando. Por favor, repítelo.',
      force: true,
      bypassCooldown: true,
    );
  }

  String _buildDetectionSummary() {
    final count = _detectionCount;
    if (count <= 0) {
      return 'No detecto objetos ahora.';
    }
    final label = count == 1 ? 'objeto' : 'objetos';
    return 'Detecto $count $label.';
  }

  void _adjustZoomLevel(double delta) {
    final newZoom = (_currentZoomLevel + delta).clamp(_minZoomLevel, _maxZoomLevel);
    setZoomLevel(newZoom);
  }

  String? _handleSignReaderCommand(String label) {
    final enable = _labelIndicatesEnable(label);
    final disable = _labelIndicatesDisable(label);

    if (enable && !disable) {
      final wasEnabled = _isSignReaderEnabled;
      setSignReaderEnabled(true);
      if (_isSignReaderEnabled && !wasEnabled) {
        return 'Lector de carteles activado.';
      }
      if (_isSignReaderEnabled) {
        return 'El lector de carteles ya estaba activado.';
      }
      return 'No se pudo activar el lector de carteles.';
    }

    if (disable && !enable) {
      final wasEnabled = _isSignReaderEnabled;
      setSignReaderEnabled(false);
      if (!_isSignReaderEnabled && wasEnabled) {
        return 'Lector de carteles desactivado.';
      }
      if (!_isSignReaderEnabled) {
        return 'El lector de carteles ya estaba desactivado.';
      }
      return 'No se pudo desactivar el lector de carteles.';
    }

    return null;
  }

  bool _labelIndicatesDecrease(String label) {
    const keywords = [
      'baja',
      'dismin',
      'reduce',
      'achica',
      'menos',
      'pequen',
      'pequeñ',
      'aleja',
      'alejar',
      'decrementa',
    ];
    return keywords.any(label.contains);
  }

  bool _labelIndicatesEnable(String label) {
    const keywords = [
      'activa',
      'activar',
      'enciende',
      'encender',
      'habilita',
      'habilitar',
      'prende',
      'prender',
    ];
    return keywords.any(label.contains);
  }

  bool _labelIndicatesDisable(String label) {
    const keywords = [
      'desactiva',
      'desactivar',
      'apaga',
      'apagar',
      'silencia',
      'silenciar',
      'deshabilita',
      'deshabilitar',
      'quita',
      'quitar',
      'cierra',
    ];
    return keywords.any(label.contains);
  }

  Future<void> _startVoiceCommand() async {
    if (_isDisposed) return;

    _isListeningForCommand = true;
    _setVoiceFeedbackPaused(true);
    _voiceCommandStatus = 'Preparando micrófono...';
    notifyListeners();

    final started = await _voiceCommandService.startListening(
      listenFor: const Duration(seconds: 2),
      onResult: (result) {
        if (_isDisposed) return;
        _isListeningForCommand = false;
        _setVoiceFeedbackPaused(false);
        notifyListeners();
        unawaited(_processVoiceCommandResult(result));
      },
      onError: (message) {
        if (_isDisposed) return;
        _isListeningForCommand = false;
        _voiceCommandStatus = message;
        _setVoiceFeedbackPaused(false);
        notifyListeners();
        unawaited(
          _announceSystemMessage(
            message,
            force: true,
            bypassCooldown: true,
          ),
        );
      },
      onStatus: (listening) {
        if (_isDisposed) return;
        _isListeningForCommand = listening;
        if (listening) {
          _voiceCommandStatus = 'Escuchando...';
          _setVoiceFeedbackPaused(true);
        } else if (!_isProcessingVoiceCommand &&
            (_voiceCommandStatus == 'Escuchando...' ||
                _voiceCommandStatus == 'Preparando micrófono...')) {
          _voiceCommandStatus = null;
          _setVoiceFeedbackPaused(false);
        }
        notifyListeners();
      },
    );

    if (!started && !_isDisposed) {
      _isListeningForCommand = false;
      _voiceCommandStatus ??= 'No fue posible iniciar la escucha.';
      _setVoiceFeedbackPaused(false);
      notifyListeners();
      final status = _voiceCommandStatus;
      if (status != null && status.isNotEmpty) {
        unawaited(
          _announceSystemMessage(
            status,
            force: true,
            bypassCooldown: true,
          ),
        );
      }
    }
  }

  Future<void> _processVoiceCommandResult(
    IntentRecognitionResult result,
  ) async {
    if (_isDisposed) return;

    _isProcessingVoiceCommand = true;
    try {
      await handleVoiceCommand(result);
    } finally {
      if (_isDisposed) {
        // No hacer nada si está 'disposed'
      } else {
        _isProcessingVoiceCommand = false;
        _setVoiceFeedbackPaused(false);
        notifyListeners();
      }
    }
  }

  Future<void> _cancelVoiceCommand() async {
    await _voiceCommandService.cancelListening();
    if (_isDisposed) return;

    final wasListening = _isListeningForCommand;
    _isListeningForCommand = false;
    _setVoiceFeedbackPaused(false);
    _voiceCommandStatus =
    wasListening ? 'Escucha cancelada.' : _voiceCommandStatus;
    notifyListeners();
    if (wasListening) {
      unawaited(
        _announceSystemMessage(
          'Escucha cancelada.',
          force: true,
          bypassCooldown: true,
        ),
      );
    }
  }

  void handleModelSelection(ModelType model) {
    if (_isDisposed) return;

    if (model == ModelType.Exterior) {
      if (_isSignReaderEnabled) {
        setSignReaderEnabled(false);
      } else {
        changeModel(ModelType.Exterior);
      }
      return;
    }

    if (_isSignReaderEnabled) {
      _isSignReaderEnabled = false;
      _modelBeforeSignReader = null;
    }

    changeModel(model);
  }

  void setSignReaderEnabled(bool value) {
    if (_isDisposed) return;

    if (_isSignReaderEnabled == value) {
      return;
    }

    if (_areControlsLocked || _isModelLoading || _isProcessingVoiceCommand) {
      return;
    }

    final now = DateTime.now();
    if (_lastSignToggleTimestamp != null &&
        now.difference(_lastSignToggleTimestamp!) < _signToggleCooldown) {
      return;
    }

    if (value) {
      if (_selectedModel != ModelType.Exterior &&
          _selectedModel != ModelType.LectorCarteles) {
        return;
      }
      _lastSignToggleTimestamp = now;
      _modelBeforeSignReader = _selectedModel == ModelType.LectorCarteles
          ? (_modelBeforeSignReader ?? ModelType.Exterior)
          : _selectedModel;
      _isSignReaderEnabled = true;
      notifyListeners();
      if (_selectedModel != ModelType.LectorCarteles) {
        changeModel(ModelType.LectorCarteles);
      }
      return;
    }

    if (!_isSignReaderEnabled) {
      return;
    }

    _lastSignToggleTimestamp = now;
    final fallback = _modelBeforeSignReader ?? ModelType.Exterior;
    _isSignReaderEnabled = false;
    _modelBeforeSignReader = null;
    notifyListeners();
    if (_selectedModel != fallback) {
      changeModel(fallback);
    } else if (_selectedModel == ModelType.LectorCarteles) {
      changeModel(ModelType.Exterior);
    }
  }

  void changeModel(ModelType model) {
    if (_isDisposed) return;

    if (!_isModelLoading && model != _selectedModel) {
      _selectedModel = model;
      _confidenceThreshold = _defaultConfidence(model);
      _numItemsThreshold = _defaultNumItems(model);
      _yoloController.setThresholds(
        confidenceThreshold: _confidenceThreshold,
        iouThreshold: _iouThreshold,
        numItemsThreshold: _numItemsThreshold,
      );
      _postProcessor.clearHistory();
      if (model == ModelType.LectorCarteles) {
        _isSignReaderEnabled = true;
      } else {
        if (_isSignReaderEnabled) {
          _isSignReaderEnabled = false;
        }
        if (model != ModelType.LectorCarteles) {
          _modelBeforeSignReader = null;
        }
      }
      notifyListeners();
      _loadModelForPlatform();
    }
  }

  Future<void> _loadModelForPlatform() async {
    if (_isDisposed) return;

    if (_loadingFuture != null) {
      await _loadingFuture;
      return;
    }

    _loadingFuture = _performModelLoading();
    try {
      await _loadingFuture;
    } finally {
      _loadingFuture = null;
    }
  }

  Future<void> _performModelLoading() async {
    if (_isDisposed) return;

    _isModelLoading = true;
    _loadingMessage = 'Loading ${_selectedModel.modelName} model...';
    _downloadProgress = 0.0;
    _detectionCount = 0;
    _currentFps = 0.0;
    _postProcessor.clearHistory();
    _processedDetections = ProcessedDetections.empty;
    _safetyAlerts = const SafetyAlerts();
    notifyListeners();

    try {
      final modelPath = await _modelManager.getModelPath(_selectedModel);

      if (_isDisposed) return;

      _modelPath = modelPath;
      _isModelLoading = false;
      _loadingMessage = '';
      _downloadProgress = 0.0;
      notifyListeners();

      if (modelPath == null) {
        throw Exception('Failed to load ${_selectedModel.modelName} model');
      }
    } catch (e) {
      if (_isDisposed) return;

      final error = YOLOErrorHandler.handleError(
        e,
        'Failed to load model ${_selectedModel.modelName} for task ${_selectedModel.task.name}',
      );

      _isModelLoading = false;
      _loadingMessage = 'Failed to load model: ${error.message}';
      _downloadProgress = 0.0;
      notifyListeners();
      rethrow;
    }
  }

  void _onStatusTick() {
    if (_isDisposed) return;

    final now = DateTime.now();
    bool shouldNotify = false;

    if (now.difference(_currentTime).inSeconds >= 1) {
      _currentTime = now;
      shouldNotify = true;
    }

    final hasModel = _modelPath != null && !_isModelLoading;
    final connectionDelay = now.difference(_lastResultTimestamp);
    String? newConnectionAlert;
    if (hasModel && connectionDelay > const Duration(seconds: 5)) {
      newConnectionAlert =
      'No recibo datos de detección, revisa tu conexión o reinicia la cámara.';
    }

    if (newConnectionAlert != _connectionAlert) {
      _connectionAlert = newConnectionAlert;
      shouldNotify = true;
    }

    String? newCameraAlert = _cameraAlert;
    final lastNonEmpty = _lastNonEmptyResult;
    if (lastNonEmpty != null) {
      if (now.difference(lastNonEmpty) > const Duration(seconds: 6)) {
        newCameraAlert =
        'No detecto objetos desde hace varios segundos, verifica que la cámara no esté obstruida.';
      }
    } else if (hasModel && connectionDelay > const Duration(seconds: 8)) {
      newCameraAlert = 'No puedo ver la imagen de la cámara.';
    } else if (hasModel && connectionDelay < const Duration(seconds: 3)) {
      newCameraAlert = null;
    }

    if (newCameraAlert != _cameraAlert) {
      _cameraAlert = newCameraAlert;
      shouldNotify = true;
    }

    _safetyAlerts = SafetyAlerts(
      connectionAlert: _connectionAlert,
      cameraAlert: _cameraAlert,
    );

    if (now.difference(_lastWeatherFetch) > const Duration(minutes: 30)) {
      unawaited(_refreshWeather());
    }

    if (shouldNotify) {
      notifyListeners();
    }
  }

  Future<void> _refreshWeather({bool force = false}) async {
    if (_isDisposed) return;

    final now = DateTime.now();
    if (!force &&
        now.difference(_lastWeatherFetch) < const Duration(minutes: 15)) {
      return;
    }

    final info = await _weatherService.loadCurrentWeather();
    if (_isDisposed) return;

    _lastWeatherFetch = now;
    if (info != null) {
      _weatherInfo = info;
      final summary = info.formatSummary();
      if (force) {
        final message = 'El clima actual es $summary';
        _voiceCommandStatus = message;
        notifyListeners();
        unawaited(
          _announceSystemMessage(
            message,
            force: force,
            bypassCooldown: force,
          ),
        );
      } else {
        _voiceCommandStatus = 'Clima actualizado.';
        notifyListeners();
      }
    } else if (force) {
      _voiceCommandStatus = 'No fue posible obtener el clima.';
      notifyListeners();
      unawaited(
        _announceSystemMessage(
          'No fue posible obtener el clima actual.',
          force: true,
          bypassCooldown: true,
        ),
      );
    }
  }

  Future<void> _loadDistanceEstimator() async {
    try {
      final estimator = await _distanceEstimatorProvider.load();
      if (_isDisposed) return;
      _distanceEstimator = estimator;
      if (estimator == null) {
        debugPrint(
          'DistanceEstimator: no se pudo cargar la calibración, se omiten las distancias.',
        );
      } else {
        _loggedMissingDistanceEstimator = false;
      }
    } catch (error, stackTrace) {
      if (_isDisposed) return;
      debugPrint('DistanceEstimator: error al cargar calibración - $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _initializeDepthService() async {
    try {
      final service = DepthInferenceService(sampleStep: 3);
      await service.initialize();
      if (_isDisposed) {
        await service.dispose();
        return;
      }
      _depthService = service;
      notifyListeners();
    } catch (error, stackTrace) {
      if (_isDisposed) return;
      debugPrint('DepthInferenceService: error al inicializar - $error');
      debugPrint('$stackTrace');
      notifyListeners();
    }
  }

  void setDepthProcessingEnabled(bool enabled) {
    if (_isDepthProcessingEnabled == enabled) return;
    _isDepthProcessingEnabled = enabled;
    if (!enabled) {
      _latestDepthFrame = null;
    }
    notifyListeners();
  }

  Future<void> _announceSystemMessage(
      String message, {
        bool force = false,
        bool bypassCooldown = false,
      }) async {
    if (!force && !_isVoiceEnabled) return;

    await _voiceAnnouncer.speakMessage(
      message,
      bypassCooldown: bypassCooldown || force,
      ignorePause: force,
      storeAsLastMessage: true,
    );
  }

  void _setVoiceFeedbackPaused(bool value) {
    if (_isVoiceFeedbackPaused == value) return;
    _isVoiceFeedbackPaused = value;
    _voiceAnnouncer.setPaused(value);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _voiceAnnouncer.dispose();
    unawaited(_intentRecognizer.dispose());
    _statusTimer?.cancel();
    _voiceResumeTimer?.cancel();
    _voiceResumeTimer = null;
    unawaited(_voiceCommandService.dispose());
    _weatherService.dispose();
    unawaited(_depthService?.dispose());
    _depthService = null;
    _latestDepthFrame = null;
    // --- INICIO DE MODIFICACIÓN ---
    _textRecognizer.close(); // Liberar recursos del OCR
    // --- FIN DE MODIFICACIÓN ---
    super.dispose();
  }
}