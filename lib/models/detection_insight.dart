import 'dart:collection';
import 'package:ultralytics_yolo/models/yolo_result.dart';

/// Enum that represents the detected state of a traffic light.
enum TrafficLightSignal {
  red,
  green,
  unknown,
}

/// Holds post-processed detection information ready for UI and voice feedback.
class ProcessedDetections {
  const ProcessedDetections({
    required List<YOLOResult> filteredResults,
    required List<String> closeObstacleLabels,
    required this.trafficLightSignal,
    required List<String> movementWarnings,
  })  : _filteredResults = filteredResults,
        _closeObstacleLabels = closeObstacleLabels,
        _movementWarnings = movementWarnings;

  final List<YOLOResult> _filteredResults;
  final List<String> _closeObstacleLabels;
  final List<String> _movementWarnings;

  /// List of filtered detections after improved NMS.
  UnmodifiableListView<YOLOResult> get filteredResults =>
      UnmodifiableListView(_filteredResults);

  /// Labels for obstacles that are considered dangerously close.
  UnmodifiableListView<String> get closeObstacleLabels =>
      UnmodifiableListView(_closeObstacleLabels);

  /// Indicates the detected traffic light colour.
  final TrafficLightSignal trafficLightSignal;

  /// Warnings related to fast moving hazards.
  UnmodifiableListView<String> get movementWarnings =>
      UnmodifiableListView(_movementWarnings);

  /// Whether a close obstacle has been detected.
  bool get hasCloseObstacle => _closeObstacleLabels.isNotEmpty;

  /// Whether a moving hazard has been detected.
  bool get hasMovementWarnings => _movementWarnings.isNotEmpty;

  /// Convenience empty object.
  static const empty = ProcessedDetections(
    filteredResults: <YOLOResult>[],
    closeObstacleLabels: <String>[],
    trafficLightSignal: TrafficLightSignal.unknown,
    movementWarnings: <String>[],
  );
}

/// Aggregated alerts that should be announced to the user.
class SafetyAlerts {
  const SafetyAlerts({this.connectionAlert, this.cameraAlert});

  final String? connectionAlert;
  final String? cameraAlert;

  List<String> toList() => [
        if (connectionAlert != null) connectionAlert!,
        if (cameraAlert != null) cameraAlert!,
      ];
}
