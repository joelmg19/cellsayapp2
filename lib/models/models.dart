import 'package:ultralytics_yolo/models/yolo_task.dart';

enum ModelType {
  Interior('yolo11n', YOLOTask.detect, 'Detección General'),
  Exterior('best_float16', YOLOTask.detect, 'Detección Exterior'),
  LectorCarteles('carteles', YOLOTask.detect, 'Lector de Carteles'); // <-- AÑADE ESTA LÍNEA

  const ModelType(this.modelName, this.task, this.displayName);

  final String modelName;
  final YOLOTask task;
  final String displayName;
}

ModelType modelTypeFromString(String? value, {ModelType fallback = ModelType.Interior}) {
  if (value == null) return fallback;
  final normalized = value.toLowerCase();
  switch (normalized) {
    case 'interior':
      return ModelType.Interior;
    case 'exterior':
      return ModelType.Exterior;
    case 'lectorcarteles': // <-- AÑADE ESTA LÍNEA
      return ModelType.LectorCarteles; // <-- AÑADE ESTA LÍNEA
    case 'dinero':
    case 'money': // Compatibilidad con valores previos
      return ModelType.Interior;
  }
  return fallback;
}

enum SliderType { none, numItems, confidence, iou }