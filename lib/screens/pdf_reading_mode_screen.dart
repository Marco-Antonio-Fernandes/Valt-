import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../models/library_item.dart';
import '../services/tts_service.dart';

const _kVoicePrefsKey = 'read_aloud_voice_json';
const _kReadAloudEngine = 'read_aloud_engine';
const _kSherpaOfflineVoice = 'offline_sherpa_voice_id';
const _kReadAloudVolume = 'read_aloud_playback_volume';
const _defaultVoiceLocale = 'pt-BR';
const _readAloudBlue = Color(0xFF1565C0);
const _highlightBg = Color(0xFF5B4A1E);
const _highlightFg = Color(0xFFFFF8E1);

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

class _PdfReadingModeScreenState extends State<PdfReadingModeScreen> {
  final FlutterTts _tts = FlutterTts();
  PdfDocument? _doc;
  int _currentPage = 1;
  int? _totalPages;
  var _pageText = '';
  var _pagePlain = '';
  var _loadingDoc = true;
  String? _loadError;
  var _isPlaying = false;
  var _autoContinue = true;
  final List<_Chunk> _queue = [];
  int _chunkIndex = 0;
  int? _hlStart;
  int? _hlEnd;
  final ScrollController _scrollController = ScrollController();
  final _textKey = GlobalKey();

  var _playbackVolume = 1.0;
  var _pendingBackChunk = false;
  int? _pendingJumpChunk;
  var _isGenerating = false;

  var _readAloudEngine = 'system';
  var _sherpaOfflineVoice = 'miro';

