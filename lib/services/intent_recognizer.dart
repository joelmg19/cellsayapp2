import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// High-level intent group used by the voice command model.
enum IntentGroup {
  menu,
  dinero,
  objetos,
  profundidad,
  lectura,
  hora,
  clima,
  camaraAyuda,
  camaraLectorCarteles,
  camaraTexto,
  camaraVoz,
  camaraZoom,
  camaraRepetir,
  unknown,
}

/// Result returned by [IntentRecognizer].
class IntentRecognitionResult {
  const IntentRecognitionResult({
    required this.label,
    required this.score,
    required this.group,
  });

  /// Label that obtained the highest score on the model output.
  final String label;

  /// Probability (after softmax) of the predicted label.
  final double score;

  /// High-level intent group derived from [label].
  final IntentGroup group;

  @override
  String toString() =>
      'IntentRecognitionResult(label: $label, score: $score, group: $group)';
}

/// Recognizes high-level intents from short audio clips using a TensorFlow Lite
/// model. The recognizer expects 16 kHz mono PCM samples and performs the same
/// MFCC preprocessing that was used during training.
class IntentRecognizer {
  IntentRecognizer({this.probabilityThreshold = 0.6});

  static const String modelAssetPath = 'assets/models/model_fp16.tflite';
  static const String labelsAssetPath = 'assets/models/labels.txt';
  static const int sampleRate = 16000;
  static const double _preEmphasis = 0.97;

  final double probabilityThreshold;

  Interpreter? _interpreter;
  List<String> _labels = const [];
  MfccProcessor? _mfcc;
  List<int>? _inputShape;
  List<int>? _outputShape;
  // Nota: eliminamos la dependencia de tflite_flutter_helper para evitar
  // incompatibilidades con camera; por ello gestionamos manualmente los buffers
  // del intérprete usando tflite_flutter puro.
  TensorType? _inputType;
  TensorType? _outputType;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Lazily loads the interpreter, labels and MFCC processor. Must be called
  /// before [recognize] or [recognizeFile].
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final options = InterpreterOptions();
      if (!kIsWeb) {
        options.threads = 2;
      }
      final interpreter = await Interpreter.fromAsset(
        modelAssetPath,
        options: options,
      );

      final inputTensor = interpreter.getInputTensor(0);
      final outputTensor = interpreter.getOutputTensor(0);
      _inputShape = List<int>.from(inputTensor.shape);
      _outputShape = List<int>.from(outputTensor.shape);
      _inputType = inputTensor.type;
      _outputType = outputTensor.type;

