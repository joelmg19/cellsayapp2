import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../controllers/camera_inference_controller.dart';
import 'detection_stats_display.dart';
import 'model_selector.dart';
import 'threshold_pill.dart';
import 'depth_control_section.dart';

/// Top overlay widget containing model selector, stats, and threshold pills
class CameraInferenceOverlay extends StatelessWidget {
  const CameraInferenceOverlay({
    super.key,
    required this.controller,
    required this.isLandscape,
    this.showDepthControls = false,
  });

  final CameraInferenceController controller;
  final bool isLandscape;
  final bool showDepthControls;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      ModelSelector(
        selectedModel: controller.displayedModel,
        isModelLoading: controller.isModelLoading,
        onModelChanged: controller.handleModelSelection,
        textScaleFactor: controller.fontScale,
      ),
      SizedBox(height: isLandscape ? 8 : 12),
      if (controller.displayedModel == ModelType.Exterior)
        _SignReaderToggle(
          isActive: controller.isSignReaderEnabled,
          isEnabled: controller.canToggleSignReader,
          onChanged: controller.setSignReaderEnabled,
          textScaleFactor: controller.fontScale,
        ),
      if (controller.displayedModel == ModelType.Exterior)
        SizedBox(height: isLandscape ? 8 : 12),
      DetectionStatsDisplay(
        detectionCount: controller.detectionCount,
        currentFps: controller.currentFps,
        textScaleFactor: controller.fontScale,
      ),
      const SizedBox(height: 8),
      _buildThresholdPills(),
    ];

    if (showDepthControls) {
      children
        ..add(const SizedBox(height: 12))
        ..add(DepthControlSection(controller: controller));
    }

    return Positioned(
      top: MediaQuery.of(context).padding.top + (isLandscape ? 8 : 16),
      left: isLandscape ? 8 : 16,
      right: isLandscape ? 8 : 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  Widget _buildThresholdPills() {
    if (controller.activeSlider == SliderType.confidence) {
      return ThresholdPill(
        label:
            'CONFIDENCE THRESHOLD: ${controller.confidenceThreshold.toStringAsFixed(2)}',
        textScaleFactor: controller.fontScale,
      );
    } else if (controller.activeSlider == SliderType.iou) {
      return ThresholdPill(
        label: 'IOU THRESHOLD: ${controller.iouThreshold.toStringAsFixed(2)}',
        textScaleFactor: controller.fontScale,
      );
    } else if (controller.activeSlider == SliderType.numItems) {
      return ThresholdPill(
        label: 'ITEMS MAX: ${controller.numItemsThreshold}',
        textScaleFactor: controller.fontScale,
      );
    }
    return const SizedBox.shrink();
  }
}

class _SignReaderToggle extends StatelessWidget {
  const _SignReaderToggle({
    required this.isActive,
    required this.isEnabled,
    required this.onChanged,
    required this.textScaleFactor,
  });

  final bool isActive;
  final bool isEnabled;
  final ValueChanged<bool> onChanged;
  final double textScaleFactor;

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 14 * textScaleFactor,
      fontWeight: FontWeight.w600,
    );

    return Semantics(
      container: true,
      label: 'Activar lector de carteles',
      hint: isEnabled
          ? 'Usa el interruptor para ${isActive ? 'desactivar' : 'activar'} el lector de carteles.'
          : 'Interruptor deshabilitado mientras los controles están bloqueados o el sistema está ocupado.',
      toggled: isActive,
      enabled: isEnabled,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Lector de carteles',
                style: labelStyle,
              ),
            ),
            Switch.adaptive(
              value: isActive,
              onChanged: isEnabled ? onChanged : null,
              activeColor: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
