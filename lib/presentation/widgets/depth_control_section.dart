import 'package:flutter/material.dart';

/// Displays controls to enable or disable depth processing for detections.
class DepthControlSection extends StatelessWidget {
  const DepthControlSection({
    super.key,
    required this.isEnabled,
    required this.isAvailable,
    required this.onChanged,
    this.textScaleFactor = 1.0,
  });

  final bool isEnabled;
  final bool isAvailable;
  final ValueChanged<bool> onChanged;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = isAvailable
        ? (isEnabled ? 'Activada' : 'Desactivada')
        : 'No disponible';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PROFUNDIDAD EN OBJETOS',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12 * textScaleFactor,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 12 * textScaleFactor,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: isAvailable && isEnabled,
            onChanged: isAvailable ? onChanged : null,
            activeColor: Colors.greenAccent,
          ),
        ],
      ),
    );
  }
}
