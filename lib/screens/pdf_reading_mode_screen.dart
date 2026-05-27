import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_theme.dart';
import '../models/library_item.dart';
import '../models/reading_book_annotations.dart';
import '../models/reading_highlight.dart';
import '../models/reading_note.dart';
import '../services/piper_voice_service.dart';
import '../services/reading_notes_store.dart';
import '../services/tts_service.dart' show TtsService, TtsSynthesisCancelled;
import '../services/vault_reading_audio.dart';
import '../widgets/pdf_sticky_notes.dart';
import '../widgets/reading_highlight_color_sheet.dart';
import '../widgets/reading_highlights_paint.dart';
import 'voice_manager_screen.dart';

const _kVoicePrefsKey = 'read_aloud_voice_json';
const _kReadAloudEngine = 'read_aloud_engine';
const _kSherpaOfflineVoice = 'offline_sherpa_voice_id';
const _kReadAloudVolume = 'read_aloud_playback_volume';
const _kSystemSpeechRate = 'read_aloud_system_speech_rate';
const _kWavPlaybackSpeed = 'read_aloud_wav_playback_speed';
const _defaultVoiceLocale = 'pt-BR';
const _readHighlightFill = Color(0x991565C0);
/// Sherpa WAV emite ticks densos — limitar repaint do PDF/evitar setState a cada um.
const _kSherpaPdfProgressMinRedrawMs = 130;
/// Com leitura parada liberta `PdfPageText` longe da página atual (exceto grifos / vizinhas).
const _kStructuredTextCacheNearbyPages = 2;
/// Evita percorrer o PDF página a página ao saltar para o fim (travava a UI).
const _kMaxSequentialQueuePageLoads = 2;
/// Trechos Sherpa menores → saltar no fim da página não gera um WAV gigante.
const _kSherpaTtsChunkMax = 5500;
/// Fila acima disto: reancorar na página alvo em vez de saltar numa fila gigante.
const _kQueueReanchorChunkThreshold = 48;
/// Throttle do thumb da barra de progresso (evita rebuild do PDF a cada pixel).
const _kScrubUiThrottleMs = 56;
/// Avanço/retrocesso dos botões junto ao play/stop.
const _kReadingTimeSkipSeconds = 5;

class PdfReadingModeScreen extends StatefulWidget {
  const PdfReadingModeScreen({
    super.key,
    required this.item,
    this.onPagePersist,
  });

  final LibraryItem item;
  final void Function(int lastPageIndex, {int? totalPages})? onPagePersist;

  @override
  State<PdfReadingModeScreen> createState() => _PdfReadingModeScreenState();
}

class _Chunk {
  const _Chunk(this.page, this.text, this.offsetInPage);

  final int page;
  final String text;
  final int offsetInPage;
}

bool _isLocalePtBr(String? raw) {
  if (raw == null || raw.isEmpty) return false;
  final n = raw.toLowerCase().replaceAll('_', '-').trim();
  return n == 'pt-br' || n.startsWith('pt-br');
}

