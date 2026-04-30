import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';

/// Áudio da leitura Sherpa + notificação / controlos de media (Android/iOS).
class VaultReadingAudio {
  VaultReadingAudio._();

  static VaultReadingAudioHandler? _handler;
  static final _systemStopCtrl = StreamController<void>.broadcast();

  /// UI deve subscrever para reagir a “parar” na notificação ou no comando do sistema.
  static Stream<void> get systemStopRequests => _systemStopCtrl.stream;

  static VaultReadingAudioHandler? get handler => _handler;

  static bool get isReady => _handler != null;

  static Future<void> init() async {
    if (kIsWeb || _handler != null) return;
    await AudioService.init(
      builder: () {
        _handler = VaultReadingAudioHandler(_systemStopCtrl);
        return _handler!;
      },
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.hqreader.vault.reading',
        androidNotificationChannelName: 'Leitura em voz alta',
        // Entre chunks o player fica idle; sem isto o Android remove o FGS de media e o SO
        // pode suspender o isolate durante síntese Sherpa com ecrã bloqueado.
        androidStopForegroundOnPause: false,
        androidShowNotificationBadge: false,
      ),
    );

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.duckOthers,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ));
  }
}

class VaultReadingAudioHandler extends BaseAudioHandler with SeekHandler {
  VaultReadingAudioHandler(this._systemStopCtrl) {
    _player.playbackEventStream.listen(_broadcastPlayback);
  }

  final StreamController<void> _systemStopCtrl;
  final _player = AudioPlayer();
  Completer<void>? _chunkDone;

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.stop,
      },
      androidCompactActionIndices: const [0, 1],
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }

  void _broadcastPlayback(PlaybackEvent event) {
    playbackState.add(_transformEvent(event));
    if (_player.processingState == ProcessingState.completed) {
      final c = _chunkDone;
      if (c != null && !c.isCompleted) {
        c.complete();
      }
      _chunkDone = null;
    }
  }

  /// Interrompe o segmento atual (troca de chunk ou stop na UI).
  Future<void> interruptPlayback() async {
    final c = _chunkDone;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _chunkDone = null;
    await _player.stop();
  }

  /// Um ficheiro WAV gerado por Sherpa; bloqueia até ao fim do segmento ou [interruptPlayback].
  Future<void> playVaultChunk({
    required String path,
    required String title,
    required String album,
    double volume = 1.0,
    Uri? artUri,
  }) async {
    await interruptPlayback();

    final chunkDone = Completer<void>();
    _chunkDone = chunkDone;

    mediaItem.add(
      MediaItem(
        id: path,
        album: album,
        title: title,
        artist: 'Vault',
        artUri: artUri,
      ),
    );

    await _player.setLoopMode(LoopMode.off);
    await _player.setFilePath(path);
    await _player.setVolume(volume.clamp(0.0, 1.0));
    await _player.seek(Duration.zero);
    await play();

    try {
      await chunkDone.future;
    } finally {
      if (identical(_chunkDone, chunkDone)) {
        _chunkDone = null;
      }
    }
  }

  Future<void> setOutputVolume(double v) async {
    await _player.setVolume(v.clamp(0.0, 1.0));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    _systemStopCtrl.add(null);
    await interruptPlayback();
    await super.stop();
  }

  Future<void> dispose() async {
    await interruptPlayback();
    await _player.dispose();
  }
}
