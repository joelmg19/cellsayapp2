import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../controllers/camera_inference_controller.dart';
import '../widgets/accessibility_status_bar.dart';
import '../widgets/camera_inference_content.dart';
import '../widgets/camera_inference_overlay.dart';
import '../widgets/camera_controls.dart';
import '../widgets/threshold_slider.dart';
import '../widgets/voice_settings_sheet.dart';

/// A screen that demonstrates real-time YOLO inference using the device camera.
///
/// This screen provides:
/// - Live camera feed with YOLO object detection
/// - Model selection (Interior, Exterior)
/// - Adjustable thresholds (confidence, IoU, max detections)
/// - Camera controls (flip, zoom)
/// - Performance metrics (FPS)
class CameraInferenceScreen extends StatefulWidget {
  // CORRECCIÓN CLAVE: Cambiar 'initialModel' por 'modelType'
  const CameraInferenceScreen({
    super.key,
    this.modelType = ModelType.Interior,
  });

  final ModelType modelType;
  final bool showDepthControls;
  final bool enableDepthProcessing;

  @override
  State<CameraInferenceScreen> createState() => _CameraInferenceScreenState();
}

class _CameraInferenceScreenState extends State<CameraInferenceScreen> {
  late final CameraInferenceController _controller;

  @override
  void initState() {
    super.initState();
    // CORRECCIÓN: Usar widget.modelType
    _controller = CameraInferenceController(initialModel: widget.modelType);
    _controller.initialize().catchError((error) {
      if (mounted) {
        _showError('Model Loading Error', error.toString());
      }
    });
    if (widget.enableDepthProcessing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.setDepthProcessingEnabled(true);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, child) {
          return Stack(
            children: [
              CameraInferenceContent(controller: _controller),
              CameraInferenceOverlay(
                controller: _controller,
                isLandscape: isLandscape,
                showDepthControls: widget.showDepthControls,
              ),
              CameraControls(
                currentZoomLevel: _controller.currentZoomLevel,
                isFrontCamera: _controller.isFrontCamera,
                activeSlider: _controller.activeSlider,
                onZoomChanged: _controller.setZoomLevel,
                onSliderToggled: _controller.toggleSlider,
                onCameraFlipped: _controller.flipCamera,
                onVoiceToggled: _controller.toggleVoice,
                isVoiceEnabled: _controller.isVoiceEnabled,
                isLandscape: isLandscape,
                fontScale: _controller.fontScale,
                onFontIncrease: _controller.increaseFontScale,
                onFontDecrease: _controller.decreaseFontScale,
                onRepeatInstruction: () => _controller.repeatLastInstruction(),
                onVoiceSettings: _showVoiceSettings,
                onVoiceCommandStart: _controller.onVoiceCommandHoldStart,
                onVoiceCommandEnd: _controller.onVoiceCommandHoldEnd,
                onVoiceCommandRequested: _controller.onVoiceCommandRequested,
                isListeningForCommand: _controller.isListeningForCommand,
                areControlsLocked: _controller.areControlsLocked,
                onLockToggled: _controller.toggleControlsLock,
              ),
              ThresholdSlider(
                activeSlider: _controller.activeSlider,
                confidenceThreshold: _controller.confidenceThreshold,
                iouThreshold: _controller.iouThreshold,
                numItemsThreshold: _controller.numItemsThreshold,
                onValueChanged: _controller.updateSliderValue,
                isLandscape: isLandscape,
                areControlsLocked: _controller.areControlsLocked,
              ),
              AccessibilityStatusBar(
                controller: _controller,
                isLandscape: isLandscape,
              ),
            ],
          );
        },
      ),
    );
  }

  void _showError(String title, String message) => showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  void _showVoiceSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.black.withOpacity(0.85),
      builder: (context) => VoiceSettingsSheet(
        initialSettings: _controller.voiceSettings,
        onChanged: _controller.updateVoiceSettings,
        fontScale: _controller.fontScale,
      ),
    );
  }

}