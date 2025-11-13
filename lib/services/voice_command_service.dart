import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'intent_recognizer.dart';

typedef VoiceCommandResultCallback = void Function(
    IntentRecognitionResult result);
typedef VoiceCommandErrorCallback = void Function(String message);
typedef VoiceCommandListeningCallback = void Function(bool isListening);

/// Captures short audio commands, classifies them with [IntentRecognizer] and
/// reports the resulting intent.
class VoiceCommandService {
  VoiceCommandService({IntentRecognizer? recognizer})
      : _recognizer = recognizer ?? IntentRecognizer();

  final IntentRecognizer _recognizer;
  final AudioRecorder _recorder = AudioRecorder();

  VoiceCommandResultCallback? _pendingResult;
  VoiceCommandErrorCallback? _pendingError;
  VoiceCommandListeningCallback? _pendingStatus;
  Timer? _autoStopTimer;
  bool _isListening = false;
  String? _currentRecordingPath;

  Duration listenDuration = const Duration(seconds: 2);

  bool get isListening => _isListening;

  Future<bool> startListening({
    required VoiceCommandResultCallback onResult,
    required VoiceCommandErrorCallback onError,
    VoiceCommandListeningCallback? onStatus,
    Duration? listenFor,
  }) async {
    if (_isListening) {
      await cancelListening();
    }

    try {
      await _recognizer.initialize();
    } catch (error, stackTrace) {
      debugPrint('No fue posible inicializar el IntentRecognizer: $error\n$stackTrace');
      onError('No fue posible preparar el reconocimiento de comandos.');
      return false;
    }

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      onError('Permiso de micrófono denegado.');
      return false;
    }

    final directory = await getTemporaryDirectory();
    final fileName =
        'intent_${DateTime.now().millisecondsSinceEpoch}_${_hashCodeString()}.wav';
    final filePath = p.join(directory.path, fileName);

    final duration = listenFor ?? listenDuration;

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: IntentRecognizer.sampleRate,
          bitRate: 128000,
          numChannels: 1,
        ),
        path: filePath,
      );
    } catch (error, stackTrace) {
      debugPrint('Error al iniciar la grabación: $error\n$stackTrace');
      onError('No fue posible acceder al micrófono.');
      return false;
    }

    _pendingResult = onResult;
    _pendingError = onError;
    _pendingStatus = onStatus;
    _currentRecordingPath = filePath;
    _isListening = true;
    onStatus?.call(true);

    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(duration, () {
      unawaited(stopListening());
    });

    return true;
  }

  Future<void> stopListening() async {
    if (!_isListening) {
      return;
    }

    _autoStopTimer?.cancel();
    _autoStopTimer = null;

    String? recordedPath;
    try {
      recordedPath = await _recorder.stop();
    } catch (error, stackTrace) {
      debugPrint('Error al detener la grabación: $error\n$stackTrace');
      recordedPath = null;
    }

    final status = _pendingStatus;
    status?.call(false);
    _isListening = false;

    final resultCallback = _pendingResult;
    final errorCallback = _pendingError;
    _pendingResult = null;
    _pendingError = null;
    _pendingStatus = null;

    final tempPath = _currentRecordingPath;
    _currentRecordingPath = null;

    if (recordedPath == null) {
      errorCallback?.call('No se capturó audio.');
      await _deleteIfExists(tempPath);
      return;
    }

    try {
      final result = await _recognizer.recognizeFile(recordedPath);
      if (result == null) {
        errorCallback?.call('No se detectó ninguna intención clara.');
      } else {
        resultCallback?.call(result);
      }
    } catch (error, stackTrace) {
      debugPrint('Error al clasificar audio: $error\n$stackTrace');
      errorCallback?.call('No se pudo procesar el comando de voz.');
    } finally {
      await _deleteIfExists(recordedPath);
    }
  }

  Future<void> cancelListening() async {
    if (!_isListening) {
      return;
    }

    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    try {
      await _recorder.cancel();
    } catch (error, stackTrace) {
      debugPrint('Error al cancelar la grabación: $error\n$stackTrace');
    }

    final status = _pendingStatus;
    status?.call(false);

    _isListening = false;
    final tempPath = _currentRecordingPath;
    _currentRecordingPath = null;
    _pendingResult = null;
    _pendingError = null;
    _pendingStatus = null;

    await _deleteIfExists(tempPath);
  }

  Future<void> dispose() async {
    await cancelListening();
    await _recorder.dispose();
  }

  Future<void> _deleteIfExists(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // ignore
    }
  }

  String _hashCodeString() => hashCode.toRadixString(16);
}
