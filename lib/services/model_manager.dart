import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/utils/map_converter.dart';
import 'package:ultralytics_yolo/config/channel_config.dart';
import '../models/models.dart';

/// Manages YOLO model loading, downloading, and caching.
///
/// This class handles:
/// - Checking for existing models in the app bundle
/// - Downloading models from the Ultralytics GitHub releases
/// - Extracting and caching models locally
/// - Platform-specific model path management
class ModelManager {
  /// Base URL for downloading model files from GitHub releases
  static const String _modelDownloadBaseUrl =
      'https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.0.0';

  // --- INICIO DE LA MODIFICACIÓN ---
  /// Lista de modelos locales que NO deben ser descargados.
  static const List<String> _localCustomModels = [
    'best_float16',
    'carteles', // Añade el nombre base de tu nuevo modelo aquí
  ];
  // --- FIN DE LA MODIFICACIÓN ---

  static final MethodChannel _channel =
  ChannelConfig.createSingleImageChannel();

  /// Callback for download progress updates (0.0 to 1.0)
  final void Function(double progress)? onDownloadProgress;

  /// Callback for status message updates
  final void Function(String message)? onStatusUpdate;

  /// Creates a new ModelManager instance
  ///
  /// [onDownloadProgress] is called with progress updates during model downloads
  /// [onStatusUpdate] is called with status messages during model operations
  ModelManager({this.onDownloadProgress, this.onStatusUpdate});

  /// Gets the appropriate model path for the current platform and model type.
  Future<String?> getModelPath(ModelType modelType) async => Platform.isIOS
      ? _getIOSModelPath(modelType)
      : Platform.isAndroid
      ? _getAndroidModelPath(modelType)
      : null;

  /// Gets the iOS model path (.mlpackage format).
  Future<String?> _getIOSModelPath(ModelType modelType) async {
    _updateStatus('Checking for ${modelType.modelName} model...');
    try {
      final bundleCheck = await _checkModelExistsInBundle(modelType.modelName);
      if (bundleCheck['exists'] == true) return modelType.modelName;
    } catch (_) {}
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${dir.path}/${modelType.modelName}.mlpackage');
    if (await modelDir.exists()) {
      if (await File('${modelDir.path}/Manifest.json').exists()) {
        return modelDir.path;
      }
      await modelDir.delete(recursive: true);
    }
    _updateStatus('Downloading ${modelType.modelName} model...');
    return _downloadIOSModel(modelType);
  }

  /// Check if a model exists in the iOS bundle
  Future<Map<String, dynamic>> _checkModelExistsInBundle(
      String modelName,
      ) async {
    if (!Platform.isIOS) return {'exists': false};
    try {
      final result = await _channel.invokeMethod('checkModelExists', {
        'modelPath': modelName,
      });
      return MapConverter.convertToTypedMap(result);
    } catch (_) {
      return {'exists': false};
    }
  }

  /// Download iOS model (.mlpackage format) or extract from assets
  Future<String?> _downloadIOSModel(ModelType modelType) async {
    final dir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${dir.path}/${modelType.modelName}.mlpackage');
    if (await modelDir.exists()) return modelDir.path;
    try {
      final zipData = await rootBundle.load(
        'assets/models/${modelType.modelName}.mlpackage.zip',
      );
      return await _extractZip(
        zipData.buffer.asUint8List(),
        modelDir,
        modelType.modelName,
      );
    } catch (_) {}
    return await _downloadAndExtract(modelType, modelDir, '.mlpackage.zip');
  }

