
import 'package:flutter/material.dart';
import '../../models/models.dart';
import 'depth_control_section.dart';

/// A widget for selecting different YOLO model types
class ModelSelector extends StatelessWidget {
  const ModelSelector({
    super.key,
    required this.selectedModel,
    required this.isModelLoading,
    required this.onModelChanged,
    required this.isDepthEnabled,
    required this.isDepthAvailable,
    required this.onDepthChanged,
    this.textScaleFactor = 1.0,
  });

  final ModelType selectedModel;
  final bool isModelLoading;
  final ValueChanged<ModelType> onModelChanged;
  final bool isDepthEnabled;
  final bool isDepthAvailable;
  final ValueChanged<bool> onDepthChanged;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DepthControlSection(
          isEnabled: isDepthEnabled,
          isAvailable: isDepthAvailable,
          onChanged: onDepthChanged,
          textScaleFactor: textScaleFactor,
        ),
        SizedBox(height: 8 * textScaleFactor),
        Container(
          height: 36,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: ModelType.values.map((model) {
              final isSelected = selectedModel == model;
              return GestureDetector(
                onTap: () {
                  if (!isModelLoading && model != selectedModel) {
                    onModelChanged(model);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    model.displayName.toUpperCase(),
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.white,
                      fontSize: 12 * textScaleFactor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