  bool get isSherpaOffline => _readAloudEngine == 'sherpa' && !kIsWeb;
  String get sherpaVoiceId => _sherpaOfflineVoice;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrapTts());
    unawaited(_loadDocument());
  }

  Future<void> _bootstrapTts() async {
    await _migrateLegacyReadAloudPrefs();
    final p = await SharedPreferences.getInstance();
    _readAloudEngine = p.getString(_kReadAloudEngine) ?? 'system';
    if (kIsWeb && _readAloudEngine == 'sherpa') {
      _readAloudEngine = 'system';
    }
    final sv =
        (p.getString(_kSherpaOfflineVoice) ?? 'miro').toLowerCase().trim();
    if (sv == 'faber') {
      _sherpaOfflineVoice = 'miro';
      await p.setString(_kSherpaOfflineVoice, 'miro');
    } else if (const {'miro', 'dii'}.contains(sv)) {
      _sherpaOfflineVoice = sv;
    }
    _playbackVolume = (p.getDouble(_kReadAloudVolume) ?? 1.0).clamp(0.0, 1.0);
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

  void _interruptChunkPlayback() {
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stop());
    } else {
      unawaited(_tts.stop());
    }
  }

  void _seekPreviousSegment() {
    if (!_isPlaying || _chunkIndex <= 0) return;
    _pendingBackChunk = true;
    _interruptChunkPlayback();
  }

  void _seekNextSegment() {
    if (!_isPlaying) return;
    _interruptChunkPlayback();
  }

  Future<void> selectSherpaVoice(String id) async {
    final normalized = id.toLowerCase().trim();
    if (!const {'miro', 'dii'}.contains(normalized)) return;

    final wasPlaying = _isPlaying;
    if (wasPlaying) _stopPlayback();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kReadAloudEngine, 'sherpa');
    await prefs.setString(_kSherpaOfflineVoice, normalized);

    if (_sherpaOfflineVoice != normalized) {
      TtsService.instance.dispose();
    }

    if (!mounted) return;
    setState(() {
      _readAloudEngine = 'sherpa';
      _sherpaOfflineVoice = normalized;
    });

    _queue.clear();
    _chunkIndex = 0;
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
    _queue.clear();
    _chunkIndex = 0;
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

  Future<void> _initSystemTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(_playbackVolume.clamp(0.0, 1.0));
    if (!kIsWeb && !isSherpaOffline) {
      _tts.setProgressHandler((_, startOffset, endOffset, _) {
        if (!mounted) return;
        if (_queue.isEmpty || _chunkIndex >= _queue.length) return;
        final chunk = _queue[_chunkIndex];
        final len = _pagePlain.length;
        if (len == 0) return;
        var a = chunk.offsetInPage + startOffset;
        var b = chunk.offsetInPage + endOffset;
        if (a < 0) a = 0;
        if (b > len) b = len;
        if (a > b) return;
        setState(() {
          _hlStart = a;
          _hlEnd = b;
        });
        _scrollHighlightIntoView();
      });
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

  void _clearHighlight() {
    _hlStart = null;
    _hlEnd = null;
  }

  void _scrollHighlightIntoView() {
    if (!mounted) return;
    if (_hlStart == null || _hlStart! > _pagePlain.length) return;
    if (!_scrollController.hasClients) return;
    const lineHeight = 24.0;
    const pad = 80.0;
    final pos = min(_hlStart!, _pagePlain.length);
    final y = min(
      (lineHeight * (_pagePlain.substring(0, pos).split('\n').length - 1)) +
          pad,
      max(0.0, _scrollController.position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          y,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _loadDocument() async {
    try {
      final doc = await PdfDocument.openFile(widget.item.filePath);
      if (!mounted) {
        unawaited(doc.dispose());
        return;
      }
      setState(() {
        _doc = doc;
        _totalPages = doc.pages.length;
        _currentPage = (widget.item.lastPageIndex + 1).clamp(
          1,
          doc.pages.length,
        );
        _loadingDoc = false;
      });
      _persistPage();
      await _loadPageText(_currentPage);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingDoc = false;
          _loadError = e.toString();
        });
      }
    }
  }

  Future<String> _textForPage(int pageNum) async {
    final doc = _doc;
    if (doc == null || pageNum < 1 || pageNum > doc.pages.length) return '';
    var page = doc.pages[pageNum - 1];
    if (!page.isLoaded) page = await page.ensureLoaded();
    final raw = await page.loadText();
    return (raw?.fullText ?? '').replaceAll('\r\n', '\n').trim();
  }

  Future<void> _loadPageText(int pageNum) async {
    if (!mounted) return;
    setState(() => _pageText = '…');
    final t = await _textForPage(pageNum);
    if (!mounted) return;
    setState(() {
      if (t.isEmpty) {
        _pageText = '(Sem texto selecionável nesta página.)';
        _pagePlain = '';
        _clearHighlight();
      } else {
        _pageText = t;
        _pagePlain = t;
        _clearHighlight();
      }
    });
  }

  /// Divide texto em segmentos respeitando fronteiras de frase.
  /// [maxLen] menor (ex. 400) para Sherpa → geração mais rápida + highlight fluido.
  static List<({String text, int start})> _splitTtsWithOffsets(
    String t, {
    int maxLen = 3000,
  }) {
    if (t.isEmpty) return [];
    if (t.length <= maxLen) return [(text: t, start: 0)];
    final out = <({String text, int start})>[];
    var i = 0;
    while (i < t.length) {
      var end = (i + maxLen) > t.length ? t.length : (i + maxLen);
      if (end < t.length) {
        var cut = t.lastIndexOf('\n\n', end);
        if (cut <= i) cut = t.lastIndexOf('. ', end);
        if (cut <= i) cut = t.lastIndexOf('! ', end);
        if (cut <= i) cut = t.lastIndexOf('? ', end);
        if (cut <= i) cut = t.lastIndexOf('\n', end);
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

  Future<void> _fillQueue({int? fromPage}) async {
    _queue.clear();
    final start = fromPage ?? _currentPage;
    final end = _autoContinue ? (_totalPages ?? 0) : start;
    final chunkMax = isSherpaOffline ? 400 : 3000;
    for (var p = start; p <= end; p++) {
      if (!mounted) return;
      final t = (await _textForPage(p)).trim();
      if (t.isEmpty) continue;
      for (final part in _splitTtsWithOffsets(t, maxLen: chunkMax)) {
        _queue.add(_Chunk(p, part.text, part.start));
      }
    }
  }

  Future<void> _play() async {
    if (_isPlaying) return;
    if (_queue.isNotEmpty && _chunkIndex < _queue.length) {
      // continuar a mesma fila
    } else {
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

    if (isSherpaOffline) {
      await TtsService.instance.ensureBundlesAndInit(_sherpaOfflineVoice);
    }

    if (!mounted) return;
    setState(() {
      _isPlaying = true;
      _clearHighlight();
    });
    await _run();
  }

  Future<void> _run() async {
    while (mounted && _isPlaying && _chunkIndex < _queue.length) {
      final c = _queue[_chunkIndex];
      if (c.page != _currentPage) {
        setState(() => _currentPage = c.page);
        _persistPage();
        await _loadPageText(_currentPage);
      }
      if (!mounted || !_isPlaying) return;

      // Destacar o trecho inteiro que vai ser lido
      if (mounted) {
        setState(() {
          _hlStart = c.offsetInPage;
          _hlEnd = c.offsetInPage + c.text.length;
        });
        _scrollHighlightIntoView();
      }

      try {
        if (isSherpaOffline) {
          if (mounted) setState(() => _isGenerating = true);
          await TtsService.instance.speak(c.text, volume: _playbackVolume);
          if (mounted) setState(() => _isGenerating = false);
        } else {
          await _tts.speak(c.text);
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

      if (!mounted || !_isPlaying) return;

      if (_pendingJumpChunk != null) {
        _chunkIndex = _pendingJumpChunk!;
        _pendingJumpChunk = null;
        continue;
      }

      if (_pendingBackChunk) {
        _chunkIndex = max(0, _chunkIndex - 1);
        _pendingBackChunk = false;
        continue;
      }

      _chunkIndex++;
    }
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _isGenerating = false;
        _clearHighlight();
        if (_chunkIndex >= _queue.length) {
          _queue.clear();
          _chunkIndex = 0;
        }
      });
    }
  }

  // ─── Tap-to-jump ───

  void _handleTextTap(TapUpDetails details) {
    final ro = _textKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph) return;
    final local = ro.globalToLocal(details.globalPosition);
    final pos = ro.getPositionForOffset(local);
    _jumpToCharOffset(pos.offset);
  }

  void _jumpToCharOffset(int charOffset) {
    if (_pagePlain.isEmpty) return;

    // Se a fila já tem chunks da página atual, procurar o chunk certo
    int? targetChunk;
    for (var i = 0; i < _queue.length; i++) {
      final c = _queue[i];
      if (c.page != _currentPage) continue;
      if (charOffset >= c.offsetInPage &&
          charOffset < c.offsetInPage + c.text.length) {
        targetChunk = i;
        break;
      }
    }

    if (_isPlaying && targetChunk != null) {
      _pendingJumpChunk = targetChunk;
      _interruptChunkPlayback();
    } else if (targetChunk != null) {
      _chunkIndex = targetChunk;
      unawaited(_play());
    } else {
      unawaited(_startPlayingFromOffset(charOffset));
    }
  }

  Future<void> _startPlayingFromOffset(int charOffset) async {
    await _fillQueue();
    for (var i = 0; i < _queue.length; i++) {
      final c = _queue[i];
      if (c.page != _currentPage) continue;
      if (charOffset >= c.offsetInPage &&
          charOffset < c.offsetInPage + c.text.length) {
        _chunkIndex = i;
        break;
      }
    }
    if (!mounted) return;

    if (isSherpaOffline) {
      await TtsService.instance.ensureBundlesAndInit(_sherpaOfflineVoice);
    }

    setState(() {
      _isPlaying = true;
      _clearHighlight();
    });
    await _run();
  }

  // ─── Playback controls ───

  void _stopPlayback() {
    _isPlaying = false;
    _pendingBackChunk = false;
    _pendingJumpChunk = null;
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stopPlaybackOnly());
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
    _queue.clear();
    _chunkIndex = 0;
    setState(() => _currentPage--);
    _persistPage();
    unawaited(_loadPageText(_currentPage));
  }

  void _onNextPage() {
    _stopPlayback();
    if (_totalPages == null || _currentPage >= _totalPages!) return;
    _queue.clear();
    _chunkIndex = 0;
    setState(() => _currentPage++);
    _persistPage();
    unawaited(_loadPageText(_currentPage));
  }

  void _onTogglePlayPause() {
    if (_isPlaying) {
      _isPlaying = false;
      _pendingBackChunk = false;
      _pendingJumpChunk = null;
      if (isSherpaOffline) {
        unawaited(TtsService.instance.stopPlaybackOnly());
      } else {
        unawaited(_tts.stop());
      }
      if (mounted) setState(() => _isGenerating = false);
    } else {
      unawaited(_play());
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

  // ─── Build text widget com highlight + tap ───

  Widget _buildReadingText() {
    const baseStyle = TextStyle(color: AppTheme.ink, height: 1.5, fontSize: 16);
    const hiStyle = TextStyle(
      color: _highlightFg,
      height: 1.5,
      fontSize: 16,
      backgroundColor: _highlightBg,
      fontWeight: FontWeight.w600,
    );
    final full = _pagePlain;
    if (full.isEmpty) {
      return Text(_pageText, style: baseStyle);
    }

    final hs = _hlStart;
    final he = _hlEnd;

    final hasHighlight =
        hs != null && he != null && _isPlaying && hs < he && he <= full.length;

    List<InlineSpan> spans;
    if (hasHighlight) {
      final a = hs.clamp(0, full.length);
      final b = he.clamp(0, full.length);
      spans = [
        if (a > 0) TextSpan(text: full.substring(0, a), style: baseStyle),
        TextSpan(text: full.substring(a, b), style: hiStyle),
        if (b < full.length)
          TextSpan(text: full.substring(b), style: baseStyle),
      ];
    } else {
      spans = [TextSpan(text: full, style: baseStyle)];
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: _handleTextTap,
      child: RichText(
        key: _textKey,
        text: TextSpan(children: spans),
        softWrap: true,
      ),
    );
  }

  @override
  void dispose() {
    _persistPage();
    if (isSherpaOffline) {
      unawaited(TtsService.instance.stopPlaybackOnly());
    } else {
      unawaited(_tts.stop());
    }
    unawaited(_doc?.dispose() ?? Future.value());
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _totalPages;
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _stopPlayback();
      },
      child: Scaffold(
        backgroundColor: AppTheme.black,
        appBar: AppBar(
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          title: Text(
            widget.item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_loadingDoc && _loadError == null) ...[
              TextButton(onPressed: _openVoiceSheet, child: const Text('Voz')),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Págs.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
                Switch(
                  value: _autoContinue,
                  onChanged: (v) => setState(() => _autoContinue = v),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: _loadingDoc
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.ink,
                ),
              )
            : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Erro: $_loadError',
                        style:
                            const TextStyle(color: AppTheme.ink, height: 1.4),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Row(
                          children: [
                            if (t != null)
                              Text(
                                'Página $_currentPage de $t',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: AppTheme.muted),
                              ),
                            const Spacer(),
                            if (_isPlaying) ...[
                              if (_isGenerating) ...[
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: AppTheme.muted,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'A gerar…',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: AppTheme.muted),
                                ),
                              ] else ...[
                                const Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 16,
                                  color: AppTheme.muted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'A ler',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: AppTheme.ink),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                      // Slider de páginas
                      if (t != null && t > 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value: _currentPage.toDouble(),
                              min: 1,
                              max: t.toDouble(),
                              divisions: t > 1 ? t - 1 : null,
                              activeColor: _readAloudBlue,
                              label: '$_currentPage',
                              onChanged: (v) {
                                final page = v.round();
                                if (page == _currentPage) return;
                                _stopPlayback();
                                _queue.clear();
                                _chunkIndex = 0;
                                setState(() => _currentPage = page);
                                _persistPage();
                                unawaited(_loadPageText(page));
                              },
                            ),
                          ),
                        ),
                      // Dica de toque
                      if (!_isPlaying && _pagePlain.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'Toca no texto para começar a ler a partir daí',
                            style: TextStyle(
                              color: AppTheme.muted.withValues(alpha: 0.6),
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 4,
                          ),
                          child: _buildReadingText(),
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.volume_down_rounded,
                                    color: AppTheme.muted,
                                    size: 22,
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        thumbShape:
                                            const RoundSliderThumbShape(
                                              enabledThumbRadius: 8,
                                            ),
                                      ),
                                      child: Slider(
                                        value: _playbackVolume.clamp(0.0, 1.0),
                                        activeColor: _readAloudBlue,
                                        onChanged: (v) async {
                                          setState(() => _playbackVolume = v);
                                          await _applyPlaybackVolumeToEngines();
                                          await _persistPlaybackVolume();
                                        },
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.volume_up_rounded,
                                    color: AppTheme.muted,
                                    size: 22,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message: 'Página anterior',
                                      child: _RoundIconButton(
                                        color: AppTheme.black,
                                        borderColor: AppTheme.ink,
                                        onPressed: _currentPage > 1
                                            ? _onPrevPage
                                            : null,
                                        icon: Icons.chevron_left_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Trecho anterior',
                                      child: _RoundIconButton(
                                        color: AppTheme.black,
                                        borderColor: AppTheme.muted,
                                        onPressed: _isPlaying &&
                                                _chunkIndex > 0
                                            ? _seekPreviousSegment
                                            : null,
                                        icon: Icons.fast_rewind_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    _RoundIconButton(
                                      color: _readAloudBlue,
                                      onPressed: _onTogglePlayPause,
                                      icon: _isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                    const SizedBox(width: 6),
                                    _RoundIconButton(
                                      color: AppTheme.ink,
                                      onPressed:
                                          _isPlaying ? _stopPlayback : null,
                                      icon: Icons.stop_rounded,
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Próximo trecho',
                                      child: _RoundIconButton(
                                        color: AppTheme.black,
                                        borderColor: AppTheme.muted,
                                        onPressed:
                                            _isPlaying ? _seekNextSegment : null,
                                        icon: Icons.fast_forward_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Página seguinte',
                                      child: _RoundIconButton(
                                        color: AppTheme.black,
                                        borderColor: AppTheme.ink,
                                        onPressed:
                                            t != null && _currentPage < t
                                                ? _onNextPage
                                                : null,
                                        icon: Icons.chevron_right_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
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
    } catch (_) {}
  }

  Widget _offlineSection() {
    final h = widget.host;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Vault — offline PT-BR (Sherpa ONNX)',
          style: TextStyle(color: AppTheme.muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _sherpaTile(
          id: 'miro',
          title: 'Miro — alta',
          selected: h.isSherpaOffline && h.sherpaVoiceId == 'miro',
        ),
        _sherpaTile(
          id: 'dii',
          title: 'Dii — alta',
          selected: h.isSherpaOffline && h.sherpaVoiceId == 'dii',
        ),
        const SizedBox(height: 4),
        Text(
          'Modelos e espeak-ng-data em assets/tts/.',
          style: TextStyle(
            color: AppTheme.ink.withValues(alpha: 0.7),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _sherpaTile({
    required String id,
    required String title,
    required bool selected,
  }) {
    return ListTile(
      textColor: AppTheme.ink,
      selectedColor: AppTheme.ink,
      selected: selected,
      title: Text(title),
      trailing: selected
          ? Icon(Icons.check_rounded, color: _readAloudBlue, size: 20)
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

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.color,
    required this.onPressed,
    required this.icon,
    this.borderColor,
  });

  final Color color;
  final Color? borderColor;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final border = borderColor;
    if (border != null) {
      return Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Material(
          color: color,
          shape: CircleBorder(side: BorderSide(color: border, width: 1.2)),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            onPressed: onPressed,
            icon: Icon(icon, color: border, size: 28),
          ),
        ),
      );
    }
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          onPressed: onPressed,
          color: Colors.white,
          icon: Icon(icon, size: 32),
        ),
      ),
    );
  }
}
