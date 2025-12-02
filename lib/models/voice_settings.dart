import 'dart:math' as math;

/// Configuration for the voice announcer.
class VoiceSettings {
  const VoiceSettings({
    this.language = 'es-ES',
    this.speechRate = 0.45,
    this.pitch = 1.0,
    this.volume = 1.0,
  });

  final String language;
  final double speechRate;
  final double pitch;
  final double volume;

  VoiceSettings copyWith({
    String? language,
    double? speechRate,
    double? pitch,
    double? volume,
  }) {
    return VoiceSettings(
      language: language ?? this.language,
      speechRate: speechRate ?? this.speechRate,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
    );
  }

  /// Returns a sanitized configuration keeping all parameters inside safe
  /// ranges accepted by the voice engines.
  VoiceSettings validated() {
    final normalizedLanguage = language.trim().isEmpty ? 'es-ES' : language.trim();
    return VoiceSettings(
      language: normalizedLanguage,
      speechRate: _clampDouble(speechRate, 0.2, 0.8),
      pitch: _clampDouble(pitch, 0.7, 1.3),
      volume: _clampDouble(volume, 0.2, 1.0),
    );
  }
}

double _clampDouble(double value, double min, double max) {
  return math.max(min, math.min(max, value));
}
