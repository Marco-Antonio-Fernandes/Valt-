import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio/just_audio.dart';

/// Ação solicitada pela notificação / centro de média (trechos da leitura, não música).
enum VaultReadingSegmentSkip {
  backward,
  forward,
}

/// Áudio da leitura Sherpa + notificação / controlos de media (Android/iOS).
class VaultReadingAudio {
  VaultReadingAudio._();

  static VaultReadingAudioHandler? _handler;
  static final _systemStopCtrl = StreamController<void>.broadcast();

  static final StreamController<VaultReadingSegmentSkip> _segmentSkipsCtrl =
      StreamController<VaultReadingSegmentSkip>.broadcast();

  /// UI deve subscrever para reagir a “parar” na notificação ou no comando do sistema.
  static Stream<void> get systemStopRequests => _systemStopCtrl.stream;

  /// Próximo / anterior trecho a partir dos controlos compactos na notificação.
  static Stream<VaultReadingSegmentSkip> get segmentSkips =>
      _segmentSkipsCtrl.stream;

  /// Posição atual e duração do WAV atual (Sherpa offline).
  static Stream<(Duration position, Duration? duration)> get wavProgress {
    final h = _handler;
    if (h != null) return h.wavProgress;
    return Stream<(Duration position, Duration? duration)>.empty();
  }

  static VaultReadingAudioHandler? get handler => _handler;

  static bool get isReady => _handler != null;

  /// Enviado de [VaultReadingAudioHandler] para esta stream.
  static void _dispatchSegmentSkip(VaultReadingSegmentSkip s) {
    if (!_segmentSkipsCtrl.isClosed) _segmentSkipsCtrl.add(s);
  }

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
  final AudioPlayer _player = AudioPlayer();

  Completer<void>? _chunkDone;
  StreamSubscription<Duration>? _posTicker;

  final StreamController<(Duration position, Duration? duration)>
      _wavProgressBroadcast =
      StreamController<(Duration position, Duration? duration)>.broadcast();

  Stream<(Duration position, Duration? duration)> get wavProgress =>
      _wavProgressBroadcast.stream;

  DateTime? _lastProgressEmitUi;
  DateTime? _lastProgressEmitSvc;

  void _detachProgressTicker() {
    unawaited(_posTicker?.cancel());
    _posTicker = null;
  }

  void _attachProgressTicker() {
    _detachProgressTicker();
    _posTicker = _player.positionStream.listen((_) {
      _pulseProgress(forceUi: false);
    });
    _pulseProgress(forceUi: true);
  }

  void _pulseProgress({required bool forceUi}) {
    final d = _player.duration;
    final durKnown =
        (d != null && d.inMilliseconds > 0) ? d : null;
    final clampedDur = durKnown ?? Duration.zero;
    Duration pos =
        clampedDur.inMilliseconds > 0
            ? Duration(
              milliseconds:
                  _player.position.inMilliseconds
                      .clamp(0, clampedDur.inMilliseconds),
            )
            : _player.position;
    final now = DateTime.now();

    final uiThrottle =
        !_wavProgressBroadcast.hasListener
            ? 999999
            : (forceUi ? 0 : 180);
    if (_lastProgressEmitUi == null ||
        now.difference(_lastProgressEmitUi!).inMilliseconds >= uiThrottle ||
        forceUi) {
      _lastProgressEmitUi = now;
      if (!_wavProgressBroadcast.isClosed && _wavProgressBroadcast.hasListener) {
        _wavProgressBroadcast.add((pos, durKnown));
      }
    }

    final svcThrottle = 380;
    if (_lastProgressEmitSvc == null ||
        now.difference(_lastProgressEmitSvc!).inMilliseconds >= svcThrottle ||
        forceUi) {
      _lastProgressEmitSvc = now;
      playbackState.add(
        _playbackStateFromPlayer(includePositionBump: true, positionBump: pos),
      );
      if (durKnown != null &&
          durKnown.inMilliseconds > 0 &&
          mediaItem.value != null &&
          mediaItem.value!.duration != durKnown) {
        mediaItem.add(mediaItem.value!.copyWith(duration: durKnown));
      }
    }
  }