  /// Gets the Android model path (.tflite format)
  Future<String?> _getAndroidModelPath(ModelType modelType) async {
    _updateStatus('Checking for ${modelType.modelName} model...');
    final bundledName = '${modelType.modelName}.tflite';

    // Check Android native assets first
    try {
      final result = await _channel.invokeMethod('checkModelExists', {
        'modelPath': bundledName,
      });
      if (result != null && result['exists'] == true) {
        return result['location'] == 'assets'
            ? bundledName
            : result['path'] as String;
      }
    } catch (_) {}

    // Check local storage
    final dir = await getApplicationDocumentsDirectory();
    final modelFile = File('${dir.path}/$bundledName');
    if (await modelFile.exists()) return modelFile.path;

    // Try extracting from bundled Flutter assets for custom/local models.
    final assetBytes = await _loadBundledModel(bundledName);
    if (assetBytes != null && assetBytes.isNotEmpty) {
      await modelFile.writeAsBytes(assetBytes, flush: true);
      return modelFile.path;
    }

    // --- INICIO DE LA MODIFICACIÓN ---
    // Si es un modelo custom, no intentes descargarlo.
    if (_localCustomModels.contains(modelType.modelName)) {
      _updateStatus('Error: Modelo local ${modelType.modelName} no encontrado en assets/models/');
      return null;
    }
    // --- FIN DE LA MODIFICACIÓN ---

    // Download if not found locally or in assets
    _updateStatus('Downloading ${modelType.modelName} model...');
    final bytes = await _downloadFile('$_modelDownloadBaseUrl/$bundledName');
    if (bytes != null && bytes.isNotEmpty) {
      await modelFile.writeAsBytes(bytes, flush: true);
      return modelFile.path;
    }
    return null;
  }

  /// Helper method to download file with progress tracking
  Future<List<int>?> _downloadFile(String url) async {
    try {
      final client = http.Client();
      final request = await client.send(http.Request('GET', Uri.parse(url)));
      final contentLength = request.contentLength ?? 0;
      final bytes = <int>[];
      int downloadedBytes = 0;

      await for (final chunk in request.stream) {
        bytes.addAll(chunk);
        downloadedBytes += chunk.length;
        if (contentLength > 0) {
          onDownloadProgress?.call(downloadedBytes / contentLength);
        }
      }
      client.close();
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Helper method to extract zip file
  Future<String?> _extractZip(
      List<int> bytes,
      Directory targetDir,
      String modelName,
      ) async {
    try {
      _updateStatus('Extracting model...');
      final archive = ZipDecoder().decodeBytes(bytes);
      await targetDir.create(recursive: true);
      String? prefix;
      if (archive.files.isNotEmpty) {
        final first = archive.files.first.name;
        if (first.contains('/') &&
            first.split('/').first.endsWith('.mlpackage')) {
          final topDir = first.split('/').first;
          if (archive.files.every(
                (f) => f.name.startsWith('$topDir/') || f.name == topDir,
          )) {
            prefix = '$topDir/';
          }
        }
      }
      for (final file in archive) {
        var filename = file.name;
        if (prefix != null) {
          if (filename.startsWith(prefix)) {
            filename = filename.substring(prefix.length);
          } else if (filename == prefix.replaceAll('/', '')) {
            continue;
          }
        }
        if (filename.isEmpty) continue;
        if (file.isFile) {
          final outputFile = File('${targetDir.path}/$filename');
          await outputFile.parent.create(recursive: true);
          await outputFile.writeAsBytes(file.content as List<int>);
        }
      }
      return targetDir.path;
    } catch (_) {
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      return null;
    }
  }

  Future<List<int>?> _loadBundledModel(String bundledName) async {
    try {
      final data = await rootBundle.load('assets/models/$bundledName');
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// Helper method to download and extract model
  Future<String?> _downloadAndExtract(
      ModelType modelType,
      Directory targetDir,
      String ext,
      ) async {
    final bytes = await _downloadFile(
      '$_modelDownloadBaseUrl/${modelType.modelName}$ext',
    );
    if (bytes == null) return null;
    return ext.contains('zip')
        ? await _extractZip(bytes, targetDir, modelType.modelName)
        : (await File(targetDir.path).writeAsBytes(bytes), targetDir.path).$2;
  }

  /// Updates the status message
  void _updateStatus(String message) => onStatusUpdate?.call(message);
}