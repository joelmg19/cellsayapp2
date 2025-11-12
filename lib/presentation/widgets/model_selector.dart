import 'package:flutter/material.dart';
import '../../models/models.dart';

/// A widget for selecting different YOLO model types
class ModelSelector extends StatelessWidget {
  const ModelSelector({
    super.key,
    required this.selectedModel,
    required this.isModelLoading,
    required this.onModelChanged,
    this.textScaleFactor = 1.0,
  });

  final ModelType selectedModel;
  final bool isModelLoading;
  final ValueChanged<ModelType> onModelChanged;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          // --- INICIO DE MODIFICACIÓN ---
          // Se quita la altura fija 'height: 36' para permitir que el Wrap crezca
          // --- FIN DE MODIFICACIÓN ---
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          // --- INICIO DE MODIFICACIÓN ---
          // Se cambió 'Row' por 'Wrap' para que los botones salten de línea
          child: Wrap(
            spacing: 2.0, // Espacio horizontal entre botones
            runSpacing: 2.0, // Espacio vertical si saltan de línea
            children: ModelType.values
                .where((model) => model != ModelType.LectorCarteles)
                .map((model) {
              // --- FIN DE MODIFICACIÓN ---
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
      ],
    );
  }
}