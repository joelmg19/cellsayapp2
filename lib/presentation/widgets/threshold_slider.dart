
import 'package:flutter/material.dart';
import '../../models/models.dart';

/// A slider widget for adjusting threshold values
class ThresholdSlider extends StatelessWidget {
  const ThresholdSlider({
    super.key,
    required this.activeSlider,
    required this.confidenceThreshold,
    required this.iouThreshold,
    required this.numItemsThreshold,
    required this.onValueChanged,
    required this.isLandscape,
    required this.areControlsLocked,
  });

  final SliderType activeSlider;
  final double confidenceThreshold;
  final double iouThreshold;
  final int numItemsThreshold;
  final ValueChanged<double> onValueChanged;
  final bool isLandscape;
  final bool areControlsLocked;

  @override
  Widget build(BuildContext context) {
    if (activeSlider == SliderType.none) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isLandscape ? 16 : 24,
          vertical: isLandscape ? 8 : 12,
        ),
        color: Colors.black.withValues(alpha: 0.8),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.yellow,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
            thumbColor: Colors.yellow,
            overlayColor: Colors.yellow.withValues(alpha: 0.2),
          ),
          child: MergeSemantics(
            child: Builder(
              builder: (context) {
                final value = _getSliderValue();
                final min = _getSliderMin();
                final max = _getSliderMax();
                final divisions = _getSliderDivisions();
                final step = divisions == 0 ? 0.1 : (max - min) / divisions;
                final semanticsValue = _formatSemanticsValue(value);
                return Semantics(
                  container: true,
                  label: _getSemanticsLabel(),
                  value: semanticsValue,
                  hint: _getSemanticsHint(),
                  increasedValue: _formatSemanticsValue(
                    (value + step).clamp(min, max),
                  ),
                  decreasedValue: _formatSemanticsValue(
                    (value - step).clamp(min, max),
                  ),
                  onIncrease: areControlsLocked
                      ? null
                      : () => onValueChanged(
                            (value + step).clamp(min, max),
                          ),
                  onDecrease: areControlsLocked
                      ? null
                      : () => onValueChanged(
                            (value - step).clamp(min, max),
                          ),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    label: _getSliderLabel(),
                    onChanged: areControlsLocked ? null : onValueChanged,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  double _getSliderValue() => switch (activeSlider) {
    SliderType.numItems => numItemsThreshold.toDouble(),
    SliderType.confidence => confidenceThreshold,
    SliderType.iou => iouThreshold,
    _ => 0,
  };

  double _getSliderMin() => activeSlider == SliderType.numItems ? 5 : 0.1;
  double _getSliderMax() => activeSlider == SliderType.numItems ? 50 : 0.9;
  int _getSliderDivisions() => activeSlider == SliderType.numItems ? 9 : 8;
  String _getSliderLabel() => switch (activeSlider) {
    SliderType.numItems => '$numItemsThreshold',
    SliderType.confidence => confidenceThreshold.toStringAsFixed(1),
    SliderType.iou => iouThreshold.toStringAsFixed(1),
    _ => '',
  };

  String _formatSemanticsValue(double value) {
    if (activeSlider == SliderType.numItems) {
      return '${value.round()} objetos';
    }
    return '${value.toStringAsFixed(1)}';
  }

  String _getSemanticsLabel() => switch (activeSlider) {
        SliderType.numItems => 'Control deslizante de límite de objetos',
        SliderType.confidence => 'Control deslizante del umbral de confianza',
        SliderType.iou => 'Control deslizante del umbral de intersección sobre unión',
        _ => 'Control deslizante',
      };

  String _getSemanticsHint() => switch (activeSlider) {
        SliderType.numItems =>
            'Ajusta el número máximo de objetos que serán anunciados.',
        SliderType.confidence =>
            'Ajusta el nivel mínimo de confianza requerido para anunciar una detección.',
        SliderType.iou =>
            'Ajusta cuánto deben solaparse las detecciones para considerarse iguales.',
        _ => 'Ajusta el valor del control deslizante.',
      };
}
