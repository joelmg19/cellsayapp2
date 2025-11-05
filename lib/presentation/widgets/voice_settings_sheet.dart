import 'package:flutter/material.dart';
import '../../models/voice_settings.dart';

class VoiceSettingsSheet extends StatefulWidget {
  const VoiceSettingsSheet({
    super.key,
    required this.initialSettings,
    required this.onChanged,
    this.fontScale = 1.0,
  });

  final VoiceSettings initialSettings;
  final ValueChanged<VoiceSettings> onChanged;
  final double fontScale;

  @override
  State<VoiceSettingsSheet> createState() => _VoiceSettingsSheetState();
}

class _VoiceSettingsSheetState extends State<VoiceSettingsSheet> {
  late VoiceSettings _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialSettings.validated();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 16 * widget.fontScale,
      fontWeight: FontWeight.w600,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Configuración de voz', style: textStyle),
          ),
          const SizedBox(height: 16),
          _buildSlider(
            label: 'Velocidad',
            value: _current.speechRate,
            min: 0.2,
            max: 0.8,
            onChanged: (value) => _updateSettings(_current.copyWith(speechRate: value)),
          ),
          const SizedBox(height: 12),
          _buildSlider(
            label: 'Tono',
            value: _current.pitch,
            min: 0.7,
            max: 1.3,
            onChanged: (value) => _updateSettings(_current.copyWith(pitch: value)),
          ),
          const SizedBox(height: 12),
          _buildSlider(
            label: 'Volumen',
            value: _current.volume,
            min: 0.2,
            max: 1.0,
            onChanged: (value) => _updateSettings(_current.copyWith(volume: value)),
          ),
          const SizedBox(height: 16),
          Text('Idioma', style: textStyle),
          const SizedBox(height: 8),
          Semantics(
            container: true,
            label: 'Idioma de la narración',
            value: _languageDescription(_current.language),
            hint: 'Doble toque para elegir un idioma distinto para la voz.',
            child: DropdownButton<String>(
              value: _current.language,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'es-ES', child: Text('Español (España)')),
                DropdownMenuItem(value: 'es-MX', child: Text('Español (México)')),
                DropdownMenuItem(value: 'en-US', child: Text('Inglés (Estados Unidos)')),
              ],
              onChanged: (value) {
                if (value != null) {
                  _updateSettings(_current.copyWith(language: value));
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: Semantics(
              button: true,
              label: 'Restablecer configuración de voz',
              hint: 'Doble toque para volver a los valores predeterminados.',
              child: TextButton(
                onPressed: _resetDefaults,
                child: const Text('Restablecer'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final step = (max - min) / 10;
    double clampValue(double target) => target.clamp(min, max).toDouble();
    final semanticsValue = value.toStringAsFixed(2);

    return MergeSemantics(
      child: Semantics(
        container: true,
        label: label,
        value: semanticsValue,
        hint: 'Desliza el control para ajustar $label.',
        increasedValue: clampValue(value + step).toStringAsFixed(2),
        decreasedValue: clampValue(value - step).toStringAsFixed(2),
        onIncrease: () => onChanged(clampValue(value + step)),
        onDecrease: () => onChanged(clampValue(value - step)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Text(label, style: TextStyle(fontSize: 14 * widget.fontScale)),
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  void _updateSettings(VoiceSettings settings) {
    final validated = settings.validated();
    setState(() {
      _current = validated;
    });
    widget.onChanged(validated);
  }

  void _resetDefaults() {
    _updateSettings(const VoiceSettings());
  }

  String _languageDescription(String code) {
    return switch (code) {
      'es-ES' => 'Español de España',
      'es-MX' => 'Español de México',
      'en-US' => 'Inglés de Estados Unidos',
      _ => code,
    };
  }
}
