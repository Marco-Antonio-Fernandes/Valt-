import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/vault_backend_config.dart';
import '../models/piper_voice.dart';
import 'tts_service.dart' show TtsService;

const String _ttsCacheDirName = 'vault_sherpa_tts_v12';

/// Status of a single voice on disk.
enum VoiceDownloadStatus { notDownloaded, downloading, downloaded }

/// Progress for an in-flight download.
class VoiceDownloadProgress {
  const VoiceDownloadProgress({
    this.received = 0,
    this.total = 0,
    this.status = VoiceDownloadStatus.notDownloaded,
  });

  final int received;
  final int total;
  final VoiceDownloadStatus status;

  double get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
}

class PiperVoiceService {
  PiperVoiceService._();
  static final PiperVoiceService instance = PiperVoiceService._();

  /// Cloudflare/CDN pode devolver **403** a clientes com UA vazio/`Dart/` em GET de ficheiros
  /// grandes — UA explícito alinha comportamento ao browser quando o servidor está correto.
  static const _dioHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14; VaultTtsDownloader) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
    'Accept': '*/*',
  };

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 10),
    headers: _dioHeaders,
  ));

  Directory? _cacheDir;

  final _progressController =
      StreamController<Map<String, VoiceDownloadProgress>>.broadcast();

  Stream<Map<String, VoiceDownloadProgress>> get progressStream =>
      _progressController.stream;

  final Map<String, VoiceDownloadProgress> _progressMap = {};
  final Map<String, CancelToken> _activeCancels = {};

  Map<String, VoiceDownloadProgress> get currentProgress =>
      Map.unmodifiable(_progressMap);

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final doc = await getApplicationDocumentsDirectory();
    _cacheDir = Directory(p.join(doc.path, _ttsCacheDirName));
    await _cacheDir!.create(recursive: true);
    return _cacheDir!;
  }

  /// Pasta de instalação: nome canónico sempre em minúsculas (`TtsService` + prefs sherpa).
  /// Se existir pasta legacy só com casing diferente, renomeia para o nome canónico.
  Future<Directory> _voiceInstallDirectoryForWrite(
      Directory cache, String voiceKey) async {
    final want = TtsService.normalizedVoiceFolderName(voiceKey);
    final target = Directory(p.join(cache.path, want));
    if (await target.exists()) return target;

    try {
      Directory? legacy;
      await for (final e in cache.list(followLinks: false)) {
        if (e is! Directory) continue;
        final bn = p.basename(e.path);
        if (bn.toLowerCase() != want) continue;
        if (bn != want) {
          legacy = Directory(e.path);
          break;
        }
      }
      if (legacy != null && await legacy.exists()) {
        try {
          await legacy.rename(target.path);
        } catch (_) {
          return legacy;
        }
      }
    } catch (_) {}

    await target.create(recursive: true);
    return target;
  }

  /// Localiza pasta instalada sem criar — aceita casing legacy no disco.
  Future<Directory?> _locateInstalledVoiceDirectory(
      Directory cache, String voiceKey) async {
    final want = TtsService.normalizedVoiceFolderName(voiceKey);
    final direct = Directory(p.join(cache.path, want));
    if (await direct.exists()) return direct;
    try {
      await for (final e in cache.list(followLinks: false)) {
        if (e is! Directory) continue;
        if (p.basename(e.path).toLowerCase() == want) {
          return Directory(e.path);
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Listing ──────────────────────────────────────────────────────────

  /// Fetch voices from backend, optionally filtered by language family.
  /// Response is paginated: `{ voices: [...], total, limit, offset }`.
  Future<List<PiperVoice>> listVoices({String? langFamily}) async {
    final query = <String, String>{};
    if (langFamily != null && langFamily.isNotEmpty) {
      query['lang_family'] = langFamily;
    }

    final allVoices = <PiperVoice>[];
    var offset = 0;
    const limit = 80;

    while (true) {
      query['limit'] = '$limit';
      query['offset'] = '$offset';

      final uri = VaultBackendConfig.uri('/piper/voices', query);
      final response = await _dio.getUri<dynamic>(uri);
      final data = response.data;
      if (data is! Map) {
        throw StateError('Resposta inesperada do servidor de vozes.');
      }

      final wrap = data as Map<String, dynamic>;
      final voicesList = wrap['voices'] as List<dynamic>? ?? [];
      final total = (wrap['total'] as num?)?.toInt() ?? voicesList.length;

      for (final item in voicesList) {
        try {
          allVoices.add(PiperVoice.fromJson(item as Map<String, dynamic>));
        } catch (e) {
          debugPrint('PiperVoiceService: skip voice: $e');
        }
      }

      offset += voicesList.length;
      if (offset >= total || voicesList.isEmpty) break;
    }

    allVoices.sort((a, b) => a.key.compareTo(b.key));
    return allVoices;
  }

  // ── Download ─────────────────────────────────────────────────────────

  /// Download all files for [voice] to local cache.
  /// Downloads .onnx and .onnx.json in parallel with combined progress.
  Future<void> downloadVoice(PiperVoice voice) async {
    final cache = await _ensureCacheDir();
    final voiceDir = await _voiceInstallDirectoryForWrite(cache, voice.key);

    final cancelToken = CancelToken();
    _activeCancels[voice.key] = cancelToken;

    final paths = voice.downloadPaths;
    if (paths.isEmpty) {
      throw StateError('Voz "${voice.key}" não possui ficheiros para baixar.');
    }

    final fileSizes = List<int>.filled(paths.length, 0);
    final fileReceived = List<int>.filled(paths.length, 0);

    void emitCombinedProgress() {
      final total = fileSizes.fold<int>(0, (a, b) => a + b);
      final recv = fileReceived.fold<int>(0, (a, b) => a + b);
      _progressMap[voice.key] = VoiceDownloadProgress(
        received: recv,
        total: total,
        status: VoiceDownloadStatus.downloading,
      );
      _progressController.add(Map.of(_progressMap));
    }

    _progressMap[voice.key] = const VoiceDownloadProgress(
      status: VoiceDownloadStatus.downloading,
    );
    _progressController.add(Map.of(_progressMap));

    try {
      await Future.wait(
        paths.indexed.map((indexed) {
          final (i, filePath) = indexed;
          return _downloadSingleFile(
            voiceKey: voice.key,
            remotePath: filePath,
            destDir: voiceDir,
            cancelToken: cancelToken,
            onProgress: (received, total) {
              fileSizes[i] = total;
              fileReceived[i] = received;
              emitCombinedProgress();
            },
          );
        }),
      );

      _progressMap[voice.key] = VoiceDownloadProgress(
        received: fileSizes.fold(0, (a, b) => a + b),
        total: fileSizes.fold(0, (a, b) => a + b),
        status: VoiceDownloadStatus.downloaded,
      );
      _progressController.add(Map.of(_progressMap));
    } catch (e) {
      _progressMap.remove(voice.key);
      _progressController.add(Map.of(_progressMap));

      if (cancelToken.isCancelled) {
        try {
          if (await voiceDir.exists()) await voiceDir.delete(recursive: true);
        } catch (_) {}
        return;
      }

      try {
        if (await voiceDir.exists()) await voiceDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      _activeCancels.remove(voice.key);
    }
  }

  Future<void> _downloadSingleFile({
    required String voiceKey,
    required String remotePath,
    required Directory destDir,
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
  }) async {
    final encodedKey = Uri.encodeComponent(voiceKey);
    // Backend: `GET /v1/piper/voices/{key}/file` (alias histórico: `/download`).
    final uri = VaultBackendConfig.uri(
      '/piper/voices/$encodedKey/file',
      {'path': remotePath},
    );

    final fileName = p.basename(remotePath);
    final destFile = File(p.join(destDir.path, fileName));
    final tmpFile = File('${destFile.path}.tmp');

    try {
      await _dio.downloadUri(
        uri,
        tmpFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );

      await tmpFile.rename(destFile.path);
    } catch (e) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Cancel an in-flight download.
  void cancelDownload(String voiceKey) {
    _activeCancels[voiceKey]?.cancel('Cancelado pelo utilizador');
    _progressMap.remove(voiceKey);
    _progressController.add(Map.of(_progressMap));
  }

  // ── Local voice management ──────────────────────────────────────────

  /// Check if a voice is fully downloaded (has .onnx + .onnx.json).
  Future<bool> isVoiceDownloaded(String voiceKey) async {
    final cache = await _ensureCacheDir();
    final voiceDir = await _locateInstalledVoiceDirectory(cache, voiceKey);
    if (voiceDir == null || !await voiceDir.exists()) return false;
    var hasOnnx = false;
    var hasJson = false;
    try {
      await for (final e in voiceDir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = p.basename(e.path).toLowerCase();
        if (name.endsWith('.onnx') && !name.endsWith('.onnx.json')) {
          hasOnnx = true;
        }
        if (name.endsWith('.onnx.json')) hasJson = true;
      }
    } catch (_) {}
    return hasOnnx && hasJson;
  }

  static const _ignoreDirs = {
    'espeak-ng-data', 'Faber', 'cadu', 'faber',
  };

  /// List all voice keys that are available (bundled + downloaded).
  Future<Set<String>> downloadedVoiceKeys() async {
    final result = <String>{};
    result.addAll(TtsService.bundledVoiceKeys);

    final cache = await _ensureCacheDir();
    try {
      await for (final entity in cache.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final rawName = p.basename(entity.path);
        final normKey = rawName.toLowerCase();
        if (_ignoreDirs.contains(rawName)) continue;
        if (result.contains(normKey)) continue;
        if (await isVoiceDownloaded(normKey)) result.add(normKey);
      }
    } catch (_) {}
    return result;
  }

  /// Delete a downloaded voice from disk.
  Future<void> deleteVoice(String voiceKey) async {
    final cache = await _ensureCacheDir();
    final voiceDir = await _locateInstalledVoiceDirectory(cache, voiceKey);
    if (voiceDir != null && await voiceDir.exists()) {
      await voiceDir.delete(recursive: true);
    }
    _progressMap.remove(voiceKey);
    _progressController.add(Map.of(_progressMap));
  }
}
