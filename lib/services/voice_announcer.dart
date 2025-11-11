
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/models/yolo_result.dart';
import '../core/tts/tts_helpers.dart';
import '../core/vision/cartel_labels.dart';
import '../core/vision/detection_distance_extension.dart';
import '../core/vision/detection_geometry.dart';
import '../models/detection_insight.dart';
import '../models/voice_settings.dart';

const Map<String, String> _labelTranslations = {
  'person': 'persona',
  'bicycle': 'bicicleta',
  'car': 'auto',
  'motorcycle': 'motocicleta',
  'motorbike': 'motocicleta',
  'airplane': 'avión',
  'aeroplane': 'avión',
  'bus': 'autobús',
  'train': 'tren',
  'truck': 'camión',
  'boat': 'barco',
  'traffic light': 'semáforo',
  'trafficlight': 'semáforo',
  'fire hydrant': 'hidrante',
  'firehydrant': 'hidrante',
  'stop sign': 'señal de alto',
  'parking meter': 'parquímetro',
  'parkingmeter': 'parquímetro',
  'bench': 'banco',
  'bird': 'pájaro',
  'cat': 'gato',
  'dog': 'perro',
  'horse': 'caballo',
  'sheep': 'oveja',
  'cow': 'vaca',
  'elephant': 'elefante',
  'bear': 'oso',
  'zebra': 'cebra',
  'giraffe': 'jirafa',
  'backpack': 'mochila',
  'umbrella': 'paraguas',
  'handbag': 'bolso',
  'tie': 'corbata',
  'suitcase': 'valija',
  'frisbee': 'frisbee',
  'skis': 'esquís',
  'snowboard': 'tabla de snowboard',
  'sports ball': 'pelota deportiva',
  'kite': 'cometa',
  'baseball bat': 'bate de béisbol',
  'baseball glove': 'guante de béisbol',
  'skateboard': 'patineta',
  'surfboard': 'tabla de surf',
  'tennis racket': 'raqueta de tenis',
  'tennisracket': 'raqueta de tenis',
  'bottle': 'botella',
  'wine glass': 'copa de vino',
  'wineglass': 'copa de vino',
  'cup': 'taza',
  'fork': 'tenedor',
  'knife': 'cuchillo',
  'spoon': 'cuchara',
  'bowl': 'bol',
  'banana': 'banana',
  'apple': 'manzana',
  'sandwich': 'sándwich',
  'orange': 'naranja',
  'broccoli': 'brócoli',
  'carrot': 'zanahoria',
  'hot dog': 'pancho',
  'pizza': 'pizza',
  'donut': 'donut',
  'cake': 'torta',
  'chair': 'silla',
  'couch': 'sofá',
  'potted plant': 'planta en maceta',
  'pottedplant': 'planta en maceta',
  'bed': 'cama',
  'dining table': 'mesa de comedor',
  'diningtable': 'mesa de comedor',
  'toilet': 'inodoro',
  'tv': 'televisor',
  'tv monitor': 'televisor',
  'tvmonitor': 'televisor',
  'laptop': 'computadora portátil',
  'mouse': 'ratón',
  'remote': 'control remoto',
  'keyboard': 'teclado',
  'cell phone': 'teléfono celular',
  'cellphone': 'teléfono celular',
  'mobile phone': 'teléfono móvil',
  'microwave': 'microondas',
  'oven': 'horno',
  'toaster': 'tostadora',
  'sink': 'lavabo',
  'refrigerator': 'refrigerador',
  'book': 'libro',
  'clock': 'reloj',
  'vase': 'florero',
  'scissors': 'tijeras',
  'teddy bear': 'oso de peluche',
  'teddybear': 'oso de peluche',
  'hair drier': 'secador de pelo',
  'hairdryer': 'secador de pelo',
  'toothbrush': 'cepillo de dientes',
};

class VoiceAnnouncer {
  VoiceAnnouncer({VoiceSettings initialSettings = const VoiceSettings()})
      : _settings = initialSettings.validated() {
    _initialization = _configure();
  }

  final FlutterTts _tts = FlutterTts();
  late final TtsHelper _ttsHelper = TtsHelper(_tts);
  Future<void>? _initialization;
  static const Duration _minimumPause = Duration(seconds: 3);
  static const double _closeDistanceThresholdMeters = 1.2;
  DateTime _lastAnnouncement = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCartelAnnouncedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _cartelCooldown = Duration(seconds: 8);
  bool _cartelWasPresent = false;
  String? _lastMessage;
  VoiceSettings _settings;
  bool _isPaused = false;
  bool _isSpeaking = false;
  _PendingSpeech? _pendingSpeech;

