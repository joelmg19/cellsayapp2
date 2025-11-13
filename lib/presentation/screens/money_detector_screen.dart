import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

class MoneyDetectorScreen extends StatefulWidget {
  const MoneyDetectorScreen({super.key});

  @override
  State<MoneyDetectorScreen> createState() => _MoneyDetectorScreenState();
}

class _MoneyDetectorScreenState extends State<MoneyDetectorScreen> {
  late CameraController _controller;
  bool _isProcessing = false;
  bool _initialized = false;

  final FlutterTts _tts = FlutterTts();
  final String _apiKey = 'rx16MJGY0rif2b1WcdJC';
  final String _modelId = 'billetescl-syltq';
  final String _version = '5';

  // 🔊 Tiempo mínimo entre voces iguales
  Duration voiceCooldown = const Duration(seconds: 3);
  DateTime lastVoiceTime = DateTime.now().subtract(const Duration(seconds: 5));

  List<Map<String, dynamic>> _detections = [];
  double? _imgW;
  double? _imgH;
  final Map<String, String> labelToSpeech = {
    "billete_1000": "Billete de mil pesos chilenos",
    "billete_2000": "Billete de dos mil pesos chilenos",
    "billete_5000": "Billete de cinco mil pesos chilenos",
    "billete_10000": "Billete de diez mil pesos chilenos",
    "billete_20000": "Billete de veinte mil pesos chilenos",
  };

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initCamera();
  }

  Future<void> _initTTS() async {
    await _tts.setLanguage('es-ES');
    await _tts.setSpeechRate(0.9);
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) return;

    final cameras = await availableCameras();
    _controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller.initialize();
    setState(() => _initialized = true);

    _controller.startImageStream(_processCameraStream);
  }

  Future<void> _processCameraStream(CameraImage image) async {
    final now = DateTime.now();
    if (_isProcessing || now.difference(lastVoiceTime) < const Duration(seconds: 2)) return;

    _isProcessing = true;

    try {
      final jpegBytes = _convertYUVToJpeg(image);
      await _sendToRoboflow(jpegBytes);
    } catch (e) {
      debugPrint("😭Error procesamiento: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Uint8List _convertYUVToJpeg(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final imgRGB = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yp = yPlane.bytes[y * yPlane.bytesPerRow + x];
        final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * (uPlane.bytesPerPixel ?? 1);

        final up = uPlane.bytes[uvIndex];
        final vp = vPlane.bytes[uvIndex];

        int r = (yp + 1.370705 * (vp - 128)).clamp(0, 255).toInt();
        int g = (yp - 0.698001 * (vp - 128) - 0.337633 * (up - 128)).clamp(0, 255).toInt();
        int b = (yp + 1.732446 * (up - 128)).clamp(0, 255).toInt();

        imgRGB.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return Uint8List.fromList(img.encodeJpg(imgRGB, quality: 90));
  }

  Future<void> _sendToRoboflow(Uint8List bytes) async {
    final uri = Uri.parse(
        "https://detect.roboflow.com/$_modelId/$_version?api_key=$_apiKey&confidence=40");

    final request = http.MultipartRequest("POST", uri)
      ..files.add(http.MultipartFile.fromBytes("file", bytes,
          filename: "img.jpg", contentType: MediaType("image", "jpeg")));

    final body = await http.Response.fromStream(await request.send());

    if (body.statusCode != 200) return;

    final data = jsonDecode(body.body);
    final preds = List<Map<String, dynamic>>.from(data["predictions"]);
    final imgData = data["image"];

    setState(() {
      _detections = preds;
      _imgW = (imgData?["width"] ?? 0).toDouble();
      _imgH = (imgData?["height"] ?? 0).toDouble();
    });

    if (preds.isNotEmpty) {
      final label = preds.first["class"];

      final now = DateTime.now();
      if (now.difference(lastVoiceTime) > voiceCooldown) {
        lastVoiceTime = now;
        final speech = labelToSpeech[label] ?? "Billete";
        await _tts.speak(speech);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Detector de Billetes")),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller),
          CustomPaint(
            painter: DetectionPainter(
              detections: _detections,
              rawImageW: _imgW,
              rawImageH: _imgH,
            ),
          ),
        ],
      ),
    );
  }
}

class DetectionPainter extends CustomPainter {
  final List<Map<String, dynamic>> detections;
  final double? rawImageW;
  final double? rawImageH;

  DetectionPainter({
    required this.detections,
    required this.rawImageW,
    required this.rawImageH,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (rawImageW == null || rawImageH == null) return;

    final sx = size.width / rawImageW!;
    final sy = size.height / rawImageH!;

    final rectPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final textStyle = const TextStyle(
      color: Colors.white,
      fontSize: 13,
      backgroundColor: Colors.black87,
    );

    for (var det in detections) {
      final x = det["x"].toDouble();
      final y = det["y"].toDouble();
      final w = det["width"].toDouble();
      final h = det["height"].toDouble();
      final label = det["class"];

      final left = (x - w / 2) * sx;
      final top = (y - h / 2) * sy;

      canvas.drawRect(Rect.fromLTWH(left, top, w * sx, h * sy), rectPaint);

      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(left, top - 18));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}