      _labels = await _loadLabels();
      _mfcc = _buildMfccProcessor(_inputShape!);
      _interpreter = interpreter;
      _isInitialized = true;
    } catch (error, stackTrace) {
      debugPrint('IntentRecognizer initialization failed: $error\n$stackTrace');
      rethrow;
    }
  }

  /// Releases interpreter resources.
  Future<void> dispose() async {
    try {
      _interpreter?.close();
    } catch (_) {
      // ignore
    }
    _interpreter = null;
    _inputType = null;
    _outputType = null;
    _mfcc = null;
    _inputShape = null;
    _outputShape = null;
    _isInitialized = false;
  }

  /// Performs inference on [audioSamples] (16 kHz mono PCM as floats between
  /// -1 and 1). Returns null if the probability of the best label does not
  /// reach [probabilityThreshold].
  Future<IntentRecognitionResult?> recognize(
    Float32List audioSamples,
  ) async {
    if (!_isInitialized) {
      await initialize();
    }
    final interpreter = _interpreter;
    final mfcc = _mfcc;
    final inputShape = _inputShape;
    final outputShape = _outputShape;
    if (interpreter == null || mfcc == null || inputShape == null || outputShape == null) {
      throw StateError('IntentRecognizer is not initialized.');
    }

    if (_inputType != TensorType.float32 || _outputType != TensorType.float32) {
      throw UnsupportedError('Solo se soportan modelos de tipo float32.');
    }

    final normalized = _prepareInputAudio(audioSamples);
    final features = mfcc.process(normalized);

    final requiredLength = inputShape.fold<int>(1, (value, element) => value * element);
    if (features.length != requiredLength) {
      throw StateError(
        'MFCC feature length ${features.length} does not match interpreter input length $requiredLength.',
      );
    }

    final inputData = Float32List.fromList(features);
    final reshapedInput = _reshapeInputData(inputData, inputShape);
    final outputContainer = _createZeroedOutput(outputShape);

    interpreter.run(reshapedInput, outputContainer);

    final scores = _flattenOutput(outputContainer);
    final expectedOutputLength =
        outputShape.fold<int>(1, (value, element) => value * element);
    if (scores.length != expectedOutputLength) {
      throw StateError(
        'Unexpected output length ${scores.length}; expected $expectedOutputLength.',
      );
    }
    final probabilities = _softmax(scores);

    final maxScore = probabilities.reduce(max);
    final maxIndex = probabilities.indexOf(maxScore);
    if (maxIndex < 0 || maxIndex >= _labels.length) {
      return null;
    }

    if (maxScore < probabilityThreshold) {
      return null;
    }

    final label = _labels[maxIndex];
    final group = _mapLabelToGroup(label);
    return IntentRecognitionResult(
      label: label,
      score: maxScore,
      group: group,
    );
  }

  /// Convenience wrapper around [recognize] that accepts a WAV file path.
  Future<IntentRecognitionResult?> recognizeFile(String wavFilePath) async {
    final samples = await decodeWavFile(wavFilePath);
    return recognize(samples);
  }

  /// Reads a WAV file into normalized PCM samples. Supports little-endian
  /// 16-bit PCM files.
  static Future<Float32List> decodeWavFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArgumentError('Audio file not found: $filePath');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) {
      throw FormatException('El archivo de audio es demasiado pequeño.');
    }

    final byteData = ByteData.sublistView(bytes);
    if (ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
      throw FormatException('Formato WAV inválido.');
    }

    int? channels;
    int? bitDepth;
    int? sampleRate;
    int? dataOffset;
    int? dataLength;

    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkId = ascii.decode(bytes.sublist(offset, offset + 4));
      final chunkSize = byteData.getUint32(offset + 4, Endian.little);
      final chunkStart = offset + 8;

      if (chunkId == 'fmt ') {
        final audioFormat = byteData.getUint16(chunkStart, Endian.little);
        channels = byteData.getUint16(chunkStart + 2, Endian.little);
        sampleRate = byteData.getUint32(chunkStart + 4, Endian.little);
        bitDepth = byteData.getUint16(chunkStart + 14, Endian.little);
        if (audioFormat != 1) {
          throw FormatException('Solo se soporta PCM lineal.');
        }
      } else if (chunkId == 'data') {
        dataOffset = chunkStart;
        dataLength = chunkSize;
        break;
      }

      offset = chunkStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (channels == null ||
        bitDepth == null ||
        sampleRate == null ||
        dataOffset == null ||
        dataLength == null) {
      throw FormatException('El archivo WAV no contiene encabezados válidos.');
    }

    if (channels != 1) {
      throw FormatException('El archivo WAV debe ser mono.');
    }

    if (bitDepth != 16) {
      throw FormatException('El archivo WAV debe ser PCM de 16 bits.');
    }

    if (sampleRate != IntentRecognizer.sampleRate) {
      throw FormatException(
        'Se esperaba una frecuencia de muestreo de ${IntentRecognizer.sampleRate} Hz, se obtuvo $sampleRate Hz.',
      );
    }

    final frameBytes = bytes.sublist(dataOffset, dataOffset + dataLength);
    final samples = Int16List.view(
      frameBytes.buffer,
      frameBytes.offsetInBytes,
      frameBytes.lengthInBytes ~/ 2,
    );
    final floatSamples = Float32List(samples.length);
    const double scale = 1 / 32768.0;
    for (var i = 0; i < samples.length; i++) {
      floatSamples[i] = samples[i] * scale;
    }
    return floatSamples;
  }

  List<double> _prepareInputAudio(Float32List input) {
    final expectedSamples = sampleRate;
    final normalized = Float32List(expectedSamples);

    if (input.length >= expectedSamples) {
      normalized.setAll(0, input.sublist(input.length - expectedSamples));
    } else {
      final start = expectedSamples - input.length;
      for (int i = 0; i < start; i++) {
        normalized[i] = 0;
      }
      normalized.setAll(start, input);
    }

    // Apply pre-emphasis filter.
    final emphasized = List<double>.generate(expectedSamples, (index) {
      if (index == 0) return normalized[index].toDouble();
      return normalized[index] - _preEmphasis * normalized[index - 1];
    });
    return emphasized;
  }

  dynamic _reshapeInputData(Float32List data, List<int> shape) {
    if (shape.isEmpty) {
      throw StateError('Input shape cannot be empty.');
    }
    var index = 0;

    dynamic build(int dimension) {
      final size = shape[dimension];
      if (dimension == shape.length - 1) {
        return List<double>.generate(size, (_) {
          if (index >= data.length) {
            throw StateError('Input data is shorter than expected for shape $shape.');
          }
          return data[index++];
        }, growable: false);
      }
      return List.generate(size, (_) => build(dimension + 1), growable: false);
    }

    final reshaped = build(0);
    if (index != data.length) {
      throw StateError('Input data length ${data.length} does not match shape $shape.');
    }
    return reshaped;
  }

  dynamic _createZeroedOutput(List<int> shape) {
    if (shape.isEmpty) {
      return <double>[];
    }
    if (shape.length == 1) {
      return List<double>.filled(shape.first, 0.0, growable: false);
    }
    final tailShape = shape.sublist(1);
    return List.generate(shape.first, (_) => _createZeroedOutput(tailShape), growable: false);
  }

  List<double> _flattenOutput(dynamic tensor) {
    final result = <double>[];
    void collect(dynamic value) {
      if (value is List) {
        for (final element in value) {
          collect(element);
        }
      } else if (value is num) {
        result.add(value.toDouble());
      }
    }

    collect(tensor);
    return result;
  }

  Future<List<String>> _loadLabels() async {
    final raw = await rootBundle.loadString(labelsAssetPath);
    final labels = raw
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((element) => element.isNotEmpty)
        .toList();
    if (labels.isEmpty) {
      throw StateError('El archivo de etiquetas está vacío.');
    }
    return labels;
  }

  MfccProcessor _buildMfccProcessor(List<int> inputShape) {
    int frameCount;
    int featureCount;
    if (inputShape.length == 4) {
      frameCount = inputShape[1];
      featureCount = inputShape[2];
    } else if (inputShape.length == 3) {
      frameCount = inputShape[1];
      featureCount = inputShape[2];
    } else {
      throw StateError('Dimensión de entrada no soportada: $inputShape');
    }
    return MfccProcessor(
      sampleRate: sampleRate,
      frameCount: frameCount,
      featureCount: featureCount,
    );
  }

  List<double> _softmax(List<double> logits) {
    if (logits.isEmpty) return const [];
    final maxLogit = logits.reduce(max);
    final expValues = logits.map((value) => exp(value - maxLogit)).toList();
    final sum = expValues.fold<double>(0, (a, b) => a + b);
    if (sum == 0) {
      return List<double>.filled(logits.length, 0);
    }
    return expValues.map((value) => value / sum).toList(growable: false);
  }

  IntentGroup _mapLabelToGroup(String label) {
    final value = label.toLowerCase().trim();
    bool containsAny(Iterable<String> keywords) =>
        keywords.any((keyword) => value.contains(keyword));

    if (containsAny(['lector', 'cartel'])) {
      return IntentGroup.camaraLectorCarteles;
    }
    if (containsAny(['texto', 'tamano', 'tamaño', 'fuente'])) {
      return IntentGroup.camaraTexto;
    }
    if (containsAny(['voz', 'narr', 'hablar', 'audio'])) {
      return IntentGroup.camaraVoz;
    }
    if (containsAny(['zoom'])) {
      return IntentGroup.camaraZoom;
    }
    if (containsAny(['repite', 'repetir', 'otra vez', 'vuelve'])) {
      return IntentGroup.camaraRepetir;
    }
    if (containsAny(['camara', 'opciones de camara', 'modo camara'])) {
      return IntentGroup.camaraAyuda;
    }
    if (containsAny(['dinero', 'billete', 'moneda'])) {
      return IntentGroup.dinero;
    }
    if (containsAny(['objeto', 'enfocar', 'clasificar'])) {
      return IntentGroup.objetos;
    }
    if (containsAny(['profund', 'distancia', 'sensor'])) {
      return IntentGroup.profundidad;
    }
    if (containsAny(['lectur', 'ocr', 'leer'])) {
      return IntentGroup.lectura;
    }
    if (containsAny(['hora', 'reloj'])) {
      return IntentGroup.hora;
    }
    if (containsAny(['clima', 'tiempo', 'pronostico', 'temperatura'])) {
      return IntentGroup.clima;
    }
    if (containsAny(['ayuda', 'menu', 'opcion', 'instruccion'])) {
      return IntentGroup.menu;
    }
    return IntentGroup.unknown;
  }
}

