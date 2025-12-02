import 'package:flutter_tts/flutter_tts.dart';

/// Utility helpers to keep text-to-speech messages consistent and safe when
/// working with proximity estimations.
class TtsHelper {
  TtsHelper(this.tts);

  final FlutterTts tts;

  /// Returns `true` if the distance is finite and positive.
  bool hasValidDistance(double? meters) {
    return meters != null && !meters.isNaN && !meters.isInfinite && meters > 0;
  }
}
