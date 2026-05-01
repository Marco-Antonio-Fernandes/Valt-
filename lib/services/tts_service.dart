import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sherpa_tts_isolate.dart';
import 'vault_reading_audio.dart';

/// Nova pasta quando os ficheiros em cache ficam estragados (ex.: cópias
/// incompletas) — faz com que todos os ONNX/tokens/etc. voltem a ser escritos.
/// Bump quando mudar formato da cache (ex.: normalização CRLF nos `.txt`).
const String _ttsCacheDirName = 'vault_sherpa_tts_v5';

/// VITS/Piper offline via Sherpa-ONNX (`miro`, `dii`, `faber`).
///
/// Incluir em `assets/tts/` (e pubspec): `*.onnx`, tokens, `.onnx.json` e
/// `espeak-ng-data/` completa (phonemas PT‑BR — necessária).
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  static final _tokensByModel = <String, String>{
    'miro': 'tokens_miro.txt',
    'dii': 'tokens_dii.txt',
    'faber': 'tokens_faber.txt',
  };

  String? _workerLoadedModel;
  Directory? _cacheDir;

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

  Future<void> ensureBundlesAndInit(String modelName) async {
    await _ensureBundlesCopied();
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



  Future<void> initTts(String modelName) async {
    if (kIsWeb) {
      throw StateError('Sherpa ONNX não está disponível na web.');
    }

    final normalized = modelName.toLowerCase().trim();
    final tokensLeaf = _tokensByModel[normalized];
    if (tokensLeaf == null) {
      throw ArgumentError(
        'modelName: usar miro, dii ou faber (recebido: $modelName)',
      );
    }
    await _ensureBundlesCopied();

    final base = _cacheDir!;
    final onnxPath = p.join(base.path, '$normalized.onnx');
    final tokensPath = p.join(base.path, tokensLeaf);
    final jsonPath = p.join(base.path, '$normalized.onnx.json');
    final dataDirPath = p.join(base.path, 'espeak-ng-data');

    await _failIfMissingFile(
      onnxPath,
      'Falta o ficheiro ONNX (assets/tts/$normalized.onnx)',
    );
    await _failIfMissingFile(tokensPath, 'Falta ficheiro de tokens');
    _validateSherpaStyleTokens(tokensPath);

    final phonPath = p.join(dataDirPath, 'phondata');
    if (!await File(phonPath).exists()) {
      throw StateError(
        'Copie para assets/tts/espeak-ng-data/ a pasta completa espeak-ng-data '
        '(p.ex. modelo Sherpa-Piper pré‑montado precisa dos ficheiros phondata, phonindex, …).',
      );
    }

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
        final inf =
            wrap['inference'] as Map<String, dynamic>? ?? const {};
        noiseScale = (inf['noise_scale'] as num?)?.toDouble() ?? noiseScale;
        noiseScaleW = (inf['noise_w'] as num?)?.toDouble() ?? noiseScaleW;
        lengthScale = (inf['length_scale'] as num?)?.toDouble() ?? lengthScale;
      }
    } catch (_) {
      /* metadados opcionais */
    }

    final threads = (!kIsWeb &&
            (Platform.isAndroid ||
                Platform.isIOS ||
                Platform.isMacOS ||
                Platform.isLinux))
        ? 1
        : 2;

    _shutdownTtsWorker();

    final mainRp = ReceivePort();
    _ttsMainReceive = mainRp;
    final initMap = <String, Object?>{
      'onnx': onnxPath,
      'tokens': tokensPath,
      'dataDir': dataDirPath,
      'noiseScale': noiseScale,
      'noiseScaleW': noiseScaleW,
      'lengthScale': lengthScale,
      'numThreads': threads,
    };

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

  /// Gera WAV sem interromper o áudio atual — corre num isolate (não trava a UI).
  Future<String> prepareWavForText(String text) async {
    if (kIsWeb) {
      throw StateError('Sherpa ONNX não está disponível na web.');
    }
    final worker = _ttsWorkerSend;
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
    });
    return c.future;
  }

  /// Reproduz um WAV já gerado (e apaga o ficheiro no fim). Interrompe o segmento anterior.
  Future<void> playPreparedWav(
    String path, {
    double volume = -1,
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

  Future<void> _ensureBundlesCopied() async {
    if (_bundlesCopied != null) {
      await _bundlesCopied!;
      return;
    }
    _bundlesCopied = Future<void>(() async {
      final doc = await getApplicationDocumentsDirectory();

      /// Caches antigas — libertar espaço após migrações.
      for (final legacyName in [
        'vault_sherpa_tts',
        'vault_sherpa_tts_v2',
        'vault_sherpa_tts_v3',
        'vault_sherpa_tts_v4',
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
        if (!key.startsWith(prefix)) {
          continue;
        }
        final rel = key.substring(prefix.length);
        final dest = File(p.join(_cacheDir!.path, rel));
        await dest.parent.create(recursive: true);
        final bytes = await rootBundle.load(key);
        final raw = bytes.buffer.asUint8List();
        /// Sherpa `ReadTokens` falha com CRLF (`getline` deixa `\r` na linha),
        /// produzindo exit nativo — normalizar texto antes de gravar.
        if (rel.endsWith('.txt')) {
          var s = utf8.decode(raw, allowMalformed: false);
          if (s.startsWith('\uFEFF')) {
            s = s.substring(1);
          }
          s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
          await dest.writeAsString(s, flush: true);
        } else {
          await dest.writeAsBytes(raw);
        }
      }
    });
    await _bundlesCopied!;
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
