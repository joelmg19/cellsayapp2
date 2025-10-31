import 'package:flutter/material.dart';
import '../../models/detection_insight.dart';
import '../controllers/camera_inference_controller.dart';

class AccessibilityStatusBar extends StatelessWidget {
  const AccessibilityStatusBar({
    super.key,
    required this.controller,
    required this.isLandscape,
  });

  final CameraInferenceController controller;
  final bool isLandscape;

  @override
  Widget build(BuildContext context) {
    final fontScale = controller.fontScale;
    final baseStyle = TextStyle(
      color: Colors.white,
      fontSize: 14 * fontScale,
      fontWeight: FontWeight.w600,
    );

    final infoChips = <Widget>[
      _InfoChip(label: 'Hora', value: controller.formattedTime, style: baseStyle),
      if (controller.weatherSummary != null)
        _InfoChip(label: 'Clima', value: controller.weatherSummary!, style: baseStyle),
      if (controller.voiceCommandStatus != null)
        _InfoChip(label: 'Voz', value: controller.voiceCommandStatus!, style: baseStyle),
    ];

    final alertChips = <Widget>[
      if (controller.connectionAlert != null)
        _AlertChip(
          text: controller.connectionAlert!,
          color: Colors.deepOrange,
          fontScale: fontScale,
        ),
      if (controller.cameraAlert != null)
        _AlertChip(
          text: controller.cameraAlert!,
          color: Colors.redAccent,
          fontScale: fontScale,
        ),
    ];

    final detections = controller.processedDetections;
    if (detections.hasCloseObstacle) {
      alertChips.add(
        _AlertChip(
          text: 'Obstáculo cercano: ${detections.closeObstacleLabels.join(', ')}',
          color: Colors.orangeAccent,
          fontScale: fontScale,
        ),
      );
    }
    if (detections.hasMovementWarnings) {
      alertChips.add(
        _AlertChip(
          text: 'Peligro en movimiento: ${detections.movementWarnings.join(', ')}',
          color: Colors.amber,
          fontScale: fontScale,
        ),
      );
    }
    final navigationInstruction = controller.navigationInstruction;
    if (navigationInstruction != null) {
      alertChips.add(
        _AlertChip(
          text: 'Guía: $navigationInstruction',
          color: controller.usedDepthNavigation
              ? Colors.lightBlueAccent
              : Colors.blueGrey,
          fontScale: fontScale,
        ),
      );
    }
    final trafficMessage = _trafficMessage(detections.trafficLightSignal);
    if (trafficMessage != null) {
      alertChips.add(
        _AlertChip(
          text: trafficMessage,
          color: detections.trafficLightSignal == TrafficLightSignal.red
              ? Colors.red
              : Colors.green,
          fontScale: fontScale,
        ),
      );
    }

    final mediaPadding = MediaQuery.of(context).padding;
    final topOffset = mediaPadding.top + (isLandscape ? 120 : 208);

    return Positioned(
      top: topOffset,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (infoChips.isNotEmpty)
            _ContainerWrapper(
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: infoChips,
              ),
            ),
          if (alertChips.isNotEmpty) ...[
            SizedBox(height: infoChips.isNotEmpty ? 12 : 0),
            _ContainerWrapper(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: alertChips
                    .map((chip) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: chip,
                        ))
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _trafficMessage(TrafficLightSignal signal) {
    switch (signal) {
      case TrafficLightSignal.green:
        return 'Semáforo verde: avanza con precaución.';
      case TrafficLightSignal.red:
        return 'Semáforo rojo: detente.';
      case TrafficLightSignal.unknown:
        return null;
    }
  }
}

class _ContainerWrapper extends StatelessWidget {
  const _ContainerWrapper({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: child,
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.value,
    required this.style,
  });

  final String label;
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final description = '$label: $value';
    return MergeSemantics(
      child: Semantics(
        label: description,
        child: ExcludeSemantics(
          child: RichText(
            text: TextSpan(
              text: '$label: ',
              style: style.copyWith(color: Colors.white70),
              children: [TextSpan(text: value, style: style)],
            ),
          ),
        ),
      ),
    );
  }
}

class _AlertChip extends StatelessWidget {
  const _AlertChip({
    required this.text,
    required this.color,
    required this.fontScale,
  });

  final String text;
  final Color color;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        label: text,
        container: true,
        child: ExcludeSemantics(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14 * fontScale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
