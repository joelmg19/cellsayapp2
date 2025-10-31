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
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Profundidad en objetos',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16 * textScaleFactor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 13 * textScaleFactor,
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
