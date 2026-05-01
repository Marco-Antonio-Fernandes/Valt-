import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart';

/// Isolate com um único [OfflineTts] — síntese não bloqueia o isolate principal
/// (event loop da UI). Pedidos são tratados em sequência (filamento interno `await for`).
@pragma('vm:entry-point')
void sherpaTtsWorkerMain(List<Object?> args) async {
  /// Obrigatório em *cada* isolate que use Sherpa — no `main.dart` só corre no
  /// isolate da UI; sem isto o carregamento FFI/native falha (crash / stack confuso).
  initBindings();

  final replyToMain = args[0] as SendPort;
  final init = Map<String, dynamic>.from(args[1] as Map);

  final rp = ReceivePort();
  replyToMain.send(rp.sendPort);

  final vits = OfflineTtsVitsModelConfig(
    model: init['onnx'] as String,
    tokens: init['tokens'] as String,
    dataDir: init['dataDir'] as String,
    noiseScale: (init['noiseScale'] as num).toDouble(),
    noiseScaleW: (init['noiseScaleW'] as num).toDouble(),
    lengthScale: (init['lengthScale'] as num).toDouble(),
  );
  final modelCfg = OfflineTtsModelConfig(
    vits: vits,
    numThreads: (init['numThreads'] as num).toInt(),
    // Evitar `kDebugMode` do Flutter neste isolate — importar `foundation`
    // no worker quebra o debug do Flutter; Sherpa em debug nativo é mais lento.
    debug: false,
    provider: 'cpu',
  );
  final tts = OfflineTts(OfflineTtsConfig(model: modelCfg));

  await for (final dynamic raw in rp) {
    final msg = Map<String, dynamic>.from(raw as Map);
    final op = msg['op'] as String;
    if (op == 'shutdown') {
      break;
    }
    if (op != 'gen') continue;

    final id = msg['id'] as int;
    try {
      final text = msg['text'] as String;
      final outPath = msg['outPath'] as String;
      if (text.trim().isEmpty) {
        replyToMain.send(
          {'id': id, 'ok': false, 'error': 'texto vazio'},
        );
        continue;
      }
      final wav = tts.generate(text: text, sid: 0, speed: 1.0);
      if (wav.samples.isEmpty || wav.sampleRate <= 0) {
        replyToMain.send(
          {'id': id, 'ok': false, 'error': 'TTS não gerou áudio.'},
        );
        continue;
      }
      writeWave(
        filename: outPath,
        samples: wav.samples,
        sampleRate: wav.sampleRate,
      );
      replyToMain.send({'id': id, 'ok': true, 'path': outPath});
    } catch (e) {
      replyToMain.send({'id': id, 'ok': false, 'error': e.toString()});
    }
  }

  tts.free();
  rp.close();
}
