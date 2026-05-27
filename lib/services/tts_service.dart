import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sherpa_tts_isolate.dart';
import 'vault_reading_audio.dart';

/// Nova pasta quando os ficheiros em cache ficam estragadas (ex.: cópias
/// incompletas) — faz com que todos os ONNX/tokens/etc. voltem a ser escritos.
/// Bump quando mudar formato da cache (ex.: normalização CRLF nos `.txt`).
const String _ttsCacheDirName = 'vault_sherpa_tts_v12';

/// Vozes pt_BR bundled no APK (assets/tts/pt_BR/…).
/// Chave = voice_key normalizado, valor = prefixo no asset bundle.
const Map<String, String> _bundledPtBrVoices = {
  'pt_br-cadu-medium': 'assets/tts/pt_BR/cadu/medium/',
  'pt_br-edresson-low': 'assets/tts/pt_BR/edresson/low/',
  'pt_br-faber-medium': 'assets/tts/pt_BR/faber/medium/',
  'pt_br-jeff-medium': 'assets/tts/pt_BR/jeff/medium/',
};

/// Síntese interrompida por scrub/pausa — não é erro fatal da leitura.
class TtsSynthesisCancelled implements Exception {
  const TtsSynthesisCancelled();
}

/// Vozes Piper: pt_BR bundled no APK + outras descarregadas do servidor.
/// Cada pasta em `vault_sherpa_tts_v12/{voice_key}/` contém `.onnx` + `.onnx.json`;
/// tokens gerados automaticamente a partir do `phoneme_id_map`.
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  String? _workerLoadedModel;
  Directory? _cacheDir;

  int _ttsGenSpeakerId = 0;

  Future<void>? _bundlesCopied;
  AudioPlayer? _fallbackPlayer;
  StreamSubscription<PlayerState>? _fallbackStateSub;
  Completer<void>? _fallbackPlaybackDone;

  Isolate? _ttsIsolate;
  ReceivePort? _ttsMainReceive;
  StreamSubscription<Object?>? _ttsReplySub;
  SendPort? _ttsWorkerSend;
  var _ttsReqId = 0;
  final Map<int, Completer<String>> _ttsPending = {};

  String? get currentModel => _workerLoadedModel;

  /// Chave única das pastas em `vault_sherpa_tts_v12/` — prefs Sherpa sempre em minúsculas;
  /// o downloader deve usar o mesmo nome para coincidir com Android (FS case-sensitive).
  static String normalizedVoiceFolderName(String modelName) =>
      modelName.toLowerCase().trim();

  Future<void> ensureBundlesAndInit(String modelName) async {
    await initTts(modelName);
  }

  void dispose() {
    _fallbackStateSub?.cancel();
    _fallbackStateSub = null;
    _finalizeFallbackPlaybackCompleter();
    final pl = _fallbackPlayer;
    _fallbackPlayer = null;
    if (pl != null) {
      unawaited(pl.dispose());
    }
    if (VaultReadingAudio.isReady) {
      unawaited(VaultReadingAudio.handler?.interruptPlayback());
    }
    _shutdownTtsWorker();
  }

  void _shutdownTtsWorker() {
    _ttsReplySub?.cancel();
    _ttsReplySub = null;
    final send = _ttsWorkerSend;
    _ttsWorkerSend = null;
    if (send != null) {
      try {
        send.send(<String, Object?>{'op': 'shutdown'});
      } catch (_) {}
    }
    _ttsIsolate?.kill(priority: Isolate.immediate);
    _ttsIsolate = null;
    _ttsMainReceive?.close();
    _ttsMainReceive = null;
    for (final c in _ttsPending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('TTS offline encerrado'));
      }
    }
    _ttsPending.clear();
    _workerLoadedModel = null;
  }

  void _onWorkerReply(Object? msg) {
    if (msg is! Map) return;
    final m = Map<String, Object?>.from(msg);
    final id = m['id'] as int?;
    if (id == null) return;
    final c = _ttsPending.remove(id);
    if (c == null) return;
    if (m['ok'] == true) {
      c.complete(m['path']! as String);
    } else {
      c.completeError(StateError(m['error']?.toString() ?? 'erro TTS'));
    }
  }

  /// Resolve ONNX + JSON + tokens para qualquer bundle Piper (Cadu ou voz baixada).
  /// Se `tokens.txt` não existir mas o `.onnx.json` contiver `phoneme_id_map`,
  /// gera automaticamente o ficheiro — modelos Piper modernos não distribuem
  /// tokens separados.
  Future<
      ({
        String onnx,
        String jsonMeta,
        String tokens,
      })> _resolvePiperBundle(Directory bundle, {String label = 'Voz'}) async {
    if (!await bundle.exists()) {
      throw StateError(
        '$label: pasta não existe (${bundle.path}).',
      );
    }

    Future<String?> pickOnnx() async {
      final onx = <String>[];
      try {
        await for (final e in bundle.list(followLinks: false)) {
          if (e is! File) continue;
          if (!e.path.toLowerCase().endsWith('.onnx')) continue;
          onx.add(e.path);
        }
      } catch (_) {}
      onx.sort();
      return onx.isEmpty ? null : onx.first;
    }

    Future<String?> pickTokens() async {
      try {
        await for (final e in bundle.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path).toLowerCase();
          if (name.startsWith('tokens') && name.endsWith('.txt')) return e.path;
        }
      } catch (_) {}
      return null;
    }

    final onnx = await pickOnnx();
    if (onnx == null) {
      throw StateError(
        '$label: falta *.onnx na pasta (${bundle.path}).',
      );
    }

    final stemOnnx =
        onnx.replaceFirst(RegExp(r'\.onnx$', caseSensitive: false), '');
    final siblingJson = '$stemOnnx.onnx.json';
    if (!await File(siblingJson).exists()) {
      throw StateError(
        '$label: falta metadados (${p.basename(siblingJson)}).',
      );
    }

    final tokens = await pickTokens() ??
        await _generateTokensFromJson(siblingJson, bundle.path, label);

    return (onnx: onnx, jsonMeta: siblingJson, tokens: tokens);
  }

  /// Pasta com `.onnx`: tenta `normalizedFolderName`, depois fallback **só por mudança maiúsculas**
  /// (downloads antigos criavam `pt_PT-…` enquanto prefs usam `pt_pt-…` no Android).
  Future<Directory> _resolveVoiceOnnxInstallDir({
    required Directory directory,
    required String normalizedFolderName,
  }) async {
    final direct = Directory(p.join(directory.path, normalizedFolderName));
    if (await direct.exists()) return direct;
    try {
      await for (final e in directory.list(followLinks: false)) {
        if (e is! Directory) continue;
        final bn = p.basename(e.path);
        if (bn.toLowerCase() != normalizedFolderName) continue;
        final found = Directory(e.path);
        if (bn != normalizedFolderName) {
          try {
            await found.rename(direct.path);
            if (await direct.exists()) return direct;
          } catch (_) {
            /* usar pasta legacy se rename falhar (ex.: cross-device) */
          }
        }
        return found;
      }
    } catch (_) {}
    return direct;
  }

  /// Gera `tokens.txt` a partir do `phoneme_id_map` no `.onnx.json`.
  Future<String> _generateTokensFromJson(
      String jsonPath, String outputDir, String label) async {
    final jf = File(jsonPath);
    final Map<String, dynamic> wrap;
    try {
      wrap = json.decode(await jf.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      throw StateError('$label: não foi possível ler $jsonPath ($e).');
    }

    final pm = wrap['phoneme_id_map'] as Map<String, dynamic>?;
    if (pm == null || pm.isEmpty) {
      throw StateError(
        '$label: .onnx.json não contém phoneme_id_map — impossível gerar tokens.',
      );
    }

    final entries = <(int, String)>[];
    for (final entry in pm.entries) {
      final ids = entry.value;
      if (ids is List && ids.isNotEmpty) {
        entries.add(((ids.first as num).toInt(), entry.key));
      }
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));

    final buf = StringBuffer();
    for (final (id, sym) in entries) {
      buf.writeln('$sym $id');
    }

    final outPath = p.join(outputDir, 'tokens.txt');
    await File(outPath).writeAsString(buf.toString());
    return outPath;
  }

  Future<void> initTts(String modelName) async {
    if (kIsWeb) {
      throw StateError('Sherpa ONNX não está disponível na web.');
    }

    final normalized = normalizedVoiceFolderName(modelName);
    await _ensureEspeakCopied();

    if (_bundledPtBrVoices.containsKey(normalized)) {
      await _copyBundledVoiceIfMissing(normalized);
    }

    final base = _cacheDir!;

    final cores = Platform.numberOfProcessors;
    final threads =
        min(3, cores <= 2 ? 1 : (cores <= 5 ? 2 : 3));

    late final Map<String, Object?> initMap;

    final voiceDir =
        await _resolveVoiceOnnxInstallDir(directory: base, normalizedFolderName: normalized);
    final resolved = await _resolvePiperBundle(
      voiceDir,
      label: normalized,
    );
    final onnxPath = resolved.onnx;
    final tokensPath = resolved.tokens;
    final jsonPath = resolved.jsonMeta;

    final dataDirPath = p.join(base.path, 'espeak-ng-data');

    await _failIfMissingFile(onnxPath, '$normalized: falta ficheiro ONNX.');
    await _failIfMissingFile(tokensPath, '$normalized: falta tokens.');
    _validateSherpaStyleTokens(tokensPath);

    final phonPath = p.join(dataDirPath, 'phondata');
    if (!await File(phonPath).exists()) {
      throw StateError(
        'Copie para assets/tts/espeak-ng-data/ a pasta completa espeak-ng-data '
        '(phondata, phonindex, …).',
      );
    }

    _ttsGenSpeakerId = 0;

    if (_workerLoadedModel == normalized && _ttsWorkerSend != null) {
      return;
    }

    var noiseScale = 0.667;
    var noiseScaleW = 0.8;
    var lengthScale = 1.0;
    try {
      final jf = File(jsonPath);
      if (await jf.exists()) {
        final wrap =
            json.decode(await jf.readAsString()) as Map<String, dynamic>;
        final inf = wrap['inference'] as Map<String, dynamic>? ?? const {};
        noiseScale =
            (inf['noise_scale'] as num?)?.toDouble() ?? noiseScale;
        noiseScaleW = (inf['noise_w'] as num?)?.toDouble() ?? noiseScaleW;
        lengthScale =
            (inf['length_scale'] as num?)?.toDouble() ?? lengthScale;
      }
    } catch (_) {
      /* metadados opcionais */
    }

    initMap = <String, Object?>{
      'kind': 'vits',
      'onnx': onnxPath,
      'tokens': tokensPath,
      'dataDir': dataDirPath,
      'noiseScale': noiseScale,
      'noiseScaleW': noiseScaleW,
      'lengthScale': lengthScale,
      'numThreads': threads,
    };

    _shutdownTtsWorker();

    final mainRp = ReceivePort();
    _ttsMainReceive = mainRp;

    final boot = Completer<SendPort>();
    late StreamSubscription<Object?> sub;
    sub = mainRp.listen((Object? msg) {
      if (msg is SendPort && !boot.isCompleted) {
        boot.complete(msg);
        return;
      }
      _onWorkerReply(msg);
    });

    try {
      final isolate = await Isolate.spawn(
        sherpaTtsWorkerMain,
        [mainRp.sendPort, initMap],
        debugName: 'vault_sherpa_tts',
      );

      _ttsIsolate = isolate;
      _ttsReplySub = sub;
      _ttsWorkerSend = await boot.future;
      _workerLoadedModel = normalized;
    } catch (e) {
      await sub.cancel();
      mainRp.close();
      _ttsMainReceive = null;
      _ttsReplySub = null;
      _ttsIsolate = null;
      rethrow;
    }
  }

  double _outputVolume = 1.0;

  Future<void> setOutputVolume(double v) async {
    _outputVolume = v.clamp(0.0, 1.0);
    await VaultReadingAudio.handler?.setOutputVolume(_outputVolume);
    await _fallbackPlayer?.setVolume(_outputVolume);
  }

  Future<void> speak(
    String text, {
    double volume = -1,
    String? mediaTitle,
    String? mediaAlbum,
    Uri? mediaArtUri,
  }) async {
    if (text.trim().isEmpty) return;
    if (volume >= 0) {
      _outputVolume = volume.clamp(0.0, 1.0);
    }

    await _stopPlaybackPipeline();

    final path = await prepareWavForText(text);
    await playPreparedWav(
      path,
      volume: volume,
      mediaTitle: mediaTitle,
      mediaAlbum: mediaAlbum,
      mediaArtUri: mediaArtUri,
    );
  }

  /// Cancela pedidos em fila e reinicia o isolate — evita CPU presa após scrub/pausa.
  Future<void> cancelPendingSynthesis() async {
    if (kIsWeb) return;
    for (final c in _ttsPending.values) {
      if (!c.isCompleted) {
        c.completeError(const TtsSynthesisCancelled());
      }
    }
    _ttsPending.clear();
    final model = _workerLoadedModel;
    if (model == null || _ttsWorkerSend == null) return;
    _shutdownTtsWorker();
    await initTts(model);
  }

  /// Gera WAV sem interromper o áudio atual — corre num isolate (não trava a UI).
  Future<String> prepareWavForText(String text) async {
    if (kIsWeb) {
      throw StateError('Sherpa ONNX não está disponível na web.');
    }
    var worker = _ttsWorkerSend;
    if (worker == null) {
      throw StateError('TtsService.initTts antes de speak');
    }
    if (text.trim().isEmpty) {
      throw StateError('texto vazio');
    }

    final id = ++_ttsReqId;
    final root = await getTemporaryDirectory();
    final out = File(
      p.join(
        root.path,
        'vault_tts_${id}_${DateTime.now().microsecondsSinceEpoch}.wav',
      ),
    );
    final c = Completer<String>();
    _ttsPending[id] = c;
    worker.send(<String, Object?>{
      'op': 'gen',
      'id': id,
      'text': text,
      'outPath': out.path,
      'sid': _ttsGenSpeakerId,
      'speed': 1.0,
    });
    return c.future;
  }

  /// Reproduz um WAV já gerado (e apaga o ficheiro no fim). Interrompe o segmento anterior.
  Future<void> playPreparedWav(
    String path, {
    double volume = -1,
    double playbackSpeed = 1.0,
    String? mediaTitle,
    String? mediaAlbum,
    Uri? mediaArtUri,
  }) async {
    if (!await File(path).exists()) {
      throw StateError('WAV em falta: $path');
    }
    if (volume >= 0) {
      _outputVolume = volume.clamp(0.0, 1.0);
    }

    try {
      if (VaultReadingAudio.isReady && VaultReadingAudio.handler != null) {
        await VaultReadingAudio.handler!.playVaultChunk(
          path: path,
          title: mediaTitle ?? 'Leitura',
          album: mediaAlbum ?? 'Vault',
          volume: _outputVolume,
          playbackSpeed: playbackSpeed,
          artUri: mediaArtUri,
        );
      } else {
        await _speakWithFallbackPlayer(path);
      }
    } finally {
      try {
        if (await File(path).exists()) {
          await File(path).delete();
        }
      } catch (_) {}
    }
  }

  void _finalizeFallbackPlaybackCompleter() {
    final c = _fallbackPlaybackDone;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _fallbackPlaybackDone = null;
  }

  Future<void> _speakWithFallbackPlayer(String path) async {
    _fallbackStateSub?.cancel();
    _fallbackStateSub = null;
    final old = _fallbackPlayer;
    _fallbackPlayer = null;
    _finalizeFallbackPlaybackCompleter();
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }

    final player = AudioPlayer();
    _fallbackPlayer = player;
    await player.setVolume(_outputVolume);

    final done = Completer<void>();
    _fallbackPlaybackDone = done;
    _fallbackStateSub = player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _fallbackStateSub?.cancel();
        _fallbackStateSub = null;
        _finalizeFallbackPlaybackCompleter();
      }
    });

    await player.setFilePath(path);
    await player.play();
    await done.future;
    _fallbackStateSub?.cancel();
    _fallbackStateSub = null;
    _fallbackPlayer = null;
    await player.dispose();
  }

  Future<void> _stopPlaybackPipeline() async {
    if (VaultReadingAudio.isReady) {
      await VaultReadingAudio.handler?.interruptPlayback();
    }
    _fallbackStateSub?.cancel();
    _fallbackStateSub = null;
    final old = _fallbackPlayer;
    _fallbackPlayer = null;
    _finalizeFallbackPlaybackCompleter();
    if (old != null) {
      try {
        await old.stop();
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _stopPlaybackPipeline();
  }

  /// Pausa só o WAV/canal de leitura (não cancela síntese nem isolate).
  Future<void> pauseReadingPlayback() async {
    final h = VaultReadingAudio.handler;
    if (VaultReadingAudio.isReady && h != null) {
      await h.pause();
      return;
    }
    final pl = _fallbackPlayer;
    if (pl != null) await pl.pause();
  }

  /// Retoma reprodução pausada por [pauseReadingPlayback].
  Future<void> resumeReadingPlayback() async {
    final h = VaultReadingAudio.handler;
    if (VaultReadingAudio.isReady && h != null) {
      await h.play();
      return;
    }
    final pl = _fallbackPlayer;
    if (pl != null) await pl.play();
  }

  /// Lista de voice_keys pt_BR que já vêm bundled no APK.
  static List<String> get bundledVoiceKeys =>
      _bundledPtBrVoices.keys.toList(growable: false);

  /// Copia .onnx + .onnx.json de um voice bundled para cache, se ainda não existir.
  Future<void> _copyBundledVoiceIfMissing(String voiceKey) async {
    final base = _cacheDir;
    if (base == null) return;
    final assetPrefix = _bundledPtBrVoices[voiceKey];
    if (assetPrefix == null) return;

    final destDir = Directory(p.join(base.path, voiceKey));
    if (await destDir.exists()) {
      var hasOnnx = false;
      await for (final e in destDir.list(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.onnx')) {
          hasOnnx = true;
          break;
        }
      }
      if (hasOnnx) return;
    }
    await destDir.create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final key in manifest.listAssets()) {
      if (!key.startsWith(assetPrefix)) continue;
      final fileName = key.substring(assetPrefix.length);
      if (fileName.contains('/')) continue;
      if (!fileName.endsWith('.onnx') && !fileName.endsWith('.onnx.json')) {
        continue;
      }
      final dest = File(p.join(destDir.path, fileName));
      if (await dest.exists()) continue;
      final bytes = await rootBundle.load(key);
      await dest.writeAsBytes(bytes.buffer.asUint8List());
    }
  }

  /// Copia apenas espeak-ng-data do bundle de assets para cache local.
  Future<void> _ensureEspeakCopied() async {
    if (_bundlesCopied != null) {
      await _bundlesCopied!;
      return;
    }
    _bundlesCopied = _copyEspeakAssetsOnce();
    await _bundlesCopied!;
  }

  Future<void> _copyEspeakAssetsOnce() async {
    final doc = await getApplicationDocumentsDirectory();

    for (final legacyName in [
      'vault_sherpa_tts',
      'vault_sherpa_tts_v2',
      'vault_sherpa_tts_v3',
      'vault_sherpa_tts_v4',
      'vault_sherpa_tts_v5',
      'vault_sherpa_tts_v6',
      'vault_sherpa_tts_v7',
      'vault_sherpa_tts_v8',
      'vault_sherpa_tts_v9',
      'vault_sherpa_tts_v10',
      'vault_sherpa_tts_v11',
    ]) {
      try {
        final d = Directory(p.join(doc.path, legacyName));
        if (await d.exists()) {
          await d.delete(recursive: true);
        }
      } catch (_) {}
    }

    _cacheDir = Directory(p.join(doc.path, _ttsCacheDirName));
    await _cacheDir!.create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    const prefix = 'assets/tts/';
    for (final key in manifest.listAssets()) {
      if (!key.startsWith(prefix)) continue;
      final rel = key.substring(prefix.length);
      if (!rel.startsWith('espeak-ng-data/')) continue;
      final dest = File(p.join(_cacheDir!.path, rel));
      if (await dest.exists()) continue;
      await dest.parent.create(recursive: true);
      final bytes = await rootBundle.load(key);
      final raw = bytes.buffer.asUint8List();
      if (rel.endsWith('.txt')) {
        var s = utf8.decode(raw, allowMalformed: false);
        if (s.startsWith('\uFEFF')) s = s.substring(1);
        s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        await dest.writeAsString(s, flush: true);
      } else {
        await dest.writeAsBytes(raw);
      }
    }
  }

  Future<void> _failIfMissingFile(String absolute, String hint) async {
    if (!await File(absolute).exists()) {
      throw StateError('$hint — esperado: $absolute');
    }
  }
}