/// Helper that generates MFCC features expected by the TensorFlow Lite model.
class MfccProcessor {
  MfccProcessor({
    required this.sampleRate,
    required this.frameCount,
    required this.featureCount,
    this.frameLengthMs = 40,
    this.frameStepMs = 20,
    this.numMelFilters = 40,
  })  : frameLength = (sampleRate * frameLengthMs / 1000).round(),
        frameStep = (sampleRate * frameStepMs / 1000).round(),
        fftSize = _nextPowerOfTwo(
          (sampleRate * frameLengthMs / 1000).round(),
        ) {
    _hammingWindow = List<double>.generate(
      frameLength,
      (i) => 0.54 - 0.46 * cos(2 * pi * i / (frameLength - 1)),
    );
    _melFilterBank = _createMelFilterBank();
    _dctMatrix = _createDctMatrix();
  }

  final int sampleRate;
  final int frameCount;
  final int featureCount;
  final int frameLengthMs;
  final int frameStepMs;
  final int numMelFilters;
  late final int frameLength;
  late final int frameStep;
  late final int fftSize;

  late final List<double> _hammingWindow;
  late final List<List<double>> _melFilterBank;
  late final List<List<double>> _dctMatrix;

  List<double> process(List<double> audio) {
    final frames = _extractFrames(audio);
    final features = List<double>.filled(frameCount * featureCount, 0);

    final melEnergies = List<double>.filled(numMelFilters, 0);
    final spectrum = List<double>.filled(fftSize ~/ 2 + 1, 0);
    final buffer = Float32List(fftSize);
    final imag = Float32List(fftSize);

    final fft = FFT(fftSize);

    int featureIndex = 0;
    for (final frame in frames) {
      buffer.fillRange(0, fftSize, 0);
      imag.fillRange(0, fftSize, 0);
      for (var i = 0; i < frameLength; i++) {
        buffer[i] = frame[i];
      }
      fft.transform(buffer, imag);

      for (var i = 0; i < spectrum.length; i++) {
        final real = buffer[i];
        final imaginary = imag[i];
        spectrum[i] = real * real + imaginary * imaginary;
      }

      for (var i = 0; i < numMelFilters; i++) {
        double energy = 0;
        final filter = _melFilterBank[i];
        for (var j = 0; j < filter.length; j++) {
          energy += spectrum[j] * filter[j];
        }
        melEnergies[i] = log(max(energy, 1e-10));
      }

      for (var i = 0; i < featureCount; i++) {
        double sum = 0;
        final dctRow = _dctMatrix[i];
        for (var j = 0; j < numMelFilters; j++) {
          sum += dctRow[j] * melEnergies[j];
        }
        features[featureIndex++] = sum;
      }
    }

    // Normalize features to zero mean and unit variance.
    final mean =
        features.reduce((value, element) => value + element) / features.length;
    double variance = 0;
    for (final value in features) {
      final diff = value - mean;
      variance += diff * diff;
    }
    variance /= features.length;
    final std = sqrt(max(variance, 1e-9));
    for (var i = 0; i < features.length; i++) {
      features[i] = (features[i] - mean) / std;
    }

    return features;
  }

