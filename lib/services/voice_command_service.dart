
import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

typedef VoiceCommandResultCallback = void Function(String text);
typedef VoiceCommandErrorCallback = void Function(String message);
typedef VoiceCommandListeningCallback = void Function(bool isListening);

/// Manages speech recognition sessions for voice commands.
class VoiceCommandService {
  VoiceCommandService();

  final SpeechToText _speechToText = SpeechToText();
  bool _isAvailable = false;
  String? _cachedLocale;
  bool _initializing = false;

  Future<bool> _ensureInitialized({
    VoiceCommandErrorCallback? onError,
    VoiceCommandListeningCallback? onStatus,
  }) async {
    if (_speechToText.isAvailable) {
      _isAvailable = true;
      return true;
    }

    if (_initializing) {
      while (_initializing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _isAvailable;
    }

    _initializing = true;
    try {
      final bool initialized;
      try {
        initialized = await _speechToText.initialize(
          onStatus: (status) {
            if (status == 'listening') {
              onStatus?.call(true);
            } else if (status == 'notListening') {
              onStatus?.call(false);
            }
          },
          onError: (error) {
            final message = error.errorMsg.isNotEmpty
                ? error.errorMsg
                : 'Error desconocido en el reconocimiento de voz.';
            onError?.call(message);
          },
        );
      } on TypeError {
        onError?.call(
          'El reconocimiento de voz no está disponible por una respuesta inválida del sistema.',
        );
        return false;
      }

      _isAvailable = initialized;

      if (_isAvailable && _cachedLocale == null) {
        final systemLocale = await _speechToText.systemLocale();
        if (systemLocale != null) {
          _cachedLocale = systemLocale.localeId;
        } else {
          final locales = await _speechToText.locales();
          _cachedLocale = _findSpanishLocale(locales) ??
              (locales.isNotEmpty ? locales.first.localeId : null);
        }
      }
    } finally {
      _initializing = false;
    }

    return _isAvailable;
  }

  String? _findSpanishLocale(List<LocaleName> locales) {
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().startsWith('es')) {
        return locale.localeId;
      }
    }
    return null;
  }

  Future<bool> startListening({
    required VoiceCommandResultCallback onResult,
    required VoiceCommandErrorCallback onError,
    VoiceCommandListeningCallback? onStatus,
    Duration listenFor = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }

    final available = await _ensureInitialized(onError: onError, onStatus: onStatus);
    if (!available) {
      onError('El reconocimiento de voz no está disponible.');
      return false;
    }

    final localeId = _cachedLocale ?? 'es_ES';
    final safeListenFor = _sanitizeDuration(
      listenFor,
      min: const Duration(seconds: 3),
      max: const Duration(seconds: 20),
      fallback: const Duration(seconds: 8),
    );
    final safePauseFor = _sanitizeDuration(
      pauseFor,
      min: const Duration(seconds: 1),
      max: const Duration(seconds: 8),
      fallback: const Duration(seconds: 3),
    );

    try {
      final bool started;
      try {
        final dynamic result = await _speechToText.listen(
          onResult: (result) {
            if (!result.finalResult) {
              return;
            }
            final recognized = result.recognizedWords.trim();
            if (recognized.isEmpty) {
              onError('No se escuchó ningún comando.');
            } else {
              onResult(recognized);
            }
          },
          listenFor: safeListenFor,
          pauseFor: safePauseFor,
          partialResults: false,
          localeId: localeId,
        );
        if (result is bool) {
          started = result;
        } else {
          started = _speechToText.isListening;
        }
      } on TypeError {
        onError(
          'El servicio de voz no pudo iniciar la escucha por una respuesta inválida.',
        );
        return false;
      }

      if (!started) {
        onError('No se pudo iniciar la escucha.');
        return false;
      }

      onStatus?.call(true);
      return true;
    } catch (error) {
      onError('Error al iniciar la escucha: $error');
      return false;
    }
  }

  Future<void> stopListening() async {
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }
  }

  Future<void> cancelListening() async {
    if (_speechToText.isListening) {
      await _speechToText.cancel();
    }
  }

  bool get isListening => _speechToText.isListening;

  Future<void> dispose() async {
    await cancelListening();
  }

  Duration _sanitizeDuration(
    Duration value, {
    required Duration min,
    required Duration max,
    required Duration fallback,
  }) {
    final milliseconds = value.inMilliseconds;
    if (milliseconds <= 0) {
      return fallback;
    }
    if (milliseconds < min.inMilliseconds) {
      return min;
    }
    if (milliseconds > max.inMilliseconds) {
      return max;
    }
    return value;
  }
}