  Future<void> _configure() async {
    try {
      final validSettings = _settings.validated();
      _settings = validSettings;
      await _tts.setLanguage(validSettings.language);
      await _tts.setSpeechRate(validSettings.speechRate);
      await _tts.setPitch(validSettings.pitch);
      await _tts.setVolume(validSettings.volume);
      await _tts.awaitSpeakCompletion(true);
      try {
        _tts.setStartHandler(() {
          _isSpeaking = true;
        });
      } catch (_) {}
      try {
        _tts.setCompletionHandler(() {
          _isSpeaking = false;
        });
      } catch (_) {}
      try {
        _tts.setCancelHandler(() {
          _isSpeaking = false;
        });
      } catch (_) {}
      try {
        _tts.setErrorHandler((msg) {
          _isSpeaking = false;
        });
      } catch (_) {}
      await _disableExclusiveAudioFocus();
    } catch (_) {
      // Ignore configuration errors to avoid crashing voice flow.
    }
  }

  Future<void> processDetections(
    List<YOLOResult> results, {
    required bool isVoiceEnabled,
    ProcessedDetections insights = ProcessedDetections.empty,
    SafetyAlerts alerts = const SafetyAlerts(),
  }) async {
    if (!isVoiceEnabled) {
      _lastMessage = null;
      unawaited(_safeStop());
      return;
    }

    if (_isPaused) {
      _lastMessage = null;
      return;
    }

    await _ensureConfigured();

    final now = DateTime.now();
    final message = _buildMessage(results, insights, alerts, now);
    if (message == null) {
      return;
    }

    final bool isCartelMessage = message == 'Cartel detectado.';

    if (!isCartelMessage && _shouldRespectCooldown(now)) {
      return;
    }

    if (!isCartelMessage && message == _lastMessage) {
      return;
    }

    await _speak(message);
  }

  Future<void> stop() => _safeStop();

  void setPaused(bool value) {
    if (_isPaused == value) return;
    _isPaused = value;
    _lastMessage = null;
  }

  Future<void> updateSettings(VoiceSettings settings) async {
    _settings = settings.validated();
    try {
      await _tts.setLanguage(_settings.language);
    } catch (_) {}
    try {
      await _tts.setSpeechRate(_settings.speechRate);
    } catch (_) {}
    try {
      await _tts.setPitch(_settings.pitch);
    } catch (_) {}
    try {
      await _tts.setVolume(_settings.volume);
    } catch (_) {}
    await _disableExclusiveAudioFocus();
  }

  Future<void> repeatLastMessage() async {
    final message = _lastMessage;
    if (message == null) {
      return;
    }
    try {
      await _speak(message, storeAsLastMessage: false);
    } catch (_) {}
  }

  String? get lastMessage => _lastMessage;

  Future<void> speakMessage(
    String message, {
    bool bypassCooldown = false,
    bool storeAsLastMessage = true,
    bool ignorePause = false,
  }) async {
    if (message.trim().isEmpty || (_isPaused && !ignorePause)) {
      return;
    }

    await _ensureConfigured();

    final now = DateTime.now();
    if (!bypassCooldown && _shouldRespectCooldown(now)) {
      return;
    }

    await _speak(
      message,
      storeAsLastMessage: storeAsLastMessage,
    );
    debugPrint('VoiceAnnouncer -> speak enqueued (len=${message.length})');
  }