/// Espelho da lógica de `piper-phonemize-lexicon.cc` → `ReadTokens` (Sherpa‑ONNX),
/// só para apanhar antes ficheiros de tokens ilegíveis / duplicados e evitar
/// `SHERPA_ONNX_EXIT` no lado nativo.
void _validateSherpaStyleTokens(String absoluteTokensPath) {
  final raw = utf8.decode(
    File(absoluteTokensPath).readAsBytesSync(),
    allowMalformed: false,
  );
  var text = raw;
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }

  /// Linha apenas com dígito(s) ⇒ `sym = espaço`, `id` = número (`iss.eof()`
  /// tal como em C++ para ` Piper ` vocab).
  final onlyAsciiId =
      RegExp(r'^[ \t]*([-]?\d+)\s*$');

  /// Primeiro símbolo (sem espaços) + segundo token numérico até ao fim.
  final glyphAndId = RegExp(r'^[ \t]*(\S+)[ \t]+([-]?\d+)\s*$');

  final charToId = <int, ({int existingId, String linePreview})>{};

  /// Caso especial Coqui (Sherpa ignore): `<BLNK>`.
  bool skippedBlanks(String sym) {
    final u = sym.runes.toList();
    return u.length == 6 &&
        u[0] == 0x3C &&
        u[1] == 0x42 &&
        u[2] == 0x4C &&
        u[3] == 0x4E &&
        u[4] == 0x4B &&
        u[5] == 0x3E;
  }

  final lines = const LineSplitter().convert(text);

  var lineIdx = 0;
  for (final line in lines) {
    lineIdx++;
    final lineNorm = line.replaceAll(RegExp(r'\r$'), '');
    if (lineNorm.trimLeft().isEmpty) {
      continue;
    }

    final int unicodeScalar;
    final int id;
    late final String linePreviewLabel;

    final lone = onlyAsciiId.firstMatch(lineNorm);
    if (lone != null) {
      // Igual ao Sherpa `iss >> sym`, `eof` ⇒ `sym=" "` + `atoi`.
      unicodeScalar = 0x20; // U+0020 espaço Piper
      id = int.parse(lone.group(1)!);
      linePreviewLabel = '(espaço) ← linha só com id';
    } else {
      final two = glyphAndId.firstMatch(lineNorm);
      if (two == null) {
        throw StateError(
          'Formato tokens inválido (linha $lineIdx): “$lineNorm” — '
          'esperado apenas dígitos (“  3 ” → espaço) ou “ símbolo id ”.',
        );
      }
      final glyph = two.group(1)!;
      id = int.parse(two.group(2)!);
      linePreviewLabel = glyph;

      if (skippedBlanks(glyph)) {
        continue;
      }

      final gRunes = glyph.runes.toList();
      if (gRunes.length != 1) {
        throw StateError(
          'Símbolo inválido no tokens (linha $lineIdx): esperado 1 ponto código, '
          'recebido glyph “$glyph”.',
        );
      }
      unicodeScalar = gRunes.single;
    }

    final prev = charToId[unicodeScalar];
    if (prev != null) {
      throw StateError(
        'tokens.txt duplica o mesmo carácter (codepoint $unicodeScalar). '
        'Primeiro id=${prev.existingId}, segundo id=$id perto das linhas com '
        '«${prev.linePreview}» e «${lineNorm.trimRight()}». '
        'Apague a pasta Sherpa nos documentos da app ou reinstale '
        '(nome atual em lib/services/tts_service.dart: $_ttsCacheDirName).',
      );
    }
    charToId[unicodeScalar] = (
      existingId: id,
      linePreview: '$linePreviewLabel (${lineNorm.trimRight()})',
    );
  }
}
