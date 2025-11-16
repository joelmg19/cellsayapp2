// Archivo: lib/main.dart

import 'package:flutter/material.dart';
import 'package:ultralytics_yolo_example/presentation/screens/camera_inference_screen.dart';
import 'package:ultralytics_yolo_example/presentation/screens/menu_screen.dart';
import 'package:ultralytics_yolo_example/presentation/screens/money_detector_screen.dart';
import 'package:ultralytics_yolo_example/presentation/screens/single_image_screen.dart';
import 'package:ultralytics_yolo_example/presentation/screens/text_reader_screen.dart';
import 'package:ultralytics_yolo_example/presentation/screens/route_screen.dart';

import 'package:ultralytics_yolo_example/presentation/screens/depth_camera_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CellSay',
      home: const MenuScreen(),
      onGenerateRoute: (settings) {
        if (settings.name == '/money') {
          // Ruta original de 'dinero' (Modo Voz/Single-Shot)
          return MaterialPageRoute(
            builder: (_) => const MoneyDetectorScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/camera') {
          return MaterialPageRoute(
            builder: (_) => const CameraInferenceScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/depth') {
          return MaterialPageRoute(
            builder: (_) => const DepthCameraScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/single-image') {
          return MaterialPageRoute(
            builder: (_) => const SingleImageScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/text-reader') {
          return MaterialPageRoute(
            builder: (_) => const TextReaderScreen(),
            settings: settings,
          );
        }
        if (settings.name == '/route') {
          return MaterialPageRoute(
            builder: (_) => const RouteScreen(),
            settings: settings,
          );
        }

        return null;
      },
    );
  }
}
