
import 'package:flutter/material.dart';

/// A widget that displays detection statistics (count and FPS)
class DetectionStatsDisplay extends StatelessWidget {
  const DetectionStatsDisplay({
    super.key,
    required this.detectionCount,
    required this.currentFps,
    this.textScaleFactor = 1.0,
  });

  final int detectionCount;
  final double currentFps;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'DETECTIONS: $detectionCount',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14 * textScaleFactor,
            ),
          ),
          const SizedBox(width: 16),
          Text(
            'FPS: ${currentFps.toStringAsFixed(1)}',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14 * textScaleFactor,
            ),
          ),
        ],
      ),
    );
  }
}
