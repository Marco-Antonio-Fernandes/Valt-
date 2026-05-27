import 'dart:async';
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/library_item.dart';
import '../models/reading_book_annotations.dart';
import '../models/reading_highlight.dart';
import '../models/reading_note.dart';
import '../services/reading_notes_store.dart';
import '../widgets/pdf_sticky_notes.dart';
import '../widgets/reading_highlight_color_sheet.dart';
import '../widgets/reading_highlights_paint.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
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
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final ReadingNotesStore _readingNotesStore = ReadingNotesStore();
  final PdfViewerController _pdfController = PdfViewerController();

  int? _current;
  int? _docPageCount;
  var _docReady = false;

  List<ReadingNote> _readingNotes = [];
  List<ReadingHighlight> _readingHighlights = [];
  final Map<int, PdfPageText> _structuredByPage = {};

  bool get _stickiesEnabled => widget.item.format == BookFormat.pdf;

  static String _preparePageSourceText(String raw) {
    return raw.replaceAll(RegExp(r'\r\n'), '\n').trim();
  }

  @override
  void initState() {
    super.initState();
    _current = widget.item.lastPageIndex + 1;
    _docPageCount = widget.item.totalPages;
    if (_stickiesEnabled) {
      unawaited(_loadReadingNotes());
    }
  }

  @override
  void dispose() {
    _structuredByPage.clear();
    super.dispose();
  }

  Future<void> _loadReadingNotes() async {
    try {
      final pack = await _readingNotesStore.book(widget.item.id);
      if (!mounted) return;
      setState(() {
        _readingNotes = List<ReadingNote>.from(pack.notes);
        _readingHighlights = List<ReadingHighlight>.from(pack.highlights);
      });
    } catch (_) {}
  }

  Future<void> _persistReadingNotesDisk() async {
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

  Future<void> _applyComposer(PdfStickyComposerResult? r) async {
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
    await _persistReadingNotesDisk();
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
        );
        await _applyComposer(r);
      },
      onDeleted: () async {
        if (!mounted) return;
        setState(() {
          _readingNotes.removeWhere((e) => e.id == n.id);
        });
        await _persistReadingNotesDisk();
      },
    );
  }

  void _offerNewStickyNote() {
    if (!_stickiesEnabled || !_docReady || _current == null) return;
    final k = _readingNotes.where((n) => n.pageNumber == _current).length;
    final off = stickySpawnAnchorsNormalized(k);
    final pal = kPdfStickyPalettes[k % kPdfStickyPalettes.length];
    unawaited(
      pushPdfStickyComposer(
        context: context,
        libraryItemId: widget.item.id,
        pageNumber: _current!,
        anchorX: off.dx,
        anchorY: off.dy,
        initialPaperArgb: pal.$1,
        initialTextArgb: pal.$2,
      ).then((r) => _applyComposer(r)),
    );
  }

  List<ReadingNote> _notesOnCurrentPdfPage() {
    if (_current == null) return const [];
    return _readingNotes.where((n) => n.pageNumber == _current!).toList();
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

  void _paintStoredHighlights(
    ui.Canvas canvas,
    Rect pageRect,
    PdfPage page,
  ) {
    paintReadingHighlightsOnPdfPage(
      canvas: canvas,
      pageRect: pageRect,
      page: page,
      highlights: _readingHighlights,
      structuredByPage: _structuredByPage,
    );
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
    final picked = await showReadingHighlightColorPicker(context);
    await delegate.clearTextSelection();
    if (!mounted) return;
    if (_pdfController.isReady) {
      _pdfController.invalidate();
    }
    if (picked == null) return;

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
        content: Text(
          added == 1 ? 'Grifo guardado.' : '$added grifos guardados.',
        ),
      ),
    );
    await _persistReadingNotesDisk();
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
    final range =
        PdfPageTextRange(pageText: structured, start: s, end: e);
    final b = range.bounds;
    try {
      if (_current != h.pageNumber) {
        setState(() => _current = h.pageNumber);
        widget.onPagePersist(
          h.pageNumber - 1,
          totalPages: _docPageCount,
        );
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

  Widget _bookmarksSectionHeader(
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

  Future<void> _openReaderBookmarksSheet() async {
    await _loadReadingNotes();
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
                                  _bookmarksSectionHeader(
                                    ctx,
                                    Icons.sticky_note_2_rounded,
                                    'Recados',
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
                                        if (!_pdfController.isReady) return;
                                        setState(() => _current = n.pageNumber);
                                        widget.onPagePersist(
                                          n.pageNumber - 1,
                                          totalPages: _docPageCount,
                                        );
                                        await _pdfController.goToPage(
                                          pageNumber: n.pageNumber,
                                        );
                                        if (mounted) {
                                          await _peekSticky(n);
                                        }
                                      },
                                    );
                                  }),
                                ],
                                if (sortedHl.isNotEmpty) ...[
                                  _bookmarksSectionHeader(
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
                                        'Pág. ${h.pageNumber} · grifo colorido · tocar para ir ao texto',
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'Apagar',
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          color:
                                              Theme.of(ctx).colorScheme.error,
                                        ),
                                        onPressed: () async {
                                          if (!mounted) return;
                                          setState(() {
                                            _readingHighlights.removeWhere(
                                                (e) => e.id == h.id);
                                          });
                                          await _persistReadingNotesDisk();
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

  @override
  Widget build(BuildContext context) {
    final initial = (widget.item.lastPageIndex + 1).clamp(1, 1 << 20);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && _current != null) {
          widget.onPagePersist(
            _current! - 1,
            totalPages: _docPageCount,
          );
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.item.displayName),
              if (_current != null)
                Text(
                  'Página $_current',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                ),
            ],
          ),
          actions: [
            if (_stickiesEnabled && _docReady && _current != null) ...[
              IconButton(
                tooltip:
                    'Marcadores — notas e grifos neste livro',
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: () => unawaited(_openReaderBookmarksSheet()),
              ),
              IconButton(
                tooltip: 'Nota nesta página',
                icon: const Icon(Icons.sticky_note_2_rounded),
                onPressed: _offerNewStickyNote,
              ),
            ],
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            PdfViewer.file(
              widget.item.filePath,
              controller: _pdfController,
              initialPageNumber: initial,
              params: PdfViewerParams(
                backgroundColor: Colors.black,
                textSelectionParams: const PdfTextSelectionParams(),
                customizeContextMenuItems: _customizePdfContextMenu,
                pagePaintCallbacks: [_paintStoredHighlights],
                onDocumentChanged: (doc) {
                  if (doc != null) {
                    final t = doc.pages.length;
                    setState(() {
                      _docPageCount = t;
                      _docReady = true;
                    });
                    _structuredByPage.clear();
                    if (_current != null) {
                      widget.onPagePersist(
                        _current! - 1,
                        totalPages: t,
                      );
                    }
                  } else {
                    setState(() {
                      _docReady = false;
                      _structuredByPage.clear();
                    });
                  }
                },
                onPageChanged: (n) {
                  if (n != null) {
                    setState(() => _current = n);
                    widget.onPagePersist(
                      n - 1,
                      totalPages: _docPageCount,
                    );
                  }
                },
              ),
            ),
            if (_stickiesEnabled && _docReady && _current != null)
              Positioned.fill(
                child: PdfStickyNotesViewport(
                  notesForCurrentPage: _notesOnCurrentPdfPage(),
                  anchorNormalizedFor: (n) => Offset(n.anchorX, n.anchorY),
                  beforeDragHoldDuration: Duration.zero,
                  onOpenNote: _peekSticky,
                  onPersistNotes: _persistReadingNotesDisk,
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
              ),
            if (widget.nextIssue != null &&
                widget.onOpenNext != null &&
                _current != null &&
                _docPageCount != null &&
                _current! >= _docPageCount!)
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