  List<List<double>> _extractFrames(List<double> audio) {
    final frames = <List<double>>[];
    int index = 0;
    for (var i = 0; i < frameCount; i++) {
      final frame = List<double>.filled(frameLength, 0);
      for (var j = 0; j < frameLength; j++) {
        final sampleIndex = index + j;
        if (sampleIndex < audio.length) {
          frame[j] = audio[sampleIndex] * _hammingWindow[j];
        }
      }
      frames.add(frame);
      index += frameStep;
      if (index + frameLength > audio.length) {
        index = audio.length - frameLength;
        if (index < 0) index = 0;
      }
    }
    return frames;
  }

  List<List<double>> _createMelFilterBank() {
    final filters = <List<double>>[];
    final nyquist = sampleRate / 2;
    final fftBins = fftSize ~/ 2 + 1;

    double hzToMel(double hz) => 2595 * log(1 + hz / 700) / ln10;
    double melToHz(double mel) => 700 * (pow(10, mel / 2595) - 1);

    final melMin = hzToMel(0);
    final melMax = hzToMel(nyquist.toDouble());
    final melPoints = List<double>.generate(
      numMelFilters + 2,
      (i) => melMin + (melMax - melMin) * i / (numMelFilters + 1),
    );
    final binFrequencies = melPoints.map(melToHz).toList();
    final binIndices = binFrequencies
        .map((freq) => freq.floor() * (fftSize ~/ 2 + 1) / nyquist)
        .map((value) => value.round())
        .toList();

    for (var i = 1; i <= numMelFilters; i++) {
      final filter = List<double>.filled(fftBins, 0);
      final left = binIndices[i - 1];
      final center = binIndices[i];
      final right = binIndices[i + 1];
      if (right <= left) {
        filters.add(filter);
        continue;
      }
      for (var j = left; j < center; j++) {
        if (j >= 0 && j < fftBins) {
          filter[j] = (j - left) / (center - left);
        }
      }
      for (var j = center; j < right; j++) {
        if (j >= 0 && j < fftBins) {
          filter[j] = (right - j) / (right - center);
        }
      }
      filters.add(filter);
    }
    return filters;
  }

