import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class SignReaderPanel extends StatelessWidget {
  const SignReaderPanel({
    super.key,
    this.lastText,
    this.timestamp,
    this.imageBytes,
    required this.isProcessing,
    this.textScaleFactor = 1.0,
  });

  final String? lastText;
  final DateTime? timestamp;
  final Uint8List? imageBytes;
  final bool isProcessing;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      fontSize: 15 * textScaleFactor,
    );
    final bodyStyle = TextStyle(
      color: Colors.white70,
      fontSize: 13 * textScaleFactor,
    );
    final accentStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      fontSize: 13 * textScaleFactor,
    );

    return Semantics(
      container: true,
      label: 'Panel del lector de carteles',
      hint:
          'Muestra el estado del lector de carteles, el último texto reconocido y una vista previa.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sign_language,
                  color: Colors.amberAccent,
                  size: 20 * textScaleFactor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lector de carteles activo',
                    style: titleStyle,
                  ),
                ),
                if (isProcessing)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.secondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Leyendo...',
                        style: accentStyle,
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Apunta la cámara hacia el cartel y mantén el teléfono estable. '
              'El texto se leerá automáticamente en voz alta.',
              style: bodyStyle,
            ),
            if (imageBytes != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  imageBytes!,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  semanticLabel: 'Vista previa del cartel capturado',
                ),
              ),
            ],
            if (lastText != null && lastText!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Última lectura',
                style: accentStyle,
              ),
              const SizedBox(height: 4),
              Text(
                lastText!,
                style: bodyStyle.copyWith(color: Colors.white),
              ),
              if (timestamp != null) ...[
                const SizedBox(height: 2),
                Text(
                  _formatTimestamp(timestamp!),
                  style: bodyStyle.copyWith(fontSize: 12 * textScaleFactor),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime value) {
    final now = DateTime.now();
    final difference = now.difference(value);
    if (difference.inSeconds < 60) {
      final seconds = difference.inSeconds.clamp(1, 59);
      return 'Hace $seconds segundos';
    }
    if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return 'Hace $minutes minuto${minutes == 1 ? '' : 's'}';
    }
    return 'Registrado a las ${DateFormat.Hms().format(value)}';
  }
}
