import 'package:flutter/material.dart';

import '../controllers/camera_inference_controller.dart';

class DepthControlSection extends StatelessWidget {
  const DepthControlSection({
    super.key,
    required this.controller,
  });

  final CameraInferenceController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isServiceReady = controller.isDepthServiceAvailable;
    final isEnabled = controller.isDepthProcessingEnabled && isServiceReady;

    return Semantics(
      container: true,
      label: 'Controles de profundidad',
      hint: 'Activa el interruptor para estimar distancias usando el mapa de profundidad.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.gradient, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Procesamiento de profundidad',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    textScaleFactor: controller.fontScale,
                  ),
                ),
                Semantics(
                  label: isEnabled
                      ? 'Procesamiento de profundidad activado'
                      : 'Procesamiento de profundidad desactivado',
                  toggled: isEnabled,
                  child: Switch.adaptive(
                    value: isEnabled,
                    onChanged: isServiceReady
                        ? controller.setDepthProcessingEnabled
                        : null,
                    activeColor: theme.colorScheme.secondary,
                    inactiveThumbColor: Colors.white70,
                    inactiveTrackColor: Colors.white30,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ) ??
                  const TextStyle(color: Colors.white70),
              child: Text(
                _statusMessage(isServiceReady, isEnabled),
                textScaleFactor: controller.fontScale,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusMessage(bool serviceReady, bool isEnabled) {
    if (!serviceReady) {
      return 'Iniciando servicio de profundidad…';
    }
    if (isEnabled) {
      return 'Estimando distancias con ayuda del mapa de profundidad.';
    }
    return 'Activa esta opción para complementar las distancias con información de profundidad.';
  }
}
