import 'package:flutter_test/flutter_test.dart';

import 'package:ultralytics_yolo_example/core/vision/distance_estimator.dart';

void main() {
  group('DistanceEstimator', () {
    final estimator = DistanceEstimator(focalPx: 864);

    test('returns shorter distance for larger bounding boxes', () {
      final closeDistance = estimator.distanceMeters(
        detectedClass: 'person',
        bboxHeightRelative: 0.8,
        imageHeightPx: 640,
      );
      final farDistance = estimator.distanceMeters(
        detectedClass: 'person',
        bboxHeightRelative: 0.2,
        imageHeightPx: 640,
      );

      expect(closeDistance, isNotNull);
      expect(farDistance, isNotNull);
      expect(closeDistance!, lessThan(farDistance!));
    });

    test('smaller bottle bounding boxes result in farther estimation', () {
      final nearBottle = estimator.distanceMeters(
        detectedClass: 'bottle',
        bboxHeightRelative: 0.6,
        imageHeightPx: 640,
      );
      final farBottle = estimator.distanceMeters(
        detectedClass: 'bottle',
        bboxHeightRelative: 0.15,
        imageHeightPx: 640,
      );

      expect(nearBottle, isNotNull);
      expect(farBottle, isNotNull);
      expect(nearBottle!, lessThan(farBottle!));
    });

    test('unknown classes return null', () {
      final distance = estimator.distanceMeters(
        detectedClass: 'unknown_object',
        bboxHeightRelative: 0.5,
        imageHeightPx: 640,
      );
      expect(distance, isNull);
    });

    test('very small bounding boxes are ignored', () {
      final distance = estimator.distanceMeters(
        detectedClass: 'person',
        bboxHeightRelative: 0.0005,
        imageHeightPx: 640,
      );
      expect(distance, isNull);
    });
  });
}
