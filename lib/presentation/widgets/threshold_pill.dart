
import 'package:flutter/material.dart';

/// A pill-shaped container for displaying threshold values
class ThresholdPill extends StatelessWidget {
  const ThresholdPill({
    super.key,
    required this.label,
    this.textScaleFactor = 1.0,
  });

  final String label;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 14 * textScaleFactor,
        ),
      ),
    );
  }
}
