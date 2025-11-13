import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:ultralytics_yolo_example/models/camera_launch_args.dart';
import 'package:ultralytics_yolo_example/models/models.dart';
import 'package:ultralytics_yolo_example/services/weather_service.dart';
import 'package:ultralytics_yolo_example/services/intent_recognizer.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _tts = FlutterTts();
  final _intentRecognizer = IntentRecognizer();
  final AudioRecorder _recorder = AudioRecorder();
  final _weather = WeatherService();
  bool _isListening = false;
  bool _isRecognizerReady = false;
  bool _isLoopActive = false;
  static const Duration _listenDuration = Duration(seconds: 2);
  static const double _intentThreshold = 0.6;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeRecognizer());
  }

  Future<void> _initializeRecognizer() async {
    try {
      await _intentRecognizer.initialize();
      if (!mounted) return;
      setState(() => _isRecognizerReady = true);
    } catch (error) {
      debugPrint('No se pudo cargar el modelo de intenciones: $error');
    }
  }

  Future<void> _speak(String text) async {
    await _tts.setLanguage('es-MX');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(text);
  }

  Future<void> _sayTime() async {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    await _speak('La hora es $h con $m minutos.');
  }

  Future<void> _sayWeather() async {
    final info = await _weather.loadCurrentWeather();
    if (info == null) {
      await _speak('No pude obtener el clima ahora.');
      return;
    }
    await _speak('Clima actual: ${info.formatSummary()}');
  }

  Future<void> _readMenu() async {
    await _speak(
      'Menú principal. Opciones: Dinero, Objetos, Profundidad, Lectura, Hora, Clima. Diga una opción.',
    );
  }

  Future<void> _startTalkback() async {
    if (_isListening) {
      await _stopListening();
      await _speak('Voz desactivada.');
      return;
    }
    if (!_isRecognizerReady) {
      await _initializeRecognizer();
    }
    if (!_isRecognizerReady) {
      await _speak('No pude activar el reconocimiento de comandos.');
      return;
    }
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      await _speak('Permiso de micrófono denegado.');
      return;
    }
    setState(() => _isListening = true);
    await _readMenu();
    await Future.delayed(const Duration(milliseconds: 300));
    if (!_isLoopActive) {
      _listenLoop();
    }
  }

  Future<void> _listenLoop() async {
    if (_isLoopActive) return;
    _isLoopActive = true;
    try {
      while (_isListening && mounted) {
        final result = await _captureIntent();
        if (!_isListening || !mounted) break;
        if (result == null) {
          await _speak(
            'No pude entender la opción. Por favor, dilo de nuevo.',
          );
          continue;
        }
        final handled = await _handleIntentResult(result);
        if (!handled && _isListening && mounted) {
          await _speak(
            'No pude procesar esa opción. Intenta de nuevo.',
          );
        }
      }
    } finally {
      _isLoopActive = false;
    }
  }

  Future<IntentRecognitionResult?> _captureIntent() async {
    final directory = await getTemporaryDirectory();
    final filePath = p.join(
      directory.path,
      'menu_intent_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: IntentRecognizer.sampleRate,
          bitRate: 128000,
          numChannels: 1,
        ),
        path: filePath,
      );
    } catch (error) {
      debugPrint('Error al iniciar captura de audio del menú: $error');
      await _speak('No pude acceder al micrófono.');
      await _stopListening();
      return null;
    }

    await Future<void>.delayed(_listenDuration);
    String? recordedPath;
    try {
      recordedPath = await _recorder.stop();
    } catch (error) {
      debugPrint('Error al detener captura de audio del menú: $error');
      recordedPath = null;
    }

    if (recordedPath == null) {
      await File(filePath).delete().catchError((_) {});
      return null;
    }

    try {
      final result = await _intentRecognizer.recognizeFile(recordedPath);
      if (result == null || result.score < _intentThreshold) {
        return null;
      }
      return result;
    } catch (error) {
      debugPrint('Error clasificando comando de menú: $error');
      return null;
    } finally {
      await File(recordedPath).delete().catchError((_) {});
    }
  }

  Future<bool> _handleIntentResult(IntentRecognitionResult result) async {
    switch (result.group) {
      case IntentGroup.dinero:
        await _stopListening();
        if (!mounted) return true;
        Navigator.pushNamed(context, '/money');
        return true;
      case IntentGroup.objetos:
        await _stopListening();
        if (!mounted) return true;
        Navigator.pushNamed(context, '/camera');
        return true;
      case IntentGroup.profundidad:
        await _stopListening();
        if (!mounted) return true;
        Navigator.pushNamed(context, '/depth');
        return true;
      case IntentGroup.lectura:
        await _stopListening();
        if (!mounted) return true;
        Navigator.pushNamed(context, '/text-reader');
        return true;
      case IntentGroup.hora:
        await _stopListening();
        await _sayTime();
        return true;
      case IntentGroup.clima:
        await _stopListening();
        await _sayWeather();
        return true;
      case IntentGroup.menu:
        await _speak(
          'Opciones: Dinero, Objetos, Profundidad, Lectura, Hora y Clima.',
        );
        return true;
      case IntentGroup.camaraAyuda:
      case IntentGroup.camaraLectorCarteles:
      case IntentGroup.camaraTexto:
      case IntentGroup.camaraVoz:
      case IntentGroup.camaraZoom:
      case IntentGroup.camaraRepetir:
        await _speak('Ese comando pertenece al modo cámara. Diga una opción del menú.');
        return true;
      case IntentGroup.unknown:
        return false;
    }
  }

  Future<void> _stopListening() async {
    if (!_isListening) return;
    setState(() => _isListening = false);
    try {
      await _recorder.stop();
    } catch (_) {
      // ignore
    }
  }

  @override
  void dispose() {
    _tts.stop();
    _intentRecognizer.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <_BigButton>[
      // 1. Botón para el modo de voz (el que tenías antes)
      _BigButton(
        label: 'Dinero',
        icon: Icons.attach_money_rounded,
        onTap: () => Navigator.pushNamed(context, '/money'),
      ),
      _BigButton(
        label: 'Objetos',
        icon: Icons.center_focus_strong_rounded,
        onTap: () => Navigator.pushNamed(context, '/camera'),
      ),
      _BigButton(
        label: 'Profundidad',
        icon: Icons.straighten,
        onTap: () => Navigator.pushNamed(context, '/depth'),
      ),
      _BigButton(
        label: 'Lectura',
        icon: Icons.menu_book_rounded,
        onTap: () => Navigator.pushNamed(context, '/text-reader'),
      ),
      _BigButton(
        label: 'Hora',
        icon: Icons.access_time_rounded,
        onTap: _sayTime,
      ),
      _BigButton(
        label: 'Clima',
        icon: Icons.cloud_outlined,
        onTap: _sayWeather,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 140,
        centerTitle: true,
        title: CircleAvatar(
          radius: 44,
          backgroundColor: Colors.transparent,
          backgroundImage: const AssetImage('assets/applogo.png'),
        ),
        automaticallyImplyLeading: false,
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          height: 56,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Row(
                children: [
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _startTalkback,
                    icon: Icon(_isListening ? Icons.hearing_disabled : Icons.hearing),
                    label: Text(_isListening ? 'Talback ON' : 'Talback'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              for (final b in buttons) ...[
                SizedBox(width: double.infinity, child: b),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _BigButton({required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 22),
      label: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}