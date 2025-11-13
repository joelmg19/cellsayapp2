
import 'package:flutter/material.dart';
import '../../models/models.dart';
import 'control_button.dart';

/// A widget containing camera control buttons
class CameraControls extends StatelessWidget {
  const CameraControls({
    super.key,
    required this.currentZoomLevel,
    required this.isFrontCamera,
    required this.activeSlider,
    required this.onZoomChanged,
    required this.onSliderToggled,
    required this.onCameraFlipped,
    required this.onVoiceToggled,
    required this.isVoiceEnabled,
    required this.isLandscape,
    required this.fontScale,
    required this.onFontIncrease,
    required this.onFontDecrease,
    required this.onRepeatInstruction,
    required this.onVoiceSettings,
    required this.onVoiceCommandStart,
    required this.onVoiceCommandEnd,
    required this.onVoiceCommandRequested,
    required this.isListeningForCommand,
    required this.areControlsLocked,
    required this.onLockToggled,
  });

  final double currentZoomLevel;
  final bool isFrontCamera;
  final SliderType activeSlider;
  final ValueChanged<double> onZoomChanged;
  final ValueChanged<SliderType> onSliderToggled;
  final VoidCallback onCameraFlipped;
  final VoidCallback onVoiceToggled;
  final bool isVoiceEnabled;
  final bool isLandscape;
  final double fontScale;
  final VoidCallback onFontIncrease;
  final VoidCallback onFontDecrease;
  final VoidCallback onRepeatInstruction;
  final VoidCallback onVoiceSettings;
  final VoidCallback onVoiceCommandStart;
  final VoidCallback onVoiceCommandEnd;
  final VoidCallback onVoiceCommandRequested;
  final bool isListeningForCommand;
  final bool areControlsLocked;
  final VoidCallback onLockToggled;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    final bottomPadding = isLandscape ? 16.0 : 24.0;
    final wrapSpacing = isLandscape ? 10.0 : 14.0;
    final fontPercentage = (fontScale * 100).round();

