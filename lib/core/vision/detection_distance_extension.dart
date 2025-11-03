import 'package:ultralytics_yolo/models/yolo_result.dart';

class _DistanceHolder {
  const _DistanceHolder(this.value);
  final double value;
}

final _distanceExpando = Expando<_DistanceHolder>('distanceM');

extension YoloResultDistance on YOLOResult {
  double? get distanceM => _distanceExpando[this]?.value;

  set distanceM(double? value) {
    if (value == null) {
      _distanceExpando[this] = null;
    } else {
      _distanceExpando[this] = _DistanceHolder(value);
    }
  }
}
