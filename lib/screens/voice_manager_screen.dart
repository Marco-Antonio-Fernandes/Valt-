import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/piper_voice.dart';
import '../services/piper_voice_service.dart';
import '../services/tts_service.dart' show TtsService;

class VoiceManagerScreen extends StatefulWidget {
  const VoiceManagerScreen({super.key});

  @override
  State<VoiceManagerScreen> createState() => _VoiceManagerScreenState();
}

class _VoiceManagerScreenState extends State<VoiceManagerScreen> {
  final _svc = PiperVoiceService.instance;

  List<PiperVoice>? _allVoices;
  Set<String> _downloaded = {};
  String? _error;
  bool _loading = true;

  /// Language families extracted from voice list.
  List<String> _langFamilies = [];
  String _selectedLang = '';

  StreamSubscription<Map<String, VoiceDownloadProgress>>? _progressSub;
  Map<String, VoiceDownloadProgress> _progress = {};

  @override
  void initState() {
    super.initState();
    _progressSub = _svc.progressStream.listen((m) {
      if (!mounted) return;
      setState(() => _progress = m);
    });
    _progress = Map.of(_svc.currentProgress);
    _load();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _svc.listVoices(),
        _svc.downloadedVoiceKeys(),
      ]);
      if (!mounted) return;
      final voices = results[0] as List<PiperVoice>;
      final downloaded = results[1] as Set<String>;

      final families = <String>{};
      for (final v in voices) {
        if (v.language.family.isNotEmpty) families.add(v.language.family);
      }
      final sorted = families.toList()..sort();

      setState(() {
        _allVoices = voices;
        _downloaded = downloaded;
        _langFamilies = sorted;
        if (_selectedLang.isEmpty || !sorted.contains(_selectedLang)) {
          _selectedLang = sorted.contains('pt') ? 'pt' : (sorted.isNotEmpty ? sorted.first : '');
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<PiperVoice> get _filteredVoices {
    if (_allVoices == null) return [];
    if (_selectedLang.isEmpty) return _allVoices!;
    return _allVoices!.where((v) => v.language.family == _selectedLang).toList();
  }

  Future<void> _refreshDownloaded() async {
    final d = await _svc.downloadedVoiceKeys();
    if (!mounted) return;
    setState(() => _downloaded = d);
  }

  Future<void> _download(PiperVoice voice) async {
    try {
      await _svc.downloadVoice(voice);
      await _refreshDownloaded();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao baixar "${voice.key}": $e')),
      );
      await _refreshDownloaded();
    }
  }

  Future<void> _delete(PiperVoice voice) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar voz?'),
        content: Text(
          'Eliminar "${voice.displayName}" do dispositivo? '
          'Pode baixar de novo quando quiser.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _svc.deleteVoice(voice.key);
    await _refreshDownloaded();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vozes Piper'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recarregar',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 48, color: cs.error),
              const SizedBox(height: 16),
              Text(
                'Não foi possível carregar as vozes',
                style: TextStyle(color: cs.onSurface, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tentar de novo'),
              ),
            ],
          ),
        ),
      );
    }

    final voices = _filteredVoices;

    return Column(
      children: [
        if (_langFamilies.length > 1) _buildLangChips(cs),
        Expanded(
          child: voices.isEmpty
              ? Center(
                  child: Text(
                    'Nenhuma voz para "$_selectedLang".',
                    style: const TextStyle(color: AppTheme.muted),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    itemCount: voices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final v = voices[i];
                      final isBundled =
                          TtsService.bundledVoiceKeys.contains(v.key.toLowerCase());
                      return _VoiceCard(
                        voice: v,
                        isDownloaded: _downloaded
                            .contains(v.key.toLowerCase().trim()),
                        isBundled: isBundled,
                        progress: _progress[v.key],
                        onDownload: () => _download(v),
                        onCancel: () => _svc.cancelDownload(v.key),
                        onDelete: isBundled ? null : () => _delete(v),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildLangChips(ColorScheme cs) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _langFamilies.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final lang = _langFamilies[i];
          final selected = lang == _selectedLang;
          // ChoiceChip (não FilterChip): só um idioma ativo; avoid onSelected(false)
          // com estado desatualizado ao retocar o mesmo chip (podia encerrar/assert).
          return ChoiceChip(
            label: Text(lang.toUpperCase()),
            selected: selected,
            onSelected: (bool value) {
              if (!mounted || !value) return;
              setState(() => _selectedLang = lang);
            },
            selectedColor: cs.primaryContainer,
            labelStyle: TextStyle(
              color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 13,
            ),
            side: BorderSide(
              color:
                  selected ? cs.primary.withValues(alpha: 0.5) : cs.outline.withValues(alpha: 0.3),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          );
        },
      ),
    );
  }
}

class _VoiceCard extends StatelessWidget {
  const _VoiceCard({
    required this.voice,
    required this.isDownloaded,
    this.isBundled = false,
    this.progress,
    required this.onDownload,
    required this.onCancel,
    this.onDelete,
  });

  final PiperVoice voice;
  final bool isDownloaded;
  final bool isBundled;
  final VoiceDownloadProgress? progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;

  bool get _isDownloading =>
      progress != null &&
      progress!.status == VoiceDownloadStatus.downloading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isBundled || isDownloaded
                      ? Icons.record_voice_over_rounded
                      : Icons.voice_over_off_rounded,
                  color: isBundled || isDownloaded ? cs.tertiary : AppTheme.muted,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        voice.displayName,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${voice.language.code} · ${voice.quality}'
                        '${voice.totalBytes > 0 ? ' · ${(voice.totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB' : ''}',
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _actionButton(cs),
              ],
            ),
            if (_isDownloading) ...[
              const SizedBox(height: 12),
              _ProgressBar(progress: progress!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionButton(ColorScheme cs) {
    if (_isDownloading) {
      return IconButton(
        onPressed: onCancel,
        icon: Icon(Icons.close_rounded, color: cs.error),
        tooltip: 'Cancelar',
      );
    }
    if (isBundled || isDownloaded) {
      final label = isBundled ? 'Incluída' : 'Instalada';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.tertiary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: cs.tertiary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded,
                  color: cs.error.withValues(alpha: 0.7), size: 20),
              tooltip: 'Apagar voz',
            ),
          ],
        ],
      );
    }
    return FilledButton.icon(
      onPressed: onDownload,
      icon: const Icon(Icons.download_rounded, size: 18),
      label: const Text('Baixar'),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});
  final VoiceDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final frac = progress.fraction;
    final mb = progress.received / (1024 * 1024);
    final totalMb = progress.total / (1024 * 1024);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress.total > 0 ? frac : null,
            minHeight: 6,
            backgroundColor: cs.outline.withValues(alpha: 0.3),
            valueColor: AlwaysStoppedAnimation(cs.primary),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          progress.total > 0
              ? '${mb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB  (${(frac * 100).toStringAsFixed(0)}%)'
              : '${mb.toStringAsFixed(1)} MB baixados…',
          style: const TextStyle(color: AppTheme.muted, fontSize: 11),
        ),
      ],
    );
  }
}