    final buttons = <Widget>[
      ControlButton(
        content: areControlsLocked ? Icons.lock : Icons.lock_open,
        onPressed: onLockToggled,
        isActive: areControlsLocked,
        tooltip: areControlsLocked
            ? 'Desbloquear controles'
            : 'Bloquear controles',
        semanticsLabel:
            areControlsLocked ? 'Controles bloqueados' : 'Controles desbloqueados',
        semanticsHint: areControlsLocked
            ? 'Doble toque para desbloquear los controles.'
            : 'Doble toque para bloquear los controles.',
        semanticsValue: areControlsLocked ? 'Bloqueados' : 'Desbloqueados',
        isToggle: true,
      ),
      ControlButton(
        content: Icons.text_decrease,
        onPressed: onFontDecrease,
        tooltip: 'Reducir tamaño de texto',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Reducir tamaño de texto',
        semanticsHint: 'Doble toque para reducir el tamaño del texto.',
        semanticsValue: 'Tamaño actual $fontPercentage%',
      ),
      ControlButton(
        content: Icons.text_increase,
        onPressed: onFontIncrease,
        tooltip: 'Aumentar tamaño de texto',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Aumentar tamaño de texto',
        semanticsHint: 'Doble toque para ampliar el tamaño del texto.',
        semanticsValue: 'Tamaño actual $fontPercentage%',
      ),
      ControlButton(
        content: Icons.replay,
        onPressed: onRepeatInstruction,
        tooltip: 'Repetir última instrucción',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Repetir última instrucción de voz',
        semanticsHint:
            'Doble toque para escuchar nuevamente la última indicación del asistente.',
      ),
      if (!isFrontCamera)
        ControlButton(
          content: '${currentZoomLevel.toStringAsFixed(1)}x',
          onPressed: () => onZoomChanged(
            currentZoomLevel < 0.75
                ? 1.0
                : currentZoomLevel < 2.0
                    ? 3.0
                    : 0.5,
          ),
          tooltip: 'Cambiar zoom',
          isDisabled: areControlsLocked,
          semanticsLabel:
              'Zoom ${currentZoomLevel.toStringAsFixed(1)} aumentos',
          semanticsHint: 'Doble toque para cambiar el nivel de zoom.',
          semanticsValue:
              'Nivel actual ${currentZoomLevel.toStringAsFixed(1)} veces',
        ),
      ControlButton(
        content: Icons.layers,
        onPressed: () => onSliderToggled(SliderType.numItems),
        isActive: activeSlider == SliderType.numItems,
        tooltip: 'Límite de objetos',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Seleccionar límite de objetos',
        semanticsHint:
            'Doble toque para ajustar la cantidad máxima de objetos detectados.',
        semanticsValue:
            activeSlider == SliderType.numItems ? 'Seleccionado' : 'No seleccionado',
        isToggle: true,
      ),
      ControlButton(
        content: Icons.adjust,
        onPressed: () => onSliderToggled(SliderType.confidence),
        isActive: activeSlider == SliderType.confidence,
        tooltip: 'Umbral de confianza',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Seleccionar umbral de confianza',
        semanticsHint:
            'Doble toque para mostrar el control deslizante del nivel de confianza.',
        semanticsValue: activeSlider == SliderType.confidence
            ? 'Seleccionado'
            : 'No seleccionado',
        isToggle: true,
      ),
      ControlButton(
        content: 'assets/iou.png',
        onPressed: () => onSliderToggled(SliderType.iou),
        isActive: activeSlider == SliderType.iou,
        tooltip: 'Umbral IoU',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Seleccionar umbral de intersección sobre unión',
        semanticsHint:
            'Doble toque para ajustar la superposición mínima entre detecciones.',
        semanticsValue:
            activeSlider == SliderType.iou ? 'Seleccionado' : 'No seleccionado',
        isToggle: true,
      ),
      ControlButton(
        content: Icons.mic,
        onPressed: onVoiceCommandRequested,
        onPressStart: onVoiceCommandStart,
        onPressEnd: onVoiceCommandEnd,
        tooltip: isListeningForCommand
            ? 'Suelta para enviar el comando'
            : 'Mantén presionado para hablar',
        isDisabled: areControlsLocked,
        isActive: isListeningForCommand,
        semanticsLabel: 'Comandos de voz',
        semanticsHint:
            'Doble toque para alternar la escucha de comandos. Mantén presionado para dictar manualmente.',
        semanticsValue:
            isListeningForCommand ? 'Escuchando' : 'Inactivo',
        isToggle: true,
      ),
      ControlButton(
        content: isVoiceEnabled ? Icons.volume_up : Icons.volume_off,
        onPressed: onVoiceToggled,
        isActive: isVoiceEnabled,
        tooltip:
            isVoiceEnabled ? 'Desactivar narración' : 'Activar narración',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Narración por voz',
        semanticsHint: isVoiceEnabled
            ? 'Doble toque para desactivar la narración de la aplicación.'
            : 'Doble toque para activar la narración de la aplicación.',
        semanticsValue: isVoiceEnabled ? 'Activada' : 'Desactivada',
        isToggle: true,
      ),
      ControlButton(
        content: Icons.settings_voice,
        onPressed: onVoiceSettings,
        tooltip: 'Configuración de voz',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Abrir configuración de voz',
        semanticsHint:
            'Doble toque para modificar la velocidad, tono e idioma de la narración.',
      ),
      ControlButton(
        content: Icons.flip_camera_ios,
        onPressed: onCameraFlipped,
        tooltip: 'Cambiar cámara',
        isDisabled: areControlsLocked,
        semanticsLabel: 'Cambiar cámara',
        semanticsHint:
            'Doble toque para alternar entre la cámara frontal y trasera.',
      ),
    ];

    return SafeArea(
      child: Align(
        alignment:
            isLandscape ? Alignment.centerRight : Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(
            left: isLandscape ? 0 : 24.0,
            right: 24.0,
            bottom: bottomPadding + padding.bottom,
          ),
          child: _ControlPanel(
            isLandscape: isLandscape,
            isLocked: areControlsLocked,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isLandscape ? 280 : 360,
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: wrapSpacing,
                runSpacing: wrapSpacing,
                children: buttons,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.child,
    required this.isLandscape,
    required this.isLocked,
  });

  final Widget child;
  final bool isLandscape;
  final bool isLocked;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isLocked
            ? Colors.black.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: Offset(0, isLandscape ? 4 : 8),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isLandscape ? 12 : 16,
          vertical: isLandscape ? 14 : 18,
        ),
        child: child,
      ),
    );
  }
}