  PlaybackState _playbackStateFromPlayer({
    bool includePositionBump = false,
    Duration positionBump = Duration.zero,
  }) {
    Duration pos = positionBump;
    if (!includePositionBump) pos = _player.position;
    Duration total = Duration.zero;
    final mdur = mediaItem.value?.duration;
    final pdur = _player.duration;
    if (mdur != null && mdur.inMilliseconds > 0) {
      total = mdur;
    } else if (pdur != null && pdur.inMilliseconds > 0) {
      total = pdur;
    }
    Duration buf = total.inMilliseconds > 0 ? total : _player.bufferedPosition;
    Duration snapPos =
        total.inMilliseconds > 0
            ? Duration(
              milliseconds:
                  pos.inMilliseconds.clamp(0, total.inMilliseconds),
            )
            : pos;

    final proc = switch (_player.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.stop,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: proc,
      playing: _player.playing,
      updatePosition: snapPos,
      bufferedPosition: buf,
      speed: _player.speed,
    );
  }

  void _broadcastPlayback(PlaybackEvent event) {
    _lastProgressEmitSvc = null;
    playbackState.add(_playbackStateFromPlayer(includePositionBump: false));
    if (_player.processingState == ProcessingState.completed) {
      final c = _chunkDone;
      if (c != null && !c.isCompleted) {
        c.complete();
      }
      _chunkDone = null;
      _detachProgressTicker();
    }
  }

  @override
  Future<void> skipToNext() async {
    VaultReadingAudio._dispatchSegmentSkip(VaultReadingSegmentSkip.forward);
  }

  @override
  Future<void> skipToPrevious() async {
    VaultReadingAudio._dispatchSegmentSkip(VaultReadingSegmentSkip.backward);
  }

  Future<void> interruptPlayback() async {
    final c = _chunkDone;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _chunkDone = null;
    _detachProgressTicker();
    await _player.stop();
    _lastProgressEmitUi = null;
    _lastProgressEmitSvc = null;
  }

  Future<void> playVaultChunk({
    required String path,
    required String title,
    required String album,
    double volume = 1.0,
    double playbackSpeed = 1.0,
    Uri? artUri,
  }) async {
    await interruptPlayback();

    final chunkDone = Completer<void>();
    _chunkDone = chunkDone;

    await _player.setLoopMode(LoopMode.off);
    await _player.setFilePath(path);
    await _player.setVolume(volume.clamp(0.0, 1.0));
    await _player.setSpeed(playbackSpeed.clamp(0.5, 2.0));

    final df = _player.durationFuture;
    Duration? wavDur;
    if (df != null) {
      wavDur = await df;
    }
    final cur = _player.duration;
    if ((wavDur == null || wavDur.inMilliseconds <= 0) &&
        cur != null &&
        cur.inMilliseconds > 0) {
      wavDur = cur;
    }

    mediaItem.add(
      MediaItem(
        id: path,
        album: album,
        title: title,
        artist: 'Vault',
        artUri: artUri,
        duration: wavDur,
      ),
    );

    _attachProgressTicker();

    playbackState.add(_playbackStateFromPlayer(includePositionBump: false));
    await _player.seek(Duration.zero);
    await play();

    try {
      await chunkDone.future;
    } finally {
      if (identical(_chunkDone, chunkDone)) {
        _chunkDone = null;
      }
      _detachProgressTicker();
    }
  }

  Future<void> setOutputVolume(double v) async {
    await _player.setVolume(v.clamp(0.0, 1.0));
  }

  Future<void> setPlaybackSpeed(double s) async {
    await _player.setSpeed(s.clamp(0.5, 2.0));
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
