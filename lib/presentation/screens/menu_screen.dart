import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:ultralytics_yolo_example/models/camera_launch_args.dart';
import 'package:ultralytics_yolo_example/models/models.dart';
import 'package:ultralytics_yolo_example/services/weather_service.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _tts = FlutterTts();
  final _stt = stt.SpeechToText();
  final _weather = WeatherService();
  bool _isListening = false;

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
      'Menú principal. Opciones: Dinero, Objetos, Lectura, Hora, Clima. Diga una opción.',
    );
  }

  Future<void> _startTalkback() async {
    if (_isListening) {
      await _stt.stop();
      setState(() => _isListening = false);
      await _speak('Voz desactivada.');
      return;
    }
    await _readMenu();
    await Future.delayed(const Duration(milliseconds: 400));
    final ok = await _stt.initialize();
    if (!ok) {
      await _speak('Micrófono no disponible.');
      return;
    }
    setState(() => _isListening = true);
    await _stt.listen(
      localeId: 'es_MX',
      listenFor: const Duration(seconds: 6),
      pauseFor: const Duration(seconds: 2),
      cancelOnError: true,
      onResult: (r) {
        if (!r.finalResult) return;
        _handleVoice(r.recognizedWords);
      },
    );
  }

  void _handleVoice(String words) async {
    final t = words.toLowerCase();
    if (t.contains('dinero') && t.contains('voz')) {
      await _stt.stop();
      setState(() => _isListening = false);
      if (!mounted) return;
      Navigator.pushNamed(context, '/money');
      return;
    }
    if (t.contains('objeto')) {
      await _stt.stop();
      setState(() => _isListening = false);
      if (!mounted) return;
      Navigator.pushNamed(context, '/camera');
      return;
    }
    if (t.contains('lectura') || t.contains('texto') || t.contains('leer')) {
      await _stt.stop();
      setState(() => _isListening = false);
      if (!mounted) return;
      Navigator.pushNamed(context, '/text-reader');
      return;
    }
    if (t.contains('hora')) {
      await _stt.stop();
      setState(() => _isListening = false);
      await _sayTime();
      return;
    }
    if (t.contains('clima')) {
      await _stt.stop();
      setState(() => _isListening = false);
      await _sayWeather();
      return;
    }
  }

  @override
  void dispose() {
    _stt.cancel();
    _tts.stop();
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