class _PdfReadingModeScreenState extends State<PdfReadingModeScreen>
    with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  final PdfViewerController _pdfController = PdfViewerController();

  int _currentPage = 1;
  int? _totalPages;
  var _viewerReady = false;
  String? _loadError;
  var _isPlaying = false;
  /// Pausa suave — mantém posição no segmento; [stop] é que reinicia a sessão.
  var _paused = false;
  Completer<void>? _resumeCompleter;

  final List<_Chunk> _queue = [];
  /// Texto por página (índices alinhados com [PdfPageText] para destaque no PDF).
  final Map<int, String> _pageTextFromQueue = {};
  /// Páginas já ingestadas na fila (extensão é incremental ao ler — não todas de uma vez).
  final Set<int> _pagesMaterializedIntoQueue = {};
  final Map<int, PdfPageText> _structuredByPage = {};
  int _chunkIndex = 0;
  /// Invalida pré-cálculo Sherpa em stop/skip — o futuro descarta o WAV órfão.
  int _readingPrefetchGeneration = 0;
  /// Próximo segmento (índice na fila = `_chunkIndex + 1` após consumir o atual).
  Future<String?>? _sherpaNextWav;
  /// Segundo à frente, iniciado quando o primeiro prefetch completa.
  Future<String?>? _sherpaSpareWav;
  int? _sherpaSpareForQueueIndex;
  PdfPageTextRange? _readHighlight;
  /// Evita redesenhar o PDF demasiadas vezes durante o FlutterTts (economiza CPU/GPU).
  DateTime? _lastProgressRedraw;
  /// Idem durante progresso WAV (Sherpa — ticks muito frequentes).
  DateTime? _lastWavHighlightRedraw;

  StreamSubscription<void>? _vaultAudioStopSub;
  StreamSubscription<VaultReadingSegmentSkip>? _vaultSegmentSkipSub;
  StreamSubscription<(Duration position, Duration? duration)>?
      _wavProgressSub;

  var _speechRate = 0.45;
  var _wavPlaybackSpeed = 1.0;
  /// Avanço aproximado na frase atual (motor do sistema) — apenas visual.
  var _flutterWordProgress = 0.0;

  Duration? _wavChunkPos;
  Duration? _wavChunkDur;
  /// Arrastar a barra de progresso (timeline da página inteira, não só o WAV atual).
  var _pageTimelineScrubbing = false;
  var _pageTimelineFraction = 0.0;
  DateTime? _lastScrubUiTick;
  int _scrubCommitToken = 0;

  /// Cache da timeline da página (evita varrer [_queue] a cada tick do WAV).
  int? _cachedTimelinePage;
  List<int>? _cachedTimelineIndices;
  List<int>? _cachedTimelineDurationsMs;
  int _cachedTimelineTotalMs = 0;
  int _cachedTimelineQueueLen = -1;
  int _cachedTimelineChunkIndex = -1;
  int _cachedTimelineWavDurMs = -1;

  var _playbackVolume = 1.0;
  var _pendingBackChunk = false;
  /// Próximo trecho (media / comando) durante TTS sistema — pedido de avançar sem repetir áudio atual.
  var _pendingSkipForwardChunk = false;
  int? _pendingJumpChunk;
  /// Dentro do trecho alvo: começar a falar daqui (tocar no fim da página).
  int? _pendingSpeakStartInChunk;
  var _isGenerating = false;

  Future<void>? _reanchorInFlight;
  int _queueRebuildToken = 0;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Destaque no PDF + setState: só com app visível (áudio segue com ecrã bloqueado).
  bool get _shouldUpdateReadAlongUi =>
      mounted &&
      _lifecycle == AppLifecycleState.resumed &&
      !_paused;

  final ReadingNotesStore _readingNotesStore = ReadingNotesStore();
  List<ReadingNote> _readingNotes = [];
  List<ReadingHighlight> _readingHighlights = [];
  var _awaitingStickyLineTap = false;
  final GlobalKey _stickyStackLayerKey = GlobalKey();

  var _readAloudEngine = 'system';
  var _sherpaOfflineVoice = 'pt_br-faber-medium';

  bool get isSherpaOffline => _readAloudEngine == 'sherpa' && !kIsWeb;
  String get sherpaVoiceId => _sherpaOfflineVoice;

  @override
  void initState() {
    super.initState();
    _currentPage = (widget.item.lastPageIndex + 1).clamp(1, 1 << 20);
    _totalPages = widget.item.totalPages;
    WidgetsBinding.instance.addObserver(this);
    _vaultAudioStopSub = VaultReadingAudio.systemStopRequests.listen((_) {
      if (!mounted) return;
      _stopPlayback();
    });
    _vaultSegmentSkipSub =
        VaultReadingAudio.segmentSkips.listen((VaultReadingSegmentSkip s) {
      if (!mounted || !_isPlaying) return;
      switch (s) {
        case VaultReadingSegmentSkip.forward:
          unawaited(_seekReadingSeconds(_kReadingTimeSkipSeconds));
        case VaultReadingSegmentSkip.backward:
          unawaited(_seekReadingSeconds(-_kReadingTimeSkipSeconds));
      }
    });
    unawaited(_bootstrapTts());
    unawaited(_reloadReadingNotesForItem());
  }

  Future<void> _reloadReadingNotesForItem() async {
    try {
      final data = await _readingNotesStore.book(widget.item.id);
      if (!mounted) return;
      setState(() {
        _readingNotes = List<ReadingNote>.from(data.notes);
        _readingHighlights = List<ReadingHighlight>.from(data.highlights);
      });
    } catch (_) {}
  }

  Future<void> _persistReadingNotes() async {
    try {
      await _readingNotesStore.saveAnnotationsForBook(
        widget.item.id,
        ReadingBookAnnotations(
          notes: List<ReadingNote>.from(_readingNotes),
          highlights: List<ReadingHighlight>.from(_readingHighlights),
        ),
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.detached) {
      _stopPlayback();
      return;
    }
    if (_isPlaying && !kIsWeb) {
      unawaited(VaultReadingAudio.ensurePlaybackSessionActive());
    }
  }

  Future<void> _bootstrapTts() async {
    await _migrateLegacyReadAloudPrefs();
    final p = await SharedPreferences.getInstance();
    _readAloudEngine = p.getString(_kReadAloudEngine) ?? 'system';
    if (kIsWeb && _readAloudEngine == 'sherpa') {
      _readAloudEngine = 'system';
    }
    var sv =
        (p.getString(_kSherpaOfflineVoice) ?? '').toLowerCase().trim();
    if (const {'miro', 'dii', 'kokoro', 'faber', 'cadu'}.contains(sv) ||
        sv.isEmpty) {
      sv = 'pt_br-faber-medium';
      await p.setString(_kSherpaOfflineVoice, sv);
    }
    _sherpaOfflineVoice = sv;
    _playbackVolume = (p.getDouble(_kReadAloudVolume) ?? 1.0).clamp(0.0, 1.0);
    _speechRate = (p.getDouble(_kSystemSpeechRate) ?? 0.45).clamp(0.22, 0.92);
    _wavPlaybackSpeed =
        (p.getDouble(_kWavPlaybackSpeed) ?? 1.0).clamp(0.6, 1.75);
    await _initSystemTts();
    await _applyPlaybackVolumeToEngines();
  }

  Future<void> _applyPlaybackVolumeToEngines() async {
    await _tts.setVolume(_playbackVolume.clamp(0.0, 1.0));
    await TtsService.instance.setOutputVolume(_playbackVolume);
  }

  Future<void> _persistPlaybackVolume() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kReadAloudVolume, _playbackVolume);
  }

  Future<void> _persistSpeechSpeeds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSystemSpeechRate, _speechRate);
    await prefs.setDouble(_kWavPlaybackSpeed, _wavPlaybackSpeed);
  }

  Future<void> _ensureSherpaInfrastructure() async {
    if (!isSherpaOffline || kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      await VaultReadingAudio.init();
      _attachSherpaWavProgressListener();
    }
    await TtsService.instance.ensureBundlesAndInit(_sherpaOfflineVoice);
  }

  /// [VaultReadingAudio.wavProgress] em initState era sempre `Stream.empty()` porque o
  /// handler só existe depois de [VaultReadingAudio.init] — tens de subscrever aqui.
  void _attachSherpaWavProgressListener() {
    if (!isSherpaOffline || kIsWeb || !VaultReadingAudio.isReady) return;
    _wavProgressSub?.cancel();
    _wavProgressSub = VaultReadingAudio.wavProgress.listen((tick) {
      if (!mounted || !isSherpaOffline || !_isPlaying || !_shouldUpdateReadAlongUi) {
        return;
      }
      final pos = tick.$1;
      final d = tick.$2;

      final now = DateTime.now();
      bool heavyRedraw = true;
      if (_lastWavHighlightRedraw != null &&
          now.difference(_lastWavHighlightRedraw!).inMilliseconds <
              _kSherpaPdfProgressMinRedrawMs) {
        heavyRedraw = false;
      }

      _wavChunkPos = pos;
      if (d != null && d.inMilliseconds > 0) {
        if (_wavChunkDur?.inMilliseconds != d.inMilliseconds) {
          _invalidatePageTimelineCache();
        }
        _wavChunkDur = d;
      }

      if (heavyRedraw) {
        _lastWavHighlightRedraw = now;
        if (!mounted) return;
        setState(() {
          if (!_pageTimelineScrubbing &&
              _queue.isNotEmpty &&
              _chunkIndex < _queue.length) {
            final dm = (_wavChunkDur ?? Duration.zero).inMilliseconds;
            final tAudio = dm <= 0
                ? 0.0
                : (pos.inMilliseconds / dm).clamp(0.0, 1.0);
            _applyReadHighlightChunkProgress(_queue[_chunkIndex], tAudio);
          }
        });
        if (_pdfController.isReady) {
          _pdfController.invalidate();
        }
      }
    });
  }

  void _detachSherpaWavProgressListener() {
    _wavProgressSub?.cancel();
    _wavProgressSub = null;
  }

  String _mediaChunkTitle(String text, int page) {
    final t = text.trim();
    const pfx = 'Pág. ';
    const maxLen = 52;
    final head = '$pfx$page · ';
    if (t.isEmpty) return '${head}Leitura';
    final budget = maxLen - head.length;
    if (t.length <= budget) return '$head$t';
    return '$head${t.substring(0, budget - 1)}…';
  }

  Uri? _coverArtUri() {
    final path = widget.item.coverPath;
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    return Uri.file(f.path);
  }

  void _completeResumeWaitIfAny() {
    final c = _resumeCompleter;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _resumeCompleter = null;
  }

  void _interruptChunkPlayback() {
    _paused = false;
    _completeResumeWaitIfAny();
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stop());
    } else {
      unawaited(_tts.stop());
    }
  }

  /// Botões centrais (±5 s) e controlos compactos da notificação.
  Future<void> _seekReadingSeconds(int deltaSec) async {
    if (!mounted || !_isPlaying || _queue.isEmpty || _chunkIndex >= _queue.length) {
      return;
    }

    if (isSherpaOffline && VaultReadingAudio.isReady) {
      final page = _queue[_chunkIndex].page;
      final timeline = _pageAudioTimeline(page);
      if (timeline.totalMs <= 0) return;
      final currentMs = _pageTimelinePositionMs(page);
      final targetMs =
          (currentMs + deltaSec * 1000).clamp(0, timeline.totalMs);
      if (targetMs == currentMs) return;
      await _commitPageTimelineScrub(targetMs / timeline.totalMs);
      return;
    }

    final chunk = _queue[_chunkIndex];
    final estMs =
        _estimatedFlutterChunkDuration(chunk).inMilliseconds.clamp(1, 1 << 30);
    final currentMs = (_flutterWordProgress * estMs).round();
    final targetMs = (currentMs + deltaSec * 1000).clamp(0, estMs);

    if (deltaSec < 0 && targetMs == 0 && _chunkIndex > 0) {
      _pendingBackChunk = true;
      _interruptChunkPlayback();
      return;
    }
    if (deltaSec > 0 &&
        targetMs >= estMs &&
        _chunkIndex + 1 < _queue.length) {
      _pendingSkipForwardChunk = true;
      _interruptChunkPlayback();
      return;
    }

    final frac = estMs <= 0 ? 0.0 : targetMs / estMs;
    final trim = (chunk.text.length * frac).floor().clamp(0, chunk.text.length);
    final safeTrim =
        trim >= chunk.text.length ? max(0, chunk.text.length - 1) : trim;
    _pendingJumpChunk = _chunkIndex;
    _pendingSpeakStartInChunk = safeTrim > 0 ? safeTrim : null;
    _interruptChunkPlayback();
  }

  Future<void> selectSherpaVoice(String id) async {
    final normalized = id.toLowerCase().trim();
    if (normalized.isEmpty) return;

    final wasPlaying = _isPlaying;
    if (wasPlaying) {
      _stopPlayback();
      if (!kIsWeb && _readAloudEngine == 'sherpa') {
        await TtsService.instance.stop();
      }
    }

    if (_sherpaOfflineVoice != normalized) {
      TtsService.instance.dispose();
    }

    /// Falha antes de gravar prefs (ex.: ONNX em falta) — modal mostra [SnackBar].
    await TtsService.instance.ensureBundlesAndInit(normalized);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kReadAloudEngine, 'sherpa');
    await prefs.setString(_kSherpaOfflineVoice, normalized);

    if (!mounted) return;
    setState(() {
      _readAloudEngine = 'sherpa';
      _sherpaOfflineVoice = normalized;
    });

    _clearQueuedPlaybackState();
    _chunkIndex = 0;
    _pendingSkipForwardChunk = false;
  }

  Future<void> applySystemVoiceFromModal(Map<String, String> v) async {
    final loc = v['locale'] ?? v['Locale'] ?? '';
    await _tts.setLanguage(loc);
    final map = <String, String>{...v}..removeWhere((k, val) => val.isEmpty);
    if (map.isNotEmpty) {
      await _tts.setVoice(map);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kReadAloudEngine, 'system');
    await p.setString(_kVoicePrefsKey, jsonEncode(map));
    if (isSherpaOffline) {
      TtsService.instance.dispose();
    }
    if (!mounted) return;
    setState(() {
      _readAloudEngine = 'system';
    });
    _detachSherpaWavProgressListener();
    _clearQueuedPlaybackState();
    _chunkIndex = 0;
    _pendingSkipForwardChunk = false;
  }

  Future<void> _migrateLegacyReadAloudPrefs() async {
    final p = await SharedPreferences.getInstance();
    final engine = p.getString(_kReadAloudEngine);
    if (engine == 'azure_speech' ||
        engine == 'elevenlabs' ||
        engine == 'fish_audio') {
      await p.setString(_kReadAloudEngine, 'system');
    }
  }

  void _onFlutterTtsProgress(String text, int startOffset, int endOffset, String word) {
    if (!mounted || !_shouldUpdateReadAlongUi) return;
    if (_queue.isEmpty || _chunkIndex >= _queue.length) return;
    final chunk = _queue[_chunkIndex];
    final pageText = _structuredByPage[chunk.page];
    if (pageText == null) return;
    final now = DateTime.now();
    if (_lastProgressRedraw != null &&
        now.difference(_lastProgressRedraw!).inMilliseconds < 170) {
      return;
    }
    _lastProgressRedraw = now;
    var a = chunk.offsetInPage + startOffset;
    var b = chunk.offsetInPage + endOffset;
    final len = pageText.fullText.length;
    if (a < 0) a = 0;
    if (b > len) b = len;
    if (a > b) return;
    final clen = chunk.text.length;
    final nextProg = clen <= 0
        ? 0.0
        : ((endOffset < 0 ? 0 : endOffset).toDouble().clamp(
              0.0,
              clen.toDouble(),
            ) /
            clen);
    final nextHighlight = PdfPageTextRange(
      pageText: pageText,
      start: a,
      end: b,
    );
    final hlSame = _sameReadHighlight(nextHighlight);
    final progJump = (_flutterWordProgress - nextProg).abs() >= 0.02;
    if (hlSame && !progJump) return;
    if (!hlSame) {
      _readHighlight = nextHighlight;
      if (_pdfController.isReady) {
        _pdfController.invalidate();
      }
    }
    _flutterWordProgress = nextProg;
    setState(() {});
  }

  Future<void> _initSystemTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(_playbackVolume.clamp(0.0, 1.0));
    if (!kIsWeb && !isSherpaOffline) {
      _tts.setProgressHandler(_onFlutterTtsProgress);
    }

    if (isSherpaOffline) {
      await _tts.setLanguage(_defaultVoiceLocale);
      return;
    }

    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kVoicePrefsKey);
    if (s == null) {
      await _tts.setLanguage(_defaultVoiceLocale);
      return;
    }
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      var loc = m['locale'] as String? ?? _defaultVoiceLocale;
      if (!_isLocalePtBr(loc)) loc = _defaultVoiceLocale;
      await _tts.setLanguage(loc);
      final voice = <String, String>{};
      for (final e in m.entries) {
        if (e.value != null) voice[e.key] = e.value.toString();
      }
      if (voice.isNotEmpty && _isLocalePtBr(m['locale'] as String?)) {
        await _tts.setVoice(voice);
      }
    } catch (_) {}
  }

  void _persistPage() {
    widget.onPagePersist?.call(
      _currentPage - 1,
      totalPages: _totalPages,
    );
  }

  /// Mantém página visível = página da leitura; com ecrã bloqueado só atualiza índice (sem PDF).
  Future<void> _syncViewerToReadingPage(int pageNum) async {
    if (!mounted || pageNum < 1) return;
    if (_totalPages != null && pageNum > _totalPages!) return;
    if (pageNum == _currentPage) return;
    if (!_shouldUpdateReadAlongUi) {
      _currentPage = pageNum;
      return;
    }
    setState(() => _currentPage = pageNum);
    if (!_pdfController.isReady) return;
    try {
      await _pdfController.goToPage(pageNumber: pageNum);
    } catch (_) {}
  }

  void _applyChunkHighlightStartUi(_Chunk c) {
    _applyReadHighlightChunkProgress(c, 0);
    _flutterWordProgress = 0;
    if (!_shouldUpdateReadAlongUi) return;
    setState(() {});
    if (_pdfController.isReady) {
      _pdfController.invalidate();
    }
  }

  /// Ao sair do ecrã: preferir o segmento da fila se existir leitura recente,
  /// para não gravar só a página visível quando se navega durante áudio.
  void _persistLibraryBookmarkOnExit() {
    if (_queue.isNotEmpty && _chunkIndex < _queue.length) {
      widget.onPagePersist?.call(
        _queue[_chunkIndex].page - 1,
        totalPages: _totalPages,
      );
    } else {
      _persistPage();
    }
  }

  String _subtitleForPdfAppBar(int? totalPages) {
    if (totalPages == null) return 'A abrir PDF…';
    final readingPage =
        (!_isPlaying || _queue.isEmpty || _chunkIndex >= _queue.length)
            ? null
            : _queue[_chunkIndex].page;
    if (readingPage != null &&
        readingPage != _currentPage &&
        _isPlaying) {
      return 'A ler pág. $readingPage · A ver pág. '
          '$_currentPage de $totalPages · PDF';
    }
    return 'Página $_currentPage de $totalPages · PDF no ecrã';
  }

  void _bumpReadingPrefetchGen() {
    _readingPrefetchGeneration++;
  }

  void _invalidatePageTimelineCache() {
    _cachedTimelinePage = null;
    _cachedTimelineIndices = null;
    _cachedTimelineDurationsMs = null;
    _cachedTimelineTotalMs = 0;
    _cachedTimelineQueueLen = -1;
    _cachedTimelineChunkIndex = -1;
    _cachedTimelineWavDurMs = -1;
  }

  /// Invalida prefetch e cancela síntese Sherpa em fila (scrub/pausa/interrupt).
  void _cancelSherpaPipeline() {
    _bumpReadingPrefetchGen();
    _clearSherpaPrefetchFutures();
    _invalidatePageTimelineCache();
    if (isSherpaOffline && !kIsWeb) {
      unawaited(TtsService.instance.cancelPendingSynthesis());
    }
  }

  Future<String?> _prepareSherpaWavIfActive(String text, int genAtSchedule) async {
    try {
      final path =
          await TtsService.instance.prepareWavForText(_normalizeTtsText(text));
      if (!mounted ||
          !_isPlaying ||
          genAtSchedule != _readingPrefetchGeneration) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        return null;
      }
      return path;
    } on TtsSynthesisCancelled {
      return null;
    }
  }

  void _attachSherpaSpareChain(
    Future<String?>? primary,
    int primaryQueueIndex,
    int gen,
  ) {
    if (primary == null) return;
    unawaited(primary.then((p) {
      if (p == null) return;
      if (!mounted || !_isPlaying || gen != _readingPrefetchGeneration) return;
      final n = primaryQueueIndex + 1;
      if (n < _queue.length && _sherpaSpareWav == null) {
        _sherpaSpareWav = _prepareSherpaWavIfActive(_queue[n].text, gen);
        _sherpaSpareForQueueIndex = n;
      }
    }));
  }

  /// Agenda síntese para `queueIndex` e, ao concluir, a do segmento seguinte.
  void _scheduleSherpaPrefetchFromQueueIndex(int queueIndex, int gen) {
    if (queueIndex >= _queue.length) return;
    _sherpaNextWav = _prepareSherpaWavIfActive(_queue[queueIndex].text, gen);
    _attachSherpaSpareChain(_sherpaNextWav, queueIndex, gen);
  }

  void _clearSherpaPrefetchFutures() {
    _sherpaNextWav = null;
    _sherpaSpareWav = null;
    _sherpaSpareForQueueIndex = null;
  }

  bool _sameReadHighlight(PdfPageTextRange o) {
    final h = _readHighlight;
    if (h == null) return false;
    return identical(h.pageText, o.pageText) && h.start == o.start && h.end == o.end;
  }

  void _clearHighlight() {
    _lastProgressRedraw = null;
    _lastWavHighlightRedraw = null;
    _flutterWordProgress = 0;
    _readHighlight = null;
    if (_pdfController.isReady) {
      _pdfController.invalidate();
    }
  }

  /// [linearProgress] ∈ [0,1]: fração do segmento já ouvida (Sherpa segue o WAV).
  void _applyReadHighlightChunkProgress(_Chunk chunk, double linearProgress) {
    final pageText = _structuredByPage[chunk.page];
    if (pageText == null) {
      _readHighlight = null;
      return;
    }
    final fullLen = pageText.fullText.length;
    final startIdx = chunk.offsetInPage.clamp(0, fullLen);
    final segmentLen = chunk.text.length;
    final tt = linearProgress.clamp(0.0, 1.0);
    final int charsRead;
    if (segmentLen <= 0) {
      charsRead = 0;
    } else if (tt >= 1.0) {
      charsRead = segmentLen;
    } else if (tt <= 0) {
      // Sem isto start==end e o PDF não pinta nada até ao primeiro tick do WAV.
      charsRead = 1;
    } else {
      charsRead = max(1, (segmentLen * tt).floor()).clamp(1, segmentLen);
    }
    final endIdx = min(startIdx + charsRead, fullLen);
    _readHighlight = PdfPageTextRange(
      pageText: pageText,
      start: startIdx,
      end: max(startIdx, endIdx),
    );
  }

  static String _preparePageSourceText(String raw) {
    return raw.replaceAll(RegExp(r'\r\n'), '\n').trim();
  }

  static int _footnoteLeadingSkipForRaw(String raw) {
    final crlf = raw.replaceAll(RegExp(r'\r\n'), '\n');
    return RegExp(r'^\s*').firstMatch(crlf)?.group(0)?.length ?? 0;
  }

  /// Índice no texto retornado por [_preparePageSourceText].
  static int linkedPrepCharFromRawTap(PdfPageText structured, int rawCharTap) {
    final prepared = _preparePageSourceText(structured.fullText);
    if (prepared.isEmpty) return 0;
    final raw = structured.fullText.replaceAll(RegExp(r'\r\n'), '\n');
    final skip = _footnoteLeadingSkipForRaw(structured.fullText);
    var ri = rawCharTap.clamp(0, max(0, raw.length - 1));
    if (ri < skip) ri = skip;
    final inside = ri - skip;
    return inside.clamp(0, prepared.length - 1).toInt();
  }

  /// Inverso simplificado de [linkedPrepCharFromRawTap]: `prepared.trim ≈ raw[skip+]` só perde `\s` nos extremos.
  static int? _rawCharIndexForLinkedPrep(PdfPageText structured, int prepIdx) {
    final prepared = _preparePageSourceText(structured.fullText);
    if (structured.charRects.isEmpty ||
        prepared.isEmpty ||
        prepIdx < 0 ||
        prepIdx >= prepared.length) {
      return null;
    }
    final skip = _footnoteLeadingSkipForRaw(structured.fullText);
    final ri = skip + prepIdx;
    return ri.clamp(0, structured.charRects.length - 1).toInt();
  }

  Offset _normalizedStickyAnchorFromRaw(
    PdfPageText structured,
    int pageNum,
    int rawCharIndex,
  ) {
    if (!_pdfController.isReady) {
      return Offset.zero;
    }
    final layouts = _pdfController.layout.pageLayouts;
    if (pageNum < 1 ||
        pageNum > layouts.length ||
        rawCharIndex < 0 ||
        rawCharIndex >= structured.charRects.length) {
      return Offset.zero;
    }
    final pageRect = layouts[pageNum - 1];
    final page = _pdfController.pages[pageNum - 1];
    final pdfRect = structured.charRects[rawCharIndex];
    final r = pdfRect.toRectInDocument(page: page, pageRect: pageRect);
    final local = _pdfController.documentToLocal(r.center);
    final box =
        _stickyStackLayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.hasSize == false) {
      return Offset.zero;
    }
    final w = box.size.width;
    final h = box.size.height;
    if (w <= 0 || h <= 0) return Offset.zero;
    return Offset(
      (local.dx / w).clamp(0.06, 0.94),
      (local.dy / h).clamp(0.06, 0.93),
    );
  }

  Offset _stickyResolvedNorm(ReadingNote n) {
    if (n.pageNumber != _currentPage) {
      return Offset(n.anchorX, n.anchorY);
    }
    final structured = _structuredByPage[n.pageNumber];
    final prep = n.linkedPrepCharIndex;
    if (structured == null || prep == null) {
      return Offset(n.anchorX, n.anchorY);
    }
    final prepared = _preparePageSourceText(structured.fullText);
    if (prep < 0 || prep >= prepared.length) {
      return Offset(n.anchorX, n.anchorY);
    }
    final rawIdx = _rawCharIndexForLinkedPrep(structured, prep);
    if (rawIdx == null) return Offset(n.anchorX, n.anchorY);
    final norm =
        _normalizedStickyAnchorFromRaw(structured, n.pageNumber, rawIdx);
    if (norm == Offset.zero) {
      return Offset(n.anchorX, n.anchorY);
    }
    return norm;
  }

  Offset _badgeNormalizedForSticky(ReadingNote n) {
    return _stickyResolvedNorm(n);
  }

  Future<PdfPageText?> _structuredForPage(int pageNum) async {
    final cached = _structuredByPage[pageNum];
    if (cached != null) return cached;

    if (!_pdfController.isReady) return null;
    final loaded = await _pdfController.useDocument((doc) async {
      if (pageNum < 1 || pageNum > doc.pages.length) return null;
      var page = doc.pages[pageNum - 1];
      if (!page.isLoaded) page = await page.ensureLoaded();
      return page.loadStructuredText();
    });
    if (loaded != null) {
      _structuredByPage[pageNum] = loaded;
    }
    return loaded;
  }

  void _clearQueuedPlaybackState() {
    _queue.clear();
    _pageTextFromQueue.clear();
    _pagesMaterializedIntoQueue.clear();
    _invalidatePageTimelineCache();
  }

  bool _queueHasChunksForPage(int pageNum) {
    for (final c in _queue) {
      if (c.page == pageNum) return true;
    }
    return false;
  }

  int? _readingPageFromQueue() {
    if (_chunkIndex < 0 || _chunkIndex >= _queue.length) return null;
    return _queue[_chunkIndex].page;
  }

  /// Trecho + offset dentro do texto do trecho (saltar leitura na mesma página).
  ({int chunkIndex, int trimInChunk}) _resolveJumpOnPage(
    int pageNum,
    int charOffset,
  ) {
    var lastOnPage = 0;
    for (var i = 0; i < _queue.length; i++) {
      final c = _queue[i];
      if (c.page != pageNum) continue;
      lastOnPage = i;
      final start = c.offsetInPage;
      final end = start + c.text.length;
      if (charOffset >= start && charOffset < end) {
        return (chunkIndex: i, trimInChunk: charOffset - start);
      }
    }
    final c = _queue[lastOnPage];
    final trim = (charOffset - c.offsetInPage).clamp(0, c.text.length);
    final safeTrim = trim >= c.text.length ? 0 : trim;
    return (chunkIndex: lastOnPage, trimInChunk: safeTrim);
  }

  _Chunk _chunkTrimmedForPlayback(_Chunk c, int trimInChunk) {
    if (trimInChunk <= 0) return c;
    final t = trimInChunk.clamp(0, c.text.length);
    if (t <= 0 || t >= c.text.length) return c;
    return _Chunk(c.page, c.text.substring(t), c.offsetInPage + t);
  }

  void _scheduleJumpToPageOffset(int pageNum, int charOffset) {
    final target = _resolveJumpOnPage(pageNum, charOffset);
    _cancelSherpaPipeline();
    _pendingJumpChunk = target.chunkIndex;
    _pendingSpeakStartInChunk =
        target.trimInChunk > 0 ? target.trimInChunk : null;
  }

  int _sherpaChunkMaxLen() => _kSherpaTtsChunkMax;

  int _queueChunkMaxLen() => isSherpaOffline ? _sherpaChunkMaxLen() : 3000;

  /// Reconstrói a fila só na página alvo (+ seguinte), em vez de carregar todas as intermediárias.
  Future<void> _reanchorPlaybackToPage(
    int pageNum, {
    int charOffset = 0,
    bool interruptIfPlaying = false,
  }) async {
    if (!mounted) return;
    if (pageNum < 1) return;
    if (_totalPages != null && pageNum > _totalPages!) return;

    final token = ++_queueRebuildToken;
    _cancelSherpaPipeline();

    if (interruptIfPlaying && _isPlaying) {
      _interruptChunkPlayback();
    }

    _clearQueuedPlaybackState();

    final chunkMax = _queueChunkMaxLen();
    final splitParagraphs = !isSherpaOffline;

    await _materializePageIntoQueue(
      pageNum,
      chunkMax: chunkMax,
      splitParagraphs: splitParagraphs,
    );
    if (!mounted || token != _queueRebuildToken) return;

    if (_totalPages != null && pageNum < _totalPages!) {
      await _materializePageIntoQueue(
        pageNum + 1,
        chunkMax: chunkMax,
        splitParagraphs: splitParagraphs,
      );
    }
    if (!mounted || token != _queueRebuildToken) return;

    final target = _resolveJumpOnPage(pageNum, charOffset);
    _chunkIndex =
        target.chunkIndex.clamp(0, max(0, _queue.length - 1));
    _pendingSpeakStartInChunk =
        target.trimInChunk > 0 ? target.trimInChunk : null;

    if (_isPlaying) {
      _pendingJumpChunk = _chunkIndex;
      _pendingSkipForwardChunk = false;
      _pendingBackChunk = false;
    }
  }

  Future<void> _awaitReanchorIfAny() async {
    final f = _reanchorInFlight;
    if (f != null) await f;
  }

  void _maybeTrimStructuredTextCache() {
    if (_isPlaying) return;
    final tp = _totalPages;
    if (tp == null || tp == 0) return;

    final keep = <int>{};
    for (final h in _readingHighlights) {
      final p = h.pageNumber;
      if (p >= 1 && p <= tp) keep.add(p);
    }
    for (var d = -_kStructuredTextCacheNearbyPages;
        d <= _kStructuredTextCacheNearbyPages;
        d++) {
      final p = _currentPage + d;
      if (p >= 1 && p <= tp) keep.add(p);
    }
    final keys = List<int>.from(_structuredByPage.keys);
    for (final k in keys) {
      if (!keep.contains(k)) _structuredByPage.remove(k);
    }
  }

  Future<void> _materializePageIntoQueue(
    int pageNum, {
    required int chunkMax,
    required bool splitParagraphs,
  }) async {
    if (!mounted) return;
    if (pageNum < 1) return;
    if (_totalPages != null && pageNum > _totalPages!) return;
    if (_pagesMaterializedIntoQueue.contains(pageNum)) return;
    _pagesMaterializedIntoQueue.add(pageNum);

    final structured = await _structuredForPage(pageNum);
    if (!mounted) return;

    final pageFull = structured == null
        ? ''
        : _preparePageSourceText(structured.fullText);
    if (pageFull.isEmpty) return;

    _pageTextFromQueue[pageNum] = pageFull;
    final parts = _splitTtsWithOffsets(
      pageFull,
      maxLen: chunkMax,
      splitAtParagraphs: splitParagraphs,
    );
    for (final part in parts) {
      _queue.add(_Chunk(pageNum, part.text, part.start));
    }
  }

  /// Pré-carrega páginas à medida (não faz `loadStructuredText` no livro inteiro ao iniciar Play).
  Future<void> _ensureQueuedChunksExtendThrough(int maxChunkIndexInclusive) async {
    final tp = _totalPages;
    if (tp == null) return;

    if (_queue.isNotEmpty && maxChunkIndexInclusive >= _queue.length) {
      final tailPage = _queue.last.page;
      if (_currentPage > tailPage + 1) {
        await _reanchorPlaybackToPage(
          _currentPage,
          interruptIfPlaying: false,
        );
        return;
      }
    }

    var safety = (tp) + 32;
    var pagesLoadedThisPass = 0;
    while (mounted &&
        maxChunkIndexInclusive >= 0 &&
        _queue.length <= maxChunkIndexInclusive) {
      if (safety-- <= 0) break;

      if (_queue.isNotEmpty &&
          pagesLoadedThisPass >= _kMaxSequentialQueuePageLoads &&
          _currentPage > _queue.last.page + 1) {
        await _reanchorPlaybackToPage(
          _currentPage,
          interruptIfPlaying: false,
        );
        return;
      }

      final basePage = _queue.isEmpty ? (_currentPage - 1) : _queue.last.page;
      var probe = basePage + 1;

      while (probe <= tp && _pagesMaterializedIntoQueue.contains(probe)) {
        probe++;
      }
      if (probe > tp) {
        return;
      }

      await _materializePageIntoQueue(
        probe,
        chunkMax: _queueChunkMaxLen(),
        splitParagraphs: !isSherpaOffline,
      );
      pagesLoadedThisPass++;
    }
  }

  /// Mantém sempre a página seguinte na fila, mesmo quando a atual tem muitos
  /// segmentos — sem isto só se pedia próxima página no último chunk (delay lá).
  Future<void> _ensureNextReadingPageQueued(int readingPage) async {
    if (!mounted) return;
    final tp = _totalPages;
    if (tp == null) return;
    final next = readingPage + 1;
    if (next > tp) return;
    if (_pagesMaterializedIntoQueue.contains(next)) return;
    await _materializePageIntoQueue(
      next,
      chunkMax: _queueChunkMaxLen(),
      splitParagraphs: !isSherpaOffline,
    );
  }

  void _paintReadAloudHighlight(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    final range = _readHighlight;
    if (!_isPlaying || range == null || range.pageNumber != page.pageNumber) {
      return;
    }
    final fill = ui.Paint()..color = _readHighlightFill;
    final stroke = ui.Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.75
      ..color = const Color(0xCFFFFFFF);
    final raw = [
      for (final br in range.enumerateFragmentBoundingRects())
        br.bounds
            .toRect(page: page, scaledPageSize: pageRect.size)
            .translate(pageRect.left, pageRect.top),
    ];
    final bands = mergeAdjacentPdfHighlightRects(raw)
        .map((r) => r.inflate(0.85))
        .toList();
    for (final r in bands) {
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  void _paintSavedHighlights(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    paintReadingHighlightsOnPdfPage(
      canvas: canvas,
      pageRect: pageRect,
      page: page,
      highlights: _readingHighlights,
      structuredByPage: _structuredByPage,
    );
  }

  bool _onPdfTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (details.type != PdfViewerGeneralTapType.tap) return false;
    if (_awaitingStickyLineTap) {
      unawaited(_handleStickyLinePlacement(details.documentPosition));
      return false;
    }
    unawaited(_jumpFromDocumentTap(details.documentPosition));
    return false;
  }

  Future<void> _handleStickyLinePlacement(Offset docPoint) async {
    if (!_pdfController.isReady || !mounted) return;
    final pageNum = _pageNumberAtDocumentPoint(docPoint);
    if (pageNum == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Toca dentro do texto da página.'),
        ),
      );
      return;
    }
    final charIndex = await _charIndexAtDocumentPoint(docPoint, pageNum);
    if (charIndex == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Sem texto legível aqui — tenta noutra linha.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    final structured = await _structuredForPage(pageNum);
    if (structured == null || !mounted) return;

    final linkedPrep = linkedPrepCharFromRawTap(structured, charIndex);
    final noteCountSamePage =
        _readingNotes.where((n) => n.pageNumber == pageNum).length;
    final spawn = stickySpawnAnchorsNormalized(noteCountSamePage);

    if (pageNum != _currentPage) {
      setState(() => _currentPage = pageNum);
      if (!_isPlaying) _persistPage();
      await _pdfController.goToPage(pageNumber: pageNum);
      if (!mounted) return;
    }

    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    await completer.future;
    if (!mounted) return;

    var anchor = _normalizedStickyAnchorFromRaw(structured, pageNum, charIndex);
    if (anchor == Offset.zero) {
      anchor = spawn;
    }

    setState(() => _awaitingStickyLineTap = false);
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();

    if (!mounted) return;
    final pal = kPdfStickyPalettes[noteCountSamePage % kPdfStickyPalettes.length];
    final r = await pushPdfStickyComposer(
      context: context,
      libraryItemId: widget.item.id,
      pageNumber: pageNum,
      anchorX: anchor.dx,
      anchorY: anchor.dy,
      initialPaperArgb: pal.$1,
      initialTextArgb: pal.$2,
      linkedPrepCharIndex: linkedPrep,
    );
    await _applyStickyComposer(r);
  }

  Future<void> _jumpFromDocumentTap(Offset docPoint) async {
    if (!_pdfController.isReady) return;
    final pageNum = _pageNumberAtDocumentPoint(docPoint);
    if (pageNum == null) return;
    final charIndex = await _charIndexAtDocumentPoint(docPoint, pageNum);
    if (charIndex == null) return;
    if (pageNum != _currentPage) {
      setState(() => _currentPage = pageNum);
      if (!_isPlaying) {
        _persistPage();
      }
      await _pdfController.goToPage(pageNumber: pageNum);
    }
    await _jumpToCharOffset(charIndex);
  }

  int? _pageNumberAtDocumentPoint(Offset docPoint) {
    final layouts = _pdfController.layout.pageLayouts;
    for (var i = 0; i < layouts.length; i++) {
      if (layouts[i].contains(docPoint)) return i + 1;
    }
    return null;
  }

  Future<int?> _charIndexAtDocumentPoint(Offset docPoint, int pageNum) async {
    final text = await _structuredForPage(pageNum);
    if (text == null || !_pdfController.isReady) return null;
    final layouts = _pdfController.layout.pageLayouts;
    if (pageNum < 1 || pageNum > layouts.length) return null;
    final pageRect = layouts[pageNum - 1];
    if (!pageRect.contains(docPoint)) return null;
    final page = _pdfController.pages[pageNum - 1];
    final pt = docPoint
        .translate(-pageRect.left, -pageRect.top)
        .toPdfPoint(page: page, scaledPageSize: pageRect.size);
    const margin = 8.0;
    var d2Min = double.infinity;
    int? closest;
    for (var i = 0; i < text.charRects.length; i++) {
      final charRect = text.charRects[i];
      if (charRect.containsPoint(pt)) return i;
      final d2 = charRect.distanceSquaredTo(pt);
      if (d2 < d2Min) {
        d2Min = d2;
        closest = i;
      }
    }
    if (closest != null && d2Min <= margin * margin) return closest;
    return null;
  }

  bool _readingHighlightDuplicate(ReadingHighlight candidate) {
    for (final h in _readingHighlights) {
      if (h.pageNumber == candidate.pageNumber &&
          h.start == candidate.start &&
          h.end == candidate.end) {
        return true;
      }
    }
    return false;
  }

  void _customizePdfContextMenu(
    PdfViewerContextMenuBuilderParams params,
    List<ContextMenuButtonItem> items,
  ) {
    if (!params.isTextSelectionEnabled) return;
    if (!params.textSelectionDelegate.hasSelectedText) return;
    items.insert(
      0,
      ContextMenuButtonItem(
        label: 'Grifar e guardar',
        onPressed: () async {
          final del = params.textSelectionDelegate;
          params.dismissContextMenu();
          await _persistHighlightsFromSelection(del);
        },
      ),
    );
  }

  Future<void> _persistHighlightsFromSelection(
    PdfTextSelectionDelegate delegate,
  ) async {
    if (!_pdfController.isReady || !mounted) return;
    List<PdfPageTextRange> ranges;
    try {
      ranges = await delegate.getSelectedTextRanges();
    } catch (_) {
      ranges = [];
    }
    if (ranges.isEmpty) {
      await delegate.clearTextSelection();
      if (!mounted) return;
      if (_pdfController.isReady) _pdfController.invalidate();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Seleção vazia — escolhe outro trecho.'),
        ),
      );
      return;
    }

    if (!mounted) return;
    final picked =
        await showReadingHighlightColorPicker(context);
    await delegate.clearTextSelection();
    if (!mounted) return;

    if (picked == null) {
      if (_pdfController.isReady) _pdfController.invalidate();
      return;
    }

    final now = DateTime.now();
    var added = 0;
    for (var ri = 0; ri < ranges.length; ri++) {
      final r = ranges[ri];
      final pageNum = r.pageNumber;
      final len = r.pageText.fullText.length;
      final s = r.start.clamp(0, len);
      final e = r.end.clamp(0, len);
      if (e <= s) continue;
      final previewRaw =
          len == 0 ? '' : r.pageText.fullText.substring(s, min(e, s + 140));
      final preview = _preparePageSourceText(previewRaw).trim();
      final nid = '${widget.item.id}-h-${now.microsecondsSinceEpoch}-$ri';
      final hl = ReadingHighlight(
        id: nid,
        libraryItemId: widget.item.id,
        pageNumber: pageNum,
        start: s,
        end: e,
        preview: preview.isEmpty ? '…' : preview,
        createdAt: now,
        highlightArgb: picked,
      );
      if (!_readingHighlightDuplicate(hl)) {
        _readingHighlights.add(hl);
        _structuredByPage[pageNum] = r.pageText;
        added++;
      }
    }
    if (!mounted) return;
    if (added == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Esse trecho já estava grifado.'),
        ),
      );
      return;
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(added == 1 ? 'Grifo guardado.' : '$added grifos guardados.'),
      ),
    );
    await _persistReadingNotes();
    if (mounted && _pdfController.isReady) {
      _pdfController.invalidate();
    }
  }

  Future<void> _jumpToStoredHighlight(ReadingHighlight h) async {
    if (!_pdfController.isReady || !mounted) return;
    final structured = await _structuredForPage(h.pageNumber);
    if (structured == null || !mounted) return;
    final len = structured.fullText.length;
    final s = h.start.clamp(0, len);
    final e = h.end.clamp(s, len);
    if (s >= e) return;
    final range = PdfPageTextRange(pageText: structured, start: s, end: e);
    final b = range.bounds;
    try {
      if (h.pageNumber != _currentPage) {
        setState(() => _currentPage = h.pageNumber);
        if (!_isPlaying) {
          _persistPage();
        }
      }
      await _pdfController.goToRectInsidePage(
        pageNumber: h.pageNumber,
        rect: b,
        anchor: PdfPageAnchor.center,
      );
      if (_pdfController.isReady) {
        _pdfController.invalidate();
      }
    } catch (_) {}
  }

  Widget _readingBookmarksSectionHeader(
    BuildContext context,
    IconData icon,
    String title,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _openReadingBookmarksSheet() async {
    await _reloadReadingNotesForItem();
    if (!mounted) return;
    var sortedNotes = [..._readingNotes]
      ..sort((a, b) {
        final p = a.pageNumber.compareTo(b.pageNumber);
        if (p != 0) return p;
        return b.createdAt.compareTo(a.createdAt);
      });
    var sortedHl = [..._readingHighlights]
      ..sort((a, b) {
        final p = a.pageNumber.compareTo(b.pageNumber);
        if (p != 0) return p;
        return b.createdAt.compareTo(a.createdAt);
      });

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setInner) {
            void refreshLocals() {
              sortedNotes = [..._readingNotes]
                ..sort((a, b) {
                  final p = a.pageNumber.compareTo(b.pageNumber);
                  if (p != 0) return p;
                  return b.createdAt.compareTo(a.createdAt);
                });
              sortedHl = [..._readingHighlights]
                ..sort((a, b) {
                  final p = a.pageNumber.compareTo(b.pageNumber);
                  if (p != 0) return p;
                  return b.createdAt.compareTo(a.createdAt);
                });
            }

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(ctx).height * 0.72,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Text(
                        'Marcadores deste PDF',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    Expanded(
                      child: sortedNotes.isEmpty && sortedHl.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(22),
                                child: Text(
                                  'Ainda não tens notas nem grifos guardados neste livro.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(ctx)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.only(bottom: 18),
                              children: [
                                if (sortedNotes.isNotEmpty) ...[
                                  _readingBookmarksSectionHeader(
                                    ctx,
                                    Icons.sticky_note_2_rounded,
                                    'Notas de rodapé',
                                  ),
                                  ...sortedNotes.map((n) {
                                    return ListTile(
                                      leading: const Icon(Icons.sell_outlined),
                                      title: Text(
                                        n.body.trim().isEmpty
                                            ? '(Nota vazia)'
                                            : n.body.trim(),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text('Pág. ${n.pageNumber}'),
                                      onTap: () async {
                                        Navigator.pop(ctx);
                                        if (mounted) {
                                          setState(() {
                                            _currentPage = n.pageNumber;
                                          });
                                        }
                                        await _pdfController.goToPage(
                                          pageNumber: n.pageNumber,
                                        );
                                        if (!_isPlaying) {
                                          _persistPage();
                                        }
                                        if (mounted) {
                                          await _peekSticky(n);
                                        }
                                      },
                                    );
                                  }),
                                ],
                                if (sortedHl.isNotEmpty) ...[
                                  _readingBookmarksSectionHeader(
                                    ctx,
                                    Icons.highlight_alt_rounded,
                                    'Grifos guardados',
                                  ),
                                  ...sortedHl.map((h) {
                                    return ListTile(
                                      leading: Icon(
                                        Icons.push_pin_rounded,
                                        color: Color(h.highlightArgb),
                                      ),
                                      title: Text(
                                        h.preview,
                                        maxLines: 4,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        'Pág. ${h.pageNumber} · cor do grifo · tocar para ir ao texto',
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'Apagar',
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          color: Theme.of(ctx).colorScheme.error,
                                        ),
                                        onPressed: () async {
                                          if (!mounted) return;
                                          setState(() {
                                            _readingHighlights.removeWhere(
                                                (e) => e.id == h.id);
                                          });
                                          await _persistReadingNotes();
                                          if (_pdfController.isReady) {
                                            _pdfController.invalidate();
                                          }
                                          refreshLocals();
                                          setInner(() {});
                                          if (!ctx.mounted) return;
                                          if (sortedNotes.isEmpty &&
                                              sortedHl.isEmpty) {
                                            Navigator.pop(ctx);
                                          }
                                        },
                                      ),
                                      onTap: () async {
                                        Navigator.pop(ctx);
                                        await _jumpToStoredHighlight(h);
                                      },
                                    );
                                  }),
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Divide texto em segmentos até [maxLen], cortando preferencialmente em frases.
  /// Com [splitAtParagraphs]: também corta em `\n\n` / `\n` (bom para motor do sistema).
  /// Com false (Sherpa offline): ignora parágrafos — leitura contínua com o mínimo de WAVs.
  static List<({String text, int start})> _splitTtsWithOffsets(
    String t, {
    int maxLen = 3000,
    bool splitAtParagraphs = true,
  }) {
    if (t.isEmpty) return [];
    if (t.length <= maxLen) return [(text: t, start: 0)];
    final out = <({String text, int start})>[];
    var i = 0;
    while (i < t.length) {
      var end = (i + maxLen) > t.length ? t.length : (i + maxLen);
      if (end < t.length) {
        var cut = -1;
        if (splitAtParagraphs) {
          cut = t.lastIndexOf('\n\n', end);
          if (cut <= i) {
            cut = t.lastIndexOf('\n', end);
          }
        }
        if (cut <= i) cut = t.lastIndexOf('. ', end);
        if (cut <= i) cut = t.lastIndexOf('! ', end);
        if (cut <= i) cut = t.lastIndexOf('? ', end);
        if (cut <= i) cut = t.lastIndexOf('; ', end);
        if (!splitAtParagraphs && cut <= i) {
          cut = t.lastIndexOf(', ', end);
        }
        if (cut <= i) cut = t.lastIndexOf(' ', end);
        if (cut > i) end = cut + 1;
      }
      final segment = t.substring(i, end);
      if (segment.trim().isNotEmpty) {
        out.add((text: segment, start: i));
      }
      i = end;
    }
    return out;
  }

  /// Collapses excessive whitespace so TTS doesn't insert long silences
  /// between paragraphs. Preserves the original length for offset mapping.
  static String _normalizeTtsText(String t) {
    return t
        .replaceAll(RegExp(r'\r\n'), '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  }

  Future<void> _fillQueue({int? fromPage}) async {
    await _reanchorPlaybackToPage(
      fromPage ?? _currentPage,
      interruptIfPlaying: false,
    );
  }

  Future<void> _play() async {
    if (_isPlaying) return;
    if (_queue.isNotEmpty && _chunkIndex < _queue.length) {
      // continuar a mesma fila
    } else {
      await _reloadReadingNotesForItem();
      if (!mounted) return;
      await _fillQueue();
      _chunkIndex = 0;
    }
    if (!mounted) return;
    if (_queue.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nada para ler a partir desta página.')),
        );
      }
      return;
    }

    try {
      await _ensureSherpaInfrastructure();
    } catch (e) {
      if (!mounted) return;
      final msg =
          e is StateError ? e.message : 'Offline TTS: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 12),
          content: Text(msg, maxLines: 8),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _isPlaying = true;
      _paused = false;
      _clearHighlight();
    });
    await _run();
  }

  Future<void> _pauseFlutterTtsForReadAloud() async {
    if (kIsWeb) return;
    try {
      await _tts.pause();
    } catch (_) {}
  }

  /// Motor do sistema: `pause()` pode fazer `speak` terminar antes do fim — repetimos o mesmo texto ao retomar.
  Future<void> _speakNormalizedChunkWithPauseResume(String normalizedText) async {
    var attempts = 0;
    while (mounted && _isPlaying && attempts < 16) {
      if (_pendingSkipForwardChunk) return;
      attempts++;
      var utteranceNaturallyCompleted = false;
      _tts.setCompletionHandler(() {
        utteranceNaturallyCompleted = true;
      });

      try {
        await _tts.speak(normalizedText);
      } finally {
        _tts.setCompletionHandler(() {});
      }

      if (!mounted || !_isPlaying) return;

      /// Sem pausa aqui — apenas ceder ciclo ao motor (silêncios entre págs. ficam só no próprio texto).
      if (!_pendingSkipForwardChunk) {
        await Future<void>.delayed(Duration.zero);
      }

      if (_pendingSkipForwardChunk) return;

      // Com `awaitSpeakCompletion(true)`, o Future de `speak` já sincroniza com o fim
      // do áudio — mas o completion handler no Android falha muito; isso repetia o
      // mesmo trecho em loop. Se não estamos em pausa quando `speak` termina, tratar
      // como conclusão natural (pausa a meio mantém `completed` falso para repetir).
      final completed = utteranceNaturallyCompleted || !_paused;

      if (_paused) {
        _resumeCompleter = Completer<void>();
        await _resumeCompleter!.future;
        _resumeCompleter = null;
        if (!mounted || !_isPlaying) return;
        if (completed) return;
        continue;
      }

      if (completed) return;

      if (!_isPlaying) return;
    }
  }

  Future<void> _run() async {
    final keepAwake = !kIsWeb;
    if (keepAwake) {
      await WakelockPlus.enable();
      await VaultReadingAudio.ensurePlaybackSessionActive();
    }
    try {
      _clearSherpaPrefetchFutures();
      while (mounted && _isPlaying) {
        await _awaitReanchorIfAny();
        if (_pendingJumpChunk != null) {
          _chunkIndex = _pendingJumpChunk!.clamp(0, max(0, _queue.length - 1));
          _pendingJumpChunk = null;
          _clearSherpaPrefetchFutures();
        }
        await _ensureQueuedChunksExtendThrough(_chunkIndex + 1);
        if (_chunkIndex >= _queue.length) break;

        final g0 = _readingPrefetchGeneration;
        final c = _queue[_chunkIndex];
        final trimInChunk = _pendingSpeakStartInChunk ?? 0;
        _pendingSpeakStartInChunk = null;
        final active = _chunkTrimmedForPlayback(c, trimInChunk);
        if (active.text.trim().isEmpty) {
          _chunkIndex++;
          continue;
        }

        final nextPagePrep = _ensureNextReadingPageQueued(active.page);
        if (!mounted || !_isPlaying) break;

        await _syncViewerToReadingPage(active.page);
        if (!mounted || !_isPlaying) break;

        _applyChunkHighlightStartUi(active);

        try {
          if (isSherpaOffline) {
            var pref = trimInChunk > 0 ? null : _sherpaNextWav;
            _sherpaNextWav = null;

            if (pref == null &&
                trimInChunk == 0 &&
                _sherpaSpareWav != null &&
                _sherpaSpareForQueueIndex == _chunkIndex) {
              pref = _sherpaSpareWav;
              _sherpaSpareWav = null;
              _sherpaSpareForQueueIndex = null;
            }

            if (trimInChunk > 0) {
              _clearSherpaPrefetchFutures();
            }

            final usePrefetch = pref != null;
            if (mounted && _shouldUpdateReadAlongUi && !usePrefetch) {
              setState(() => _isGenerating = true);
            }

            String? wavPath;
            if (usePrefetch) {
              wavPath = await pref;
              await nextPagePrep;
            } else {
              final results = await Future.wait<Object?>([
                nextPagePrep,
                _prepareSherpaWavIfActive(active.text, g0),
              ]);
              wavPath = results[1] as String?;
            }

            if (mounted && _shouldUpdateReadAlongUi) {
              setState(() => _isGenerating = false);
            } else {
              _isGenerating = false;
            }

            if (wavPath == null) {
              if (!mounted || !_isPlaying) break;
              if (g0 != _readingPrefetchGeneration) continue;
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Não foi possível gerar áudio. Tente de novo ou use a voz do telemóvel.',
                    ),
                  ),
                );
              }
              break;
            }

            final gen1 = _readingPrefetchGeneration;
            final nextIdx = _chunkIndex + 1;
            if (nextIdx < _queue.length) {
              if (_sherpaSpareWav != null &&
                  _sherpaSpareForQueueIndex == nextIdx) {
                _sherpaNextWav = _sherpaSpareWav;
                _sherpaSpareWav = null;
                _sherpaSpareForQueueIndex = null;
                _attachSherpaSpareChain(_sherpaNextWav, nextIdx, gen1);
              } else {
                _scheduleSherpaPrefetchFromQueueIndex(nextIdx, gen1);
              }
            }

            await TtsService.instance.playPreparedWav(
              wavPath,
              volume: _playbackVolume,
              playbackSpeed: _wavPlaybackSpeed,
              mediaTitle: _notificationTitleForChunk(active),
              mediaAlbum: widget.item.displayName,
              mediaArtUri: _coverArtUri(),
            );
          } else {
            await _speakNormalizedChunkWithPauseResume(
              _normalizeTtsText(active.text),
            );
          }
        } catch (e) {
          if (mounted) setState(() => _isGenerating = false);
          if (isSherpaOffline) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('TTS offline: $e')),
              );
              setState(() {
                _isPlaying = false;
                _clearHighlight();
              });
            }
            return;
          }
        }

        if (!mounted || !_isPlaying) break;

        if (_pendingJumpChunk != null) {
          _bumpReadingPrefetchGen();
          _clearSherpaPrefetchFutures();
          _chunkIndex = _pendingJumpChunk!;
          _pendingJumpChunk = null;
          _pendingSkipForwardChunk = false;
          continue;
        }

        if (_pendingBackChunk) {
          _bumpReadingPrefetchGen();
          _clearSherpaPrefetchFutures();
          _chunkIndex = max(0, _chunkIndex - 1);
          _pendingBackChunk = false;
          _pendingSkipForwardChunk = false;
          continue;
        }

        if (_pendingSkipForwardChunk) {
          _bumpReadingPrefetchGen();
          _clearSherpaPrefetchFutures();
          _pendingSkipForwardChunk = false;
          widget.onPagePersist?.call(c.page - 1, totalPages: _totalPages);
          _chunkIndex++;
          continue;
        }

        widget.onPagePersist?.call(c.page - 1, totalPages: _totalPages);
        _chunkIndex++;
      }

      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isGenerating = false;
          _clearHighlight();
          if (_chunkIndex >= _queue.length) {
            _clearQueuedPlaybackState();
            _chunkIndex = 0;
          }
        });
      }
    } finally {
      if (keepAwake) {
        await WakelockPlus.disable();
      }
    }
  }

  // ─── Tap-to-jump ───

  Future<void> _jumpToCharOffset(int charOffset) async {
    final page = _currentPage;
    final readingPage = _readingPageFromQueue();
    final farFromQueue = readingPage != null && readingPage != page;
    final needsReanchor =
        !_queueHasChunksForPage(page) || farFromQueue;

    if (needsReanchor) {
      _reanchorInFlight = _reanchorPlaybackToPage(
        page,
        charOffset: charOffset,
        interruptIfPlaying: _isPlaying,
      );
      await _reanchorInFlight;
      _reanchorInFlight = null;
      if (!mounted) return;
      if (!_isPlaying) {
        unawaited(_play());
      }
      return;
    }

    if (_isPlaying) {
      _scheduleJumpToPageOffset(page, charOffset);
      _interruptChunkPlayback();
    } else {
      final target = _resolveJumpOnPage(page, charOffset);
      _chunkIndex = target.chunkIndex;
      _pendingSpeakStartInChunk =
          target.trimInChunk > 0 ? target.trimInChunk : null;
      unawaited(_play());
    }
  }

  // ─── Playback controls ───

  void _stopPlayback() {
    _completeResumeWaitIfAny();
    _paused = false;
    _cancelSherpaPipeline();
    _isPlaying = false;
    _pendingBackChunk = false;
    _pendingSkipForwardChunk = false;
    _pendingJumpChunk = null;
    _pendingSpeakStartInChunk = null;
    _pageTimelineScrubbing = false;
    _wavChunkPos = null;
    _wavChunkDur = null;
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stop());
    } else {
      unawaited(_tts.stop());
    }
    if (mounted) {
      setState(() {
        _isGenerating = false;
        _clearHighlight();
      });
    }
  }

  void _onPrevPage() {
    _stopPlayback();
    if (_currentPage <= 1) return;
    _clearQueuedPlaybackState();
    _chunkIndex = 0;
    final page = _currentPage - 1;
    setState(() => _currentPage = page);
    _persistPage();
    if (_pdfController.isReady) {
      unawaited(_pdfController.goToPage(pageNumber: page));
    }
  }

  void _onNextPage() {
    _stopPlayback();
    if (_totalPages == null || _currentPage >= _totalPages!) return;
    _clearQueuedPlaybackState();
    _chunkIndex = 0;
    final page = _currentPage + 1;
    setState(() => _currentPage = page);
    _persistPage();
    if (_pdfController.isReady) {
      unawaited(_pdfController.goToPage(pageNumber: page));
    }
  }

  void _onTogglePlayPause() {
    if (!_isPlaying) {
      unawaited(_play());
      return;
    }
    if (_paused) {
      setState(() => _paused = false);
      if (isSherpaOffline) {
        unawaited(TtsService.instance.resumeReadingPlayback());
      }
      _completeResumeWaitIfAny();
      return;
    }
    _cancelSherpaPipeline();
    setState(() => _paused = true);
    if (isSherpaOffline) {
      unawaited(TtsService.instance.pauseReadingPlayback());
    } else {
      unawaited(_pauseFlutterTtsForReadAloud());
    }
  }

  Future<void> _openVoiceSheet() async {
    var allVoices = <Map<String, String>>[];
    try {
      final raw = await _tts.getVoices;
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) {
            allVoices.add(
              e.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
            );
          }
        }
      }
    } catch (_) {}
    var voices =
        allVoices
            .where((v) => _isLocalePtBr(v['locale'] ?? v['Locale']))
            .toList()
          ..sort(
            (a, b) => (a['name'] ?? a['Name'] ?? '').compareTo(
              b['name'] ?? b['Name'] ?? '',
            ),
          );
    if (!mounted) return;
    final host = this;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.black,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.78,
              child: _ReadAloudVoiceModalContent(
                host: host,
                systemVoicesPtBr: voices,
                hadAnySystemVoice: allVoices.isNotEmpty,
                showOfflineSherpa: !kIsWeb,
              ),
            ),
          ),
        );
      },
    );
  }

  Duration _estimatedFlutterChunkDuration(_Chunk chunk) {
    final n = max(1, chunk.text.length);
    final rateFactor = (_speechRate / 0.45).clamp(0.48, 3.9);
    const baseCharsPerSec = 12.0;
    final secs =
        ((n / (baseCharsPerSec * rateFactor)).ceil()).clamp(3, 36000);
    return Duration(seconds: secs);
  }

  String _notificationTitleForChunk(_Chunk c) =>
      _mediaChunkTitle(c.text, c.page);

  Duration _estimatedSherpaChunkDuration(_Chunk chunk) {
    final n = max(1, chunk.text.length);
    final speed = _wavPlaybackSpeed.clamp(0.65, 1.75);
    const baseCharsPerSec = 14.0;
    final secs =
        ((n / (baseCharsPerSec * speed)).ceil()).clamp(2, 36000);
    return Duration(seconds: secs);
  }

  /// Trechos da página na fila + duração estimada (WAV real no trecho atual).
  ({List<int> indices, List<int> durationsMs, int totalMs}) _pageAudioTimeline(
    int pageNum,
  ) {
    final wavDurMs = _wavChunkDur?.inMilliseconds ?? 0;
    if (_cachedTimelinePage == pageNum &&
        _cachedTimelineIndices != null &&
        _cachedTimelineDurationsMs != null &&
        _cachedTimelineQueueLen == _queue.length &&
        _cachedTimelineChunkIndex == _chunkIndex &&
        _cachedTimelineWavDurMs == wavDurMs) {
      return (
        indices: _cachedTimelineIndices!,
        durationsMs: _cachedTimelineDurationsMs!,
        totalMs: _cachedTimelineTotalMs,
      );
    }

    final indices = <int>[];
    final durationsMs = <int>[];
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].page != pageNum) continue;
      indices.add(i);
      if (i == _chunkIndex && wavDurMs > 0) {
        durationsMs.add(wavDurMs);
      } else {
        durationsMs.add(_estimatedSherpaChunkDuration(_queue[i]).inMilliseconds);
      }
    }
    final totalMs = durationsMs.fold<int>(0, (a, b) => a + b);

    _cachedTimelinePage = pageNum;
    _cachedTimelineIndices = indices;
    _cachedTimelineDurationsMs = durationsMs;
    _cachedTimelineTotalMs = totalMs;
    _cachedTimelineQueueLen = _queue.length;
    _cachedTimelineChunkIndex = _chunkIndex;
    _cachedTimelineWavDurMs = wavDurMs;

    return (indices: indices, durationsMs: durationsMs, totalMs: totalMs);
  }

  int _pageTimelinePositionMs(int pageNum) {
    final t = _pageAudioTimeline(pageNum);
    if (t.indices.isEmpty || t.totalMs <= 0) return 0;
    var pos = 0;
    for (var k = 0; k < t.indices.length; k++) {
      final idx = t.indices[k];
      final dur = t.durationsMs[k];
      if (idx < _chunkIndex) {
        pos += dur;
      } else if (idx == _chunkIndex) {
        if (_pageTimelineScrubbing) {
          pos += (dur * _pageTimelineFraction).round();
        } else {
          final dm = _wavChunkDur?.inMilliseconds ?? 0;
          if (dm > 0) {
            pos += (_wavChunkPos ?? Duration.zero)
                .inMilliseconds
                .clamp(0, dm);
          }
        }
        break;
      }
    }
    return pos.clamp(0, t.totalMs);
  }

  double _livePageTimelineFraction() {
    if (_queue.isEmpty || _chunkIndex >= _queue.length) return 0;
    final page = _queue[_chunkIndex].page;
    final t = _pageAudioTimeline(page);
    if (t.totalMs <= 0) return 0;
    return (_pageTimelinePositionMs(page) / t.totalMs).clamp(0.0, 1.0);
  }

  Future<void> _commitPageTimelineScrub(double pageFrac) async {
    if (!mounted || !_isPlaying || _queue.isEmpty) return;
    if (_chunkIndex >= _queue.length) return;
    final commitToken = ++_scrubCommitToken;
    final page = _queue[_chunkIndex].page;
    final timeline = _pageAudioTimeline(page);
    if (timeline.indices.isEmpty || timeline.totalMs <= 0) return;

    final targetMs =
        (pageFrac.clamp(0.0, 1.0) * timeline.totalMs).round().clamp(
          0,
          timeline.totalMs,
        );
    var acc = 0;
    for (var k = 0; k < timeline.indices.length; k++) {
      final idx = timeline.indices[k];
      final dur = timeline.durationsMs[k];
      final end = acc + dur;
      final isLast = k == timeline.indices.length - 1;
      if (targetMs < end || isLast) {
        final within = (targetMs - acc).clamp(0, dur);

        if (idx == _chunkIndex &&
            (_wavChunkDur?.inMilliseconds ?? 0) > 0 &&
            VaultReadingAudio.isReady) {
          await VaultReadingAudio.handler?.seek(
            Duration(milliseconds: within),
          );
          if (!mounted || commitToken != _scrubCommitToken) return;
          _wavChunkPos = Duration(milliseconds: within);
          if (mounted && _shouldUpdateReadAlongUi) {
            final frac = dur <= 0 ? 0.0 : within / dur;
            setState(() {
              _applyReadHighlightChunkProgress(_queue[idx], frac);
            });
            if (_pdfController.isReady) {
              _pdfController.invalidate();
            }
          }
          return;
        }

        final c = _queue[idx];
        final frac = dur <= 0 ? 0.0 : within / dur;
        final trim = (c.text.length * frac).floor().clamp(0, c.text.length);
        final safeTrim = trim >= c.text.length ? max(0, c.text.length - 1) : trim;
        final charOffset = c.offsetInPage + safeTrim;

        if (_queue.length > _kQueueReanchorChunkThreshold ||
            (_queue.isNotEmpty &&
                (c.page < _queue.first.page || c.page > _queue.last.page))) {
          _cancelSherpaPipeline();
          _reanchorInFlight = _reanchorPlaybackToPage(
            c.page,
            charOffset: charOffset,
            interruptIfPlaying: true,
          );
          await _reanchorInFlight;
          _reanchorInFlight = null;
          return;
        }

        if (commitToken != _scrubCommitToken) return;
        _cancelSherpaPipeline();
        _pendingJumpChunk = idx;
        _pendingSpeakStartInChunk = safeTrim > 0 ? safeTrim : null;
        _interruptChunkPlayback();
        return;
      }
      acc = end;
    }
  }

  String _formatShortDuration(Duration d) {
    final totalMs = max(0, d.inMilliseconds);
    final totalSec = (totalMs + 500) ~/ 1000;
    final m = totalSec ~/ 60;
    final rs = totalSec % 60;
    return '$m:${rs.toString().padLeft(2, '0')}';
  }

  Widget _buildSpeechAndWavSpeedSliders(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        );
    final sliders = <Widget>[];
    if (!isSherpaOffline) {
      sliders.add(Text('Velocidade — voz do telemóvel', style: labelStyle));
      sliders.add(
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.8,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            min: 0.22,
            max: 0.92,
            value: _speechRate.clamp(0.22, 0.92),
            activeColor: cs.primary,
            onChanged: (v) async {
              final nv = v.clamp(0.22, 0.92);
              setState(() => _speechRate = nv);
              await _tts.setSpeechRate(nv);
              await _persistSpeechSpeeds();
            },
          ),
        ),
      );
    }
    if (isSherpaOffline && !kIsWeb) {
      sliders.add(Text('Velocidade — WAV (Vault offline)', style: labelStyle));
      sliders.add(
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.8,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            min: 0.65,
            max: 1.75,
            value: _wavPlaybackSpeed.clamp(0.65, 1.75),
            activeColor: cs.primary,
            onChanged: (v) async {
              final nv = v.clamp(0.65, 1.75);
              setState(() => _wavPlaybackSpeed = nv);
              await _persistSpeechSpeeds();
              if (VaultReadingAudio.isReady) {
                await VaultReadingAudio.handler?.setPlaybackSpeed(nv);
              }
            },
          ),
        ),
      );
    }
    if (sliders.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sliders,
      ),
    );
  }

  Widget _buildPlayingProgressStrip(BuildContext context) {
    if (!_viewerReady ||
        !_isPlaying ||
        _queue.isEmpty ||
        _chunkIndex >= _queue.length) {
      return const SizedBox.shrink();
    }
    final chunk = _queue[_chunkIndex];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    if (!isSherpaOffline) {
      final est = _estimatedFlutterChunkDuration(chunk);
      final estMs = est.inMilliseconds.clamp(1, 1 << 30);
      final elapsedMs =
          ((_flutterWordProgress * estMs).round()).clamp(0, estMs);
      final elapsed = Duration(milliseconds: elapsedMs);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trecho (aprox.) · pág. ${chunk.page}',
            style:
                Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          Text(
            'Para avançar/retroceder com precisão, use Vault offline '
            '(a voz do sistema não permite arrastar esta barra aqui).',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: muted.withValues(alpha: 0.85),
                  fontSize: 10.5,
                  height: 1.25,
                ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                _formatShortDuration(elapsed),
                style:
                    Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                  ),
                  child: Slider(
                    value: _flutterWordProgress.clamp(0.0, 1.0),
                    onChanged: null,
                  ),
                ),
              ),
              Text(
                _formatShortDuration(est),
                style:
                    Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
              ),
            ],
          ),
        ],
      );
    }

    if (!VaultReadingAudio.isReady) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'A iniciar serviço de leitura em segundo plano…',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: muted,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    final page = chunk.page;
    final timeline = _pageAudioTimeline(page);
    final totalMs = timeline.totalMs;
    final frac = (_pageTimelineScrubbing
            ? _pageTimelineFraction
            : _livePageTimelineFraction())
        .clamp(0.0, 1.0);
    final elapsedMs = totalMs <= 0 ? 0 : (frac * totalMs).round();
    final remainingMs = max(0, totalMs - elapsedMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Página $page · arraste para avançar ou voltar na leitura',
          style:
              Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              totalMs <= 0 ? '—' : _formatShortDuration(Duration(milliseconds: elapsedMs)),
              style:
                  Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 9),
                ),
                child: Slider(
                  value: frac,
                  onChangeStart:
                      totalMs <= 0
                          ? null
                          : (_) {
                            setState(() {
                              _pageTimelineScrubbing = true;
                              _pageTimelineFraction = _livePageTimelineFraction();
                            });
                          },
                  onChanged:
                      totalMs <= 0
                          ? null
                          : (v) {
                            _pageTimelineFraction = v.clamp(0.0, 1.0);
                            final now = DateTime.now();
                            if (_lastScrubUiTick != null &&
                                now.difference(_lastScrubUiTick!).inMilliseconds <
                                    _kScrubUiThrottleMs) {
                              return;
                            }
                            _lastScrubUiTick = now;
                            setState(() {});
                          },
                  onChangeEnd:
                      totalMs <= 0
                          ? (_) {
                            _lastScrubUiTick = null;
                            setState(() => _pageTimelineScrubbing = false);
                          }
                          : (v) async {
                            _scrubCommitToken++;
                            _lastScrubUiTick = null;
                            final target = v.clamp(0.0, 1.0);
                            setState(() => _pageTimelineScrubbing = false);
                            await _commitPageTimelineScrub(target);
                          },
                ),
              ),
            ),
            Text(
              totalMs <= 0
                  ? '—'
                  : _formatShortDuration(Duration(milliseconds: remainingMs)),
              style:
                  Theme.of(context).textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaybackBar(BuildContext context) {
    final tp = _totalPages;
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              cs.surfaceContainerHighest.withValues(alpha: 0.98),
              cs.surface.withValues(alpha: 1),
            ],
          ),
          border: Border(
            top: BorderSide(color: cs.outline.withValues(alpha: 0.38)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 28,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.volume_down_rounded,
                      color: cs.primary.withValues(alpha: 0.75),
                      size: 22,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 9,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 18,
                          ),
                        ),
                        child: Slider(
                          value: _playbackVolume.clamp(0.0, 1.0),
                          activeColor: cs.primary,
                          onChanged: (v) async {
                            setState(() => _playbackVolume = v);
                            await _applyPlaybackVolumeToEngines();
                            await _persistPlaybackVolume();
                          },
                        ),
                      ),
                    ),
                    Icon(
                      Icons.volume_up_rounded,
                      color: cs.primary.withValues(alpha: 0.75),
                      size: 22,
                    ),
                  ],
                ),
                if (_viewerReady && _loadError == null) ...[
                  const SizedBox(height: 10),
                  _buildSpeechAndWavSpeedSliders(context),
                  _buildPlayingProgressStrip(context),
                ],
                const SizedBox(height: 10),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.navPage,
                        icon: Icons.chevron_left_rounded,
                        tooltip: 'Página anterior',
                        onPressed: _currentPage > 1 ? _onPrevPage : null,
                      ),
                      const SizedBox(width: 8),
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.segmentSkip,
                        icon: Icons.replay_5_rounded,
                        tooltip: 'Voltar $_kReadingTimeSkipSeconds segundos',
                        onPressed:
                            _isPlaying
                                ? () => unawaited(
                                  _seekReadingSeconds(-_kReadingTimeSkipSeconds),
                                )
                                : null,
                      ),
                      const SizedBox(width: 12),
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.playPrimary,
                        icon: _isPlaying && !_paused
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        tooltip: !_isPlaying
                            ? 'Começar leitura'
                            : (_paused
                                ? 'Continuar leitura'
                                : 'Pausar leitura'),
                        onPressed: _onTogglePlayPause,
                      ),
                      const SizedBox(width: 12),
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.stop,
                        icon: Icons.stop_rounded,
                        tooltip: 'Parar',
                        onPressed: _isPlaying ? _stopPlayback : null,
                      ),
                      const SizedBox(width: 8),
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.segmentSkip,
                        icon: Icons.forward_5_rounded,
                        tooltip: 'Avançar $_kReadingTimeSkipSeconds segundos',
                        onPressed:
                            _isPlaying
                                ? () => unawaited(
                                  _seekReadingSeconds(_kReadingTimeSkipSeconds),
                                )
                                : null,
                      ),
                      const SizedBox(width: 8),
                      _PlaybackCircleButton(
                        kind: _PlaybackBtnKind.navPage,
                        icon: Icons.chevron_right_rounded,
                        tooltip: 'Página seguinte',
                        onPressed: tp != null && _currentPage < tp
                            ? _onNextPage
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _applyStickyComposer(PdfStickyComposerResult? r) async {
    if (r == null || !mounted) return;
    setState(() {
      if (r.createdNew) {
        _readingNotes.add(r.note);
      } else {
        final ix = _readingNotes.indexWhere((e) => e.id == r.note.id);
        if (ix >= 0) {
          _readingNotes[ix] = r.note;
        }
      }
    });
    await _persistReadingNotes();
  }

  Future<void> _peekSticky(ReadingNote n) async {
    await showPdfStickyPeekSheet(
      context: context,
      note: n,
      onEdit: () async {
        if (!mounted) return;
        final r = await pushPdfStickyComposer(
          context: context,
          libraryItemId: widget.item.id,
          pageNumber: n.pageNumber,
          anchorX: n.anchorX,
          anchorY: n.anchorY,
          existing: n,
          initialPaperArgb: n.paperArgb,
          initialTextArgb: n.textArgb,
          linkedPrepCharIndex: n.linkedPrepCharIndex,
        );
        await _applyStickyComposer(r);
      },
      onDeleted: () async {
        if (!mounted) return;
        setState(() {
          _readingNotes.removeWhere((e) => e.id == n.id);
        });
        await _persistReadingNotes();
      },
    );
  }

  void _offerAddStickyNote() {
    if (!_viewerReady || _loadError != null) return;
    if (_awaitingStickyLineTap) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
      setState(() => _awaitingStickyLineTap = false);
      return;
    }
    setState(() => _awaitingStickyLineTap = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(minutes: 3),
        content: const Text(
          'Toca na linha do texto onde queres ligar a nota de rodapé.',
        ),
        action: SnackBarAction(
          label: 'Cancelar',
          onPressed: () {
            if (!mounted) return;
            setState(() => _awaitingStickyLineTap = false);
          },
        ),
      ),
    );
  }

  Widget _readingStickiesOverlay() {
    if (!_viewerReady) return const SizedBox.shrink();
    final list =
        _readingNotes.where((n) => n.pageNumber == _currentPage).toList();
    return ValueListenableBuilder<Matrix4>(
      valueListenable: _pdfController,
      builder: (_, _, _) {
        return SizedBox.expand(
          key: _stickyStackLayerKey,
          child: PdfStickyNotesViewport(
            notesForCurrentPage: list,
            anchorNormalizedFor: _badgeNormalizedForSticky,
            onOpenNote: _peekSticky,
            onPersistNotes: _persistReadingNotes,
            beforeDragHoldDuration: Duration.zero,
            onDragMove: (trip) {
              final n = trip.$1;
              final d = trip.$2;
              final vp = trip.$3;
              final ni = _readingNotes.indexWhere((e) => e.id == n.id);
              if (ni < 0) return;
              final cur = _readingNotes[ni];
              final nx =
                  (cur.anchorX * vp.width + d.delta.dx) / vp.width;
              final ny =
                  (cur.anchorY * vp.height + d.delta.dy) / vp.height;
              setState(() {
                _readingNotes[ni] = cur.copyWith(
                  anchorX: nx.clamp(0.06, 0.94),
                  anchorY: ny.clamp(0.06, 0.93),
                );
              });
            },
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _awaitingStickyLineTap = false;
    _paused = false;
    _completeResumeWaitIfAny();
    _cancelSherpaPipeline();
    _vaultAudioStopSub?.cancel();
    _vaultSegmentSkipSub?.cancel();
    _wavProgressSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _persistLibraryBookmarkOnExit();
    _structuredByPage.clear();
    _pagesMaterializedIntoQueue.clear();
    _clearQueuedPlaybackState();
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stop());
    } else {
      unawaited(_tts.stop());
    }
    if (!kIsWeb) {
      unawaited(WakelockPlus.disable());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _totalPages;
    final initialPage =
        (widget.item.lastPageIndex + 1).clamp(1, 1 << 20);
    final surface = Theme.of(context).scaffoldBackgroundColor;

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _stopPlayback();
      },
      child: Scaffold(
        backgroundColor: surface,
        appBar: AppBar(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _subtitleForPdfAppBar(t),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                    ),
              ),
            ],
          ),
          actions: [
            if (_viewerReady && _loadError == null) ...[
              if (_isPlaying) ...[
                if (_isGenerating) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 22,
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.92),
                    ),
                  ),
              ],
              IconButton(
                tooltip:
                    'Marcadores — notas e grifos guardados neste PDF',
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: (!_viewerReady || _loadError != null)
                    ? null
                    : () => unawaited(_openReadingBookmarksSheet()),
              ),
              IconButton(
                tooltip: _awaitingStickyLineTap
                    ? 'Cancelar (premir de novo)'
                    : 'Nota de rodapé — liga ao texto ao tocar numa linha',
                icon: const Icon(Icons.sticky_note_2_rounded),
                onPressed:
                    (_viewerReady && _loadError == null)
                        ? _offerAddStickyNote
                        : null,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilledButton.tonalIcon(
                  onPressed: _openVoiceSheet,
                  icon: const Icon(Icons.record_voice_over_rounded, size: 20),
                  label: const Text('Voz'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        body: _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Erro: $_loadError',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  PdfViewer.file(
                    widget.item.filePath,
                    controller: _pdfController,
                    initialPageNumber: initialPage,
                    params: PdfViewerParams(
                      backgroundColor: Colors.black,
                      textSelectionParams: const PdfTextSelectionParams(),
                      customizeContextMenuItems: _customizePdfContextMenu,
                      pagePaintCallbacks: [
                        _paintSavedHighlights,
                        _paintReadAloudHighlight,
                      ],
                      onGeneralTap: _onPdfTap,
                      onDocumentChanged: (doc) {
                        if (doc == null) return;
                        final count = doc.pages.length;
                        setState(() {
                          _viewerReady = true;
                          _totalPages = count;
                          _currentPage = _currentPage.clamp(1, count);
                        });
                        _persistPage();
                      },
                      onPageChanged: (n) {
                        if (n == null || n == _currentPage) return;
                        final wasPlaying = _isPlaying;
                        final readingPage = _readingPageFromQueue();
                        if (!wasPlaying) {
                          _clearQueuedPlaybackState();
                          _chunkIndex = 0;
                        }
                        setState(() => _currentPage = n);
                        if (!wasPlaying) {
                          _persistPage();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            _maybeTrimStructuredTextCache();
                          });
                        } else if (readingPage != null &&
                            (n - readingPage).abs() > 1) {
                          _reanchorInFlight = _reanchorPlaybackToPage(
                            n,
                            interruptIfPlaying: true,
                          );
                        }
                      },
                    ),
                  ),
                  if (!_viewerReady)
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_viewerReady && !_isPlaying)
                    Positioned(
                      left: 16,
                      right: 16,
                      top: 10,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: LinearGradient(
                              colors: [
                                Colors.black.withValues(alpha: 0.72),
                                Colors.black.withValues(alpha: 0.52),
                              ],
                            ),
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.35),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 18,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.touch_app_rounded,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Toca no texto do PDF para ouvir a partir daí',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: Colors.white.withValues(
                                            alpha: 0.94,
                                          ),
                                          height: 1.25,
                                          fontWeight: FontWeight.w500,
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_viewerReady && _loadError == null)
                    Positioned.fill(
                      child: _readingStickiesOverlay(),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildPlaybackBar(context),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ReadAloudVoiceModalContent extends StatefulWidget {
  const _ReadAloudVoiceModalContent({
    required this.host,
    required this.systemVoicesPtBr,
    required this.hadAnySystemVoice,
    required this.showOfflineSherpa,
  });

  final _PdfReadingModeScreenState host;
  final List<Map<String, String>> systemVoicesPtBr;
  final bool hadAnySystemVoice;
  final bool showOfflineSherpa;

  @override
  State<_ReadAloudVoiceModalContent> createState() =>
      _ReadAloudVoiceModalContentState();
}

class _ReadAloudVoiceModalContentState
    extends State<_ReadAloudVoiceModalContent> {
  Set<String> _downloadedKeys = {};

  @override
  void initState() {
    super.initState();
    _loadDownloaded();
  }

  Future<void> _loadDownloaded() async {
    final keys = await PiperVoiceService.instance.downloadedVoiceKeys();
    if (!mounted) return;
    setState(() => _downloadedKeys = keys);
  }

  Future<void> _applySystemVoice(Map<String, String> v) async {
    await widget.host.applySystemVoiceFromModal(v);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _pickSherpa(String id) async {
    try {
      await widget.host.selectSherpaVoice(id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final msg = e is StateError ? e.message : '${e.runtimeType}: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 12),
          content: Text(msg, maxLines: 8),
        ),
      );
    }
  }

  void _openVoiceManager() {
    Navigator.of(context).pop();
    Navigator.of(widget.host.context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VoiceManagerScreen(),
      ),
    );
  }

  Widget _offlineSection() {
    final h = widget.host;
    final downloaded = _downloadedKeys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Vault — offline (Sherpa ONNX)',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: _openVoiceManager,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Gerir vozes', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (downloaded.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Nenhuma voz offline instalada. Toque em "Gerir vozes" para baixar.',
              style: TextStyle(
                color: AppTheme.ink.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
          )
        else
          for (final key in downloaded)
            _sherpaTile(
              id: key,
              title: _voiceDisplayName(key),
              selected: h.isSherpaOffline && h.sherpaVoiceId == key,
            ),
      ],
    );
  }

  String _voiceDisplayName(String key) {
    final parts = key.split('-');
    if (parts.length >= 2) {
      final speaker = parts[1].trim();
      final quality = parts.length >= 3 ? parts[2] : '';
      if (speaker.isEmpty) return '$key (offline)';
      final head = speaker.length == 1
          ? speaker.toUpperCase()
          : '${speaker[0].toUpperCase()}${speaker.substring(1)}';
      return '$head${quality.isNotEmpty ? ' — $quality' : ''} (offline)';
    }
    return key;
  }

  Widget _sherpaTile({
    required String id,
    required String title,
    String? subtitle,
    required bool selected,
  }) {
    return ListTile(
      textColor: AppTheme.ink,
      selectedColor: AppTheme.ink,
      selected: selected,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.muted.withValues(alpha: 0.95),
              ),
            ),
      trailing: selected
          ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary, size: 20)
          : null,
      onTap: () => _pickSherpa(id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              const Text(
                'Voz para ler',
                style: TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: AppTheme.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _buildMergedList()),
      ],
    );
  }

  Widget _buildMergedList() {
    final voices = widget.systemVoicesPtBr;
    final off = widget.showOfflineSherpa;
    final children = <Widget>[
      if (off) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _offlineSection(),
        ),
        const Divider(height: 1, color: AppTheme.muted),
        const SizedBox(height: 8),
      ],
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Telemóvel — português (Brasil)',
          style: TextStyle(color: AppTheme.muted, fontSize: 12),
        ),
      ),
    ];

    if (voices.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Text(
            !widget.hadAnySystemVoice
                ? 'Não foi possível listar vozes nesta plataforma. Configura a voz nas definições do sistema.'
                : 'Não há vozes de português (Brasil) instaladas. Nas definições: Idioma e introdução de texto → '
                    'Leitura de texto / síntese de voz → transferir vozes para português (Brasil).',
            style: const TextStyle(color: AppTheme.ink, height: 1.4),
          ),
        ),
      );
    } else {
      if (defaultTargetPlatform == TargetPlatform.android) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Som melhor: Definições → Idioma e introdução de texto → Leitura de texto → motor Google → '
              'dados de voz em português (Brasil) em alta qualidade.',
              style: TextStyle(
                color: AppTheme.ink.withValues(alpha: 0.85),
                height: 1.3,
                fontSize: 12,
              ),
            ),
          ),
        );
      }
      for (final v in voices) {
        final name = v['name'] ?? v['Name'] ?? '';
        final loc = v['locale'] ?? v['Locale'] ?? '';
        final sub = [
          loc,
          v['gender'],
        ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
        children.add(
          ListTile(
            textColor: AppTheme.ink,
            title: Text(
              name.isNotEmpty ? name : loc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: sub.isNotEmpty
                ? Text(
                    sub,
                    style:
                        const TextStyle(color: AppTheme.muted, fontSize: 12),
                  )
                : null,
            onTap: () => _applySystemVoice(v),
          ),
        );
      }
    }

    return ListView(
        padding: const EdgeInsets.only(bottom: 16), children: children);
  }
}