  Future<void> _safeStop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Ignore stop failures.
    }
    _pendingSpeech = null;
  }

  Future<void> _ensureConfigured() async {
    final init = _initialization;
    if (init != null) {
      await init;
      _initialization = null;
    }
  }

  bool _shouldRespectCooldown(DateTime now) {
    return now.difference(_lastAnnouncement) < _minimumPause;
  }

  Future<void> _speak(
    String message, {
    bool storeAsLastMessage = true,
  }) async {
    final request = _PendingSpeech(message, storeAsLastMessage);

    if (_isSpeaking) {
      _pendingSpeech = request;
      return;
    }

    await _playSpeech(request);
  }

  Future<void> _playSpeech(_PendingSpeech request) async {
    _isSpeaking = true;
    try {
      try {
        await _tts.setQueueMode(1);
      } catch (_) {}
      await _tts.speak(request.message);
      _lastAnnouncement = DateTime.now();
      if (request.storeAsLastMessage) {
        _lastMessage = request.message;
      }
    } catch (_) {
      // Ignore speak failures to keep detection loop running.
    } finally {
      _isSpeaking = false;
      final next = _pendingSpeech;
      _pendingSpeech = null;
      if (next != null) {
        await _playSpeech(next);
      }
    }
  }

  String? _buildMessage(
    List<YOLOResult> results,
    ProcessedDetections insights,
    SafetyAlerts alerts,
    DateTime now,
  ) {
    final alertMessages = alerts.toList();
    if (alertMessages.isNotEmpty) {
      return alertMessages.join(' ');
    }

    final filteredResults = insights.filteredResults.isNotEmpty
        ? insights.filteredResults
        : results;

    final hasCartelDetection = filteredResults.any(
      (result) => isCartelLabel(extractLabel(result)),
    );

    if (hasCartelDetection) {
      final shouldAnnounceCartel = !_cartelWasPresent ||
          now.difference(_lastCartelAnnouncedAt) > _cartelCooldown;
      _cartelWasPresent = true;
      if (shouldAnnounceCartel) {
        _lastCartelAnnouncedAt = now;
        return 'Cartel detectado.';
      }
      return null;
    }

    if (_cartelWasPresent) {
      _cartelWasPresent = false;
    }

    if (filteredResults.isEmpty) {
      if (_lastMessage == null) {
        return 'No detecto objetos frente a la cámara.';
      }
      _lastMessage = null;
      return null;
    }

    final descriptions = <String>[];
    String? warning;

    for (final result in filteredResults.take(3)) {
      final rawLabel = result.className.isNotEmpty ? result.className : 'objeto';
      final label = _localizeLabel(rawLabel);
      descriptions.add(label);

      if (warning == null && _isClose(result.distanceM)) {
        warning = 'Cuidado, $label está muy cerca.';
      }
    }

    if (descriptions.isEmpty) {
      return null;
    }

    final base = 'Veo ${descriptions.join(', ')}.';
    final movement = _describeMovementWarnings(insights) ?? '';

    final obstacle = insights.hasCloseObstacle
        ? ' Obstáculo cercano al frente: ${_localizeLabels(insights.closeObstacleLabels).join(', ')}.'
        : '';

    final traffic = _describeTrafficLight(insights.trafficLightSignal);

    return [base, warning, obstacle, movement, traffic]
        .where((element) => element != null && element.isNotEmpty)
        .join(' ')
        .trim();
  }

  bool _isClose(double? meters) {
    if (!_ttsHelper.hasValidDistance(meters)) {
      return false;
    }
    return meters! <= _closeDistanceThresholdMeters;
  }

  void dispose() {
    unawaited(_safeStop());
  }

  Future<void> _disableExclusiveAudioFocus() async {
    final dynamic tts = _tts;
    try {
      final result = tts.setAudioFocus(false);
      if (result is Future) {
        await result;
      }
    } catch (_) {
      // Ignore failures or missing platform support.
    }
  }

  String _localizeLabel(String label) {
    final normalized = label
        .toLowerCase()
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) {
      return 'objeto';
    }

    final translation = _labelTranslations[normalized];
    if (translation != null) {
      return translation;
    }

    if (normalized.endsWith('s')) {
      final singular = normalized.substring(0, normalized.length - 1);
      final singularTranslation = _labelTranslations[singular];
      if (singularTranslation != null) {
        return singularTranslation;
      }
    }

    return normalized;
  }

  Iterable<String> _localizeLabels(Iterable<String> labels) sync* {
    for (final label in labels) {
      yield _localizeLabel(label);
    }
  }

  String? _describeTrafficLight(TrafficLightSignal signal) {
    switch (signal) {
      case TrafficLightSignal.green:
        return 'Semáforo en verde, es seguro avanzar con precaución.';
      case TrafficLightSignal.red:
        return 'Semáforo en rojo, detente y espera.';
      case TrafficLightSignal.unknown:
        return null;
    }
  }

  String? _describeMovementWarnings(ProcessedDetections insights) {
    if (!insights.hasMovementWarnings) {
      return null;
    }

    final localized = insights.movementWarnings
        .map(_localizeMovementWarning)
        .where((warning) => warning.isNotEmpty)
        .toList();

    if (localized.isEmpty) {
      return null;
    }

    return ' Peligro en movimiento: ${localized.join(', ')}.';
  }

  String _localizeMovementWarning(String warning) {
    const suffix = ' acercándose rápidamente';
    if (warning.endsWith(suffix)) {
      final label = warning.substring(0, warning.length - suffix.length).trim();
      final localizedLabel = _localizeLabel(label);
      return '$localizedLabel$suffix';
    }
    return warning;
  }
}

class _PendingSpeech {
  const _PendingSpeech(this.message, this.storeAsLastMessage);

  final String message;
  final bool storeAsLastMessage;
}