  List<List<double>> _createDctMatrix() {
    final matrix = <List<double>>[];
    final scale = sqrt(2 / numMelFilters);
    for (var i = 0; i < featureCount; i++) {
      final row = List<double>.filled(numMelFilters, 0);
      for (var j = 0; j < numMelFilters; j++) {
        row[j] = scale * cos(pi * i * (2 * j + 1) / (2 * numMelFilters));
      }
      if (i == 0) {
        for (var j = 0; j < numMelFilters; j++) {
          row[j] /= sqrt(2);
        }
      }
      matrix.add(row);
    }
    return matrix;
  }
}

class FFT {
  FFT(this.size);

  final int size;

  void transform(Float32List real, Float32List imag) {
    if (real.length != size || imag.length != size) {
      throw ArgumentError('FFT input length mismatch.');
    }
    _fft(real, imag, false);
  }

  void _fft(Float32List real, Float32List imag, bool inverse) {
    final n = size;
    if (n <= 1) return;

    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while (j & bit != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;

      if (i < j) {
        final tempReal = real[i];
        final tempImag = imag[i];
        real[i] = real[j];
        imag[i] = imag[j];
        real[j] = tempReal;
        imag[j] = tempImag;
      }
    }

    for (int len = 2; len <= n; len <<= 1) {
      final angle = 2 * pi / len * (inverse ? -1 : 1);
      final wlenReal = cos(angle);
      final wlenImag = sin(angle);
      for (int i = 0; i < n; i += len) {
        double wReal = 1;
        double wImag = 0;
        for (int j = 0; j < len / 2; j++) {
          final uReal = real[i + j];
          final uImag = imag[i + j];
          final vReal = real[i + j + len ~/ 2] * wReal -
              imag[i + j + len ~/ 2] * wImag;
          final vImag = real[i + j + len ~/ 2] * wImag +
              imag[i + j + len ~/ 2] * wReal;
          real[i + j] = uReal + vReal;
          imag[i + j] = uImag + vImag;
          real[i + j + len ~/ 2] = uReal - vReal;
          imag[i + j + len ~/ 2] = uImag - vImag;
          final nextReal = wReal * wlenReal - wImag * wlenImag;
          final nextImag = wReal * wlenImag + wImag * wlenReal;
          wReal = nextReal;
          wImag = nextImag;
        }
      }
    }

    if (inverse) {
      for (int i = 0; i < n; i++) {
        real[i] /= n;
        imag[i] /= n;
      }
    }
  }
}

int _nextPowerOfTwo(int value) {
  var v = value - 1;
  v |= v >> 1;
  v |= v >> 2;
  v |= v >> 4;
  v |= v >> 8;
  v |= v >> 16;
  return v + 1;
}