enum _PlaybackBtnKind { navPage, segmentSkip, playPrimary, stop }

class _PlaybackCircleButton extends StatelessWidget {
  const _PlaybackCircleButton({
    required this.kind,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final _PlaybackBtnKind kind;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = onPressed == null;

    var size = 46.0;
    var iconSize = 23.0;
    Gradient? gradient;
    Color bg = cs.surfaceContainerHighest;
    Color borderCol = cs.outline.withValues(alpha: 0.42);
    Color iconColor = cs.onSurface;
    List<BoxShadow>? shadows;

    switch (kind) {
      case _PlaybackBtnKind.navPage:
        bg = cs.surfaceContainerHigh;
        iconColor = cs.onSurface.withValues(alpha: 0.95);
        iconSize = 24;
        break;
      case _PlaybackBtnKind.segmentSkip:
        bg = cs.surfaceContainerHighest.withValues(alpha: 0.88);
        iconColor = cs.primary.withValues(alpha: 0.95);
        borderCol = cs.primary.withValues(alpha: 0.38);
        break;
      case _PlaybackBtnKind.playPrimary:
        size = 58;
        iconSize = 31;
        gradient = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary,
            cs.tertiary.withValues(alpha: 0.92),
          ],
        );
        iconColor = cs.onPrimary;
        borderCol = Colors.transparent;
        shadows = [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.48),
            blurRadius: 20,
            offset: const Offset(0, 9),
          ),
        ];
        break;
      case _PlaybackBtnKind.stop:
        bg = cs.error.withValues(alpha: 0.14);
        iconColor = cs.error;
        borderCol = cs.error.withValues(alpha: 0.42);
        break;
    }

    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: gradient,
        color: gradient == null ? bg : null,
        border: Border.all(
          color: borderCol,
          width: kind == _PlaybackBtnKind.playPrimary ? 0 : 1.25,
        ),
        boxShadow: shadows,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          splashColor: cs.primary.withValues(alpha: 0.22),
          highlightColor: cs.primary.withValues(alpha: 0.08),
          child: Icon(icon, color: iconColor, size: iconSize),
        ),
      ),
    );

    Widget child =
        Opacity(opacity: disabled ? 0.38 : 1, child: circle);

    if (tooltip != null && tooltip!.isNotEmpty) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}
