import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/library_item.dart';
import '../services/comic_page_source.dart';
import '../services/rar7_util.dart';

class ComicReaderScreen extends StatefulWidget {
  const ComicReaderScreen({
    super.key,
    required this.item,
    required this.onPagePersist,
    this.nextIssue,
    this.onOpenNext,
  });

  final LibraryItem item;
  final void Function(int lastPageIndex, {int? totalPages}) onPagePersist;
  final LibraryItem? nextIssue;
  final VoidCallback? onOpenNext;

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> {
  ComicPageSource? _source;
  Object? _error;
  bool _loading = true;
  final Map<int, Future<Uint8List>> _futures = {};
  late final PageController _pageController;
  int _index = 0;
  int? _pageCount;

  @override
  void initState() {
    super.initState();
    _index = widget.item.lastPageIndex;
    _pageController = PageController(initialPage: _index);
    _open();
  }

  Future<void> _open() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    _futures.clear();
    try {
      final s = await ComicPageSource.open(widget.item);
      if (!mounted) return;
      final clamped = _index.clamp(0, s.pageCount - 1);
      setState(() {
        _source = s;
        _index = clamped;
        _pageCount = s.pageCount;
        _loading = false;
      });
      widget.onPagePersist(clamped, totalPages: s.pageCount);
      if (clamped > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(clamped);
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<Uint8List> _page(int i) {
    final s = _source;
    if (s == null) {
      return Future.error(StateError('no source'));
    }
    _prefetchAround(i);
    return _futures.putIfAbsent(i, () => s.pageAt(i));
  }

  void _prefetchAround(int center) {
    final s = _source;
    if (s == null) return;
    for (var d = 1; d <= 3; d++) {
      final next = center + d;
      final prev = center - d;
      if (next < s.pageCount) {
        _futures.putIfAbsent(next, () => s.pageAt(next));
      }
      if (prev >= 0) {
        _futures.putIfAbsent(prev, () => s.pageAt(prev));
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        backgroundColor: AppTheme.black,
        appBar: AppBar(
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          title: Text(widget.item.displayName),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: c.primary, strokeWidth: 2.5),
              const SizedBox(height: 16),
              Text(
                'A abrir…',
                style: TextStyle(color: c.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: AppTheme.black,
        appBar: AppBar(
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          title: Text(widget.item.displayName),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 56, color: c.error),
                const SizedBox(height: 16),
                Text(
                  'Não foi possível abrir',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.onSurfaceVariant, fontSize: 13),
                ),
                const SizedBox(height: 28),
                if (Platform.isWindows) ...[
                  FilledButton.icon(
                    onPressed: () async {
                      await open7zDownloadPage();
                    },
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Baixar 7-Zip (grátis)'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      setState(() {
                        _error = null;
                        _loading = true;
                      });
                      final ok = await tryAutoInstall7z();
                      if (!mounted) return;
                      if (ok) {
                        _open();
                      } else {
                        setState(() {
                          _loading = false;
                          _error = ComicOpenError(
                            'winget não conseguiu instalar o 7-Zip automaticamente.\n'
                            'Baixa manualmente em https://www.7-zip.org e reinicia.',
                          );
                        });
                      }
                    },
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    label: const Text('Instalar via winget'),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Tentar novamente'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final src = _source!;
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          widget.onPagePersist(_index, totalPages: _pageCount);
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.black,
        appBar: AppBar(
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          title: Text('${widget.item.displayName} • ${_index + 1}/${src.pageCount}'),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: src.pageCount,
              onPageChanged: (i) {
                setState(() => _index = i);
                widget.onPagePersist(i, totalPages: _pageCount);
              },
              itemBuilder: (context, i) {
                return FutureBuilder<Uint8List>(
                  future: _page(i),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return InteractiveViewer(
                      minScale: 0.25,
                      maxScale: 8,
                      child: Center(
                        child: Image.memory(
                          snap.data!,
                          fit: BoxFit.contain,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            if (widget.nextIssue != null &&
                widget.onOpenNext != null &&
                _index >= src.pageCount - 1)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: SafeArea(
                  child: FilledButton.icon(
                    onPressed: widget.onOpenNext,
                    icon: const Icon(Icons.navigate_next_rounded),
                    label: Text(
                      'Próximo · ${widget.nextIssue!.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
