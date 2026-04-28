import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_theme.dart';
import '../models/library_item.dart';
import '../models/saga.dart';
import '../services/import_service.dart';
import '../services/library_store.dart';
import '../utils/comic_name_parser.dart';
import 'comic_reader_screen.dart';
import 'pdf_reading_mode_screen.dart';
import 'pdf_reader_screen.dart';
import 'saga_detail_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _store = LibraryStore();
  final _import = ImportService();
  List<LibraryItem> _items = [];
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final l = await _store.load();
    if (!mounted) return;
    setState(() {
      _items = l;
      _loading = false;
    });
  }

  Future<void> _persist() => _store.save(_items);

  Future<void> _scheduleCoversForImported(List<LibraryItem> imported) async {
    var batch = 0;
    await _import.fillMissingCovers(
      imported,
      onCoverApplied: (_) {
        if (!mounted) return;
        setState(() {});
        batch++;
        if (batch >= 12) {
          batch = 0;
          _persist();
        }
      },
    );
    if (mounted) await _persist();
  }

  Future<List<LibraryItem>> _runImportWithProgress(
    Future<List<LibraryItem>> Function(ImportProgressCallback onProgress) work,
  ) async {
    if (!mounted) return [];
    final nav = Navigator.of(context, rootNavigator: true);
    final prog = ValueNotifier<({int done, int total})>((done: 0, total: 0));
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: AppTheme.black,
            title: const Text('A importar…'),
            content: ValueListenableBuilder<({int done, int total})>(
              valueListenable: prog,
              builder: (context, v, child) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (v.total > 0)
                      LinearProgressIndicator(value: v.done / v.total)
                    else
                      const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      v.total > 0 ? '${v.done} de ${v.total}' : 'A preparar…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    try {
      return await work((completed, total) {
        prog.value = (done: completed, total: total);
      });
    } finally {
      if (mounted) nav.pop();
    }
  }

  Future<void> _addFiles() async {
    final files = await _import.pickFiles();
    if (files == null) return;
    final n = await _runImportWithProgress(
      (onProgress) => _import.processPickedFiles(files, onProgress: onProgress),
    );
    if (n.isEmpty) return;
    setState(() => _items = [...n, ..._items]);
    await _persist();
    unawaited(_scheduleCoversForImported(n));
  }

  Future<void> _addFolder() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.black,
        title: const Text('Nome da coleção'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Ex.: Dragon Ball, Marvel…',
          ),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Selecionar ficheiros'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final files = await _import.pickFiles(
      dialogTitle: 'Selecionar ficheiros para "$title"',
    );
    if (files == null) return;
    final colId = 'col_${DateTime.now().microsecondsSinceEpoch}';
    final n = await _runImportWithProgress(
      (onProgress) => _import.processPickedFiles(
        files,
        collectionId: colId,
        collectionTitle: title,
        onProgress: onProgress,
      ),
    );
    if (!mounted) return;
    if (n.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nenhum ficheiro selecionado ou importado.'),
        ),
      );
      return;
    }
    setState(() => _items = [...n, ..._items]);
    await _persist();
    unawaited(_scheduleCoversForImported(n));
  }

  Future<void> _importFolderFromDisk() async {
    final dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Selecionar pasta no disco',
    );
    if (dirPath == null || dirPath.isEmpty) return;
    if (!mounted) return;
    final controller = TextEditingController(text: p.basename(dirPath));
    final nameOrCancel = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.black,
        title: const Text('Importar pasta'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Todos os PDF/CBZ/CBR… dentro da pasta (e subpastas) serão importados.',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Nome da coleção',
                hintText: 'Vazio = ficheiros soltos na biblioteca',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Importar'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (nameOrCancel == null) return;
    final n = await _runImportWithProgress(
      (onProgress) => _import.importFromDirectoryPath(
        dirPath,
        collectionTitle: nameOrCancel.isEmpty ? null : nameOrCancel,
        onProgress: onProgress,
      ),
    );
    if (!mounted) return;
    if (n.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nenhum ficheiro compatível encontrado na pasta.'),
        ),
      );
      return;
    }
    setState(() => _items = [...n, ..._items]);
    await _persist();
    unawaited(_scheduleCoversForImported(n));
  }

  void _createEmptyFolder() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.black,
          title: const Text('Nome da pasta'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Ex.: One Piece, Marvel…'),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) {
                Navigator.pop(ctx);
                final colId = 'col_${DateTime.now().microsecondsSinceEpoch}';
                setState(() {
                  _items.insert(
                    0,
                    LibraryItem(
                      id: '${DateTime.now().microsecondsSinceEpoch}_folder',
                      filePath: '',
                      format: BookFormat.pdf,
                      addedAt: DateTime.now(),
                      originalName: '.folder_placeholder',
                      collectionId: colId,
                      collectionTitle: v.trim(),
                    ),
                  );
                });
                _persist();
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final v = controller.text.trim();
                if (v.isNotEmpty) {
                  Navigator.pop(ctx);
                  final colId = 'col_${DateTime.now().microsecondsSinceEpoch}';
                  setState(() {
                    _items.insert(
                      0,
                      LibraryItem(
                        id: '${DateTime.now().microsecondsSinceEpoch}_folder',
                        filePath: '',
                        format: BookFormat.pdf,
                        addedAt: DateTime.now(),
                        originalName: '.folder_placeholder',
                        collectionId: colId,
                        collectionTitle: v,
                      ),
                    );
                  });
                  _persist();
                }
              },
              child: const Text('Criar'),
            ),
          ],
        );
      },
    );
  }

  LibraryItem? _nextIssueInSameSaga(LibraryItem item) {
    final sagas = buildSagas(_items);
    for (final s in sagas) {
      final issues = s.issues
          .where((e) => e.originalName != '.folder_placeholder')
          .toList();
      final i = issues.indexWhere((e) => e.id == item.id);
      if (i >= 0 && i < issues.length - 1) {
        return issues[i + 1];
      }
    }
    return null;
  }

  Widget _readerRouteForItem(BuildContext routeContext, LibraryItem itemRef) {
    final idx = _items.indexWhere((e) => e.id == itemRef.id);
    if (idx < 0) {
      return const Scaffold(body: Center(child: Text('Item não encontrado')));
    }
    final openItem = _items[idx];
    final next = _nextIssueInSameSaga(openItem);

    void persist(int p, {int? totalPages}) {
      final i = _items.indexWhere((e) => e.id == openItem.id);
      if (i < 0) return;
      setState(() {
        _items[i].lastPageIndex = p;
        _items[i].lastReadAt = DateTime.now();
        if (totalPages != null) {
          _items[i].totalPages = totalPages;
        }
      });
      _persist();
    }

    void goNext() {
      if (next == null) return;
      Navigator.of(routeContext).pushReplacement(
        MaterialPageRoute(
          builder: (ctx) => _readerRouteForItem(ctx, next),
        ),
      );
    }

    if (openItem.format == BookFormat.pdf) {
      return PdfReaderScreen(
        item: openItem,
        onPagePersist: persist,
        nextIssue: next,
        onOpenNext: next != null ? goNext : null,
      );
    }
    return ComicReaderScreen(
      item: openItem,
      onPagePersist: persist,
      nextIssue: next,
      onOpenNext: next != null ? goNext : null,
    );
  }

  void _openReader(LibraryItem item) {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) return;
    setState(() {
      _items[idx].lastReadAt = DateTime.now();
    });
    _persist();

    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => _readerRouteForItem(ctx, _items[idx]),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openReadModeForPdf(LibraryItem item) {
    final idx = _getIndexForItem(item);
    if (idx < 0 || item.format != BookFormat.pdf) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PdfReadingModeScreen(
          item: _items[idx],
          onPagePersist: (p, {int? totalPages}) {
            final i = _items.indexWhere((e) => e.id == item.id);
            if (i < 0) return;
            setState(() {
              _items[i].lastPageIndex = p;
              _items[i].lastReadAt = DateTime.now();
              if (totalPages != null) _items[i].totalPages = totalPages;
            });
            _persist();
          },
        ),
      ),
    );
  }

  int _getIndexForItem(LibraryItem item) {
    return _items.indexWhere((e) => e.id == item.id);
  }

  void _moveItems(List<LibraryItem> items, String colId, String colTitle) {
    setState(() {
      for (final it in items) {
        final idx = _items.indexWhere((e) => e.id == it.id);
        if (idx < 0) continue;
        _items[idx].collectionId = colId;
        _items[idx].collectionTitle = colTitle;
      }
    });
    _persist();
  }

  void _createFolderAndMove(List<LibraryItem> items, String title) {
    final colId = 'col_${DateTime.now().microsecondsSinceEpoch}';
    _moveItems(items, colId, title);
  }

  Future<void> _addFilesToSaga(Saga saga) async {
    String colId;
    final colTitle = saga.title;

    if (saga.isPastaCollection) {
      colId = saga.id.replaceFirst('c:', '');
    } else {
      colId = 'col_${DateTime.now().microsecondsSinceEpoch}';
      setState(() {
        for (final it in saga.issues) {
          final idx = _items.indexWhere((e) => e.id == it.id);
          if (idx >= 0) {
            _items[idx].collectionId = colId;
            _items[idx].collectionTitle = colTitle;
          }
        }
      });
    }

    final files = await _import.pickFiles();
    if (files == null) return;
    final n = await _runImportWithProgress(
      (onProgress) => _import.processPickedFiles(
        files,
        collectionId: colId,
        collectionTitle: colTitle,
        onProgress: onProgress,
      ),
    );
    if (!mounted) return;
    if (n.isEmpty) return;
    setState(() => _items = [...n, ..._items]);
    await _persist();
    unawaited(_scheduleCoversForImported(n));
  }

  void _deleteItems(List<LibraryItem> items) {
    final ids = items.map((e) => e.id).toSet();
    setState(() {
      _items.removeWhere((e) => ids.contains(e.id));
    });
    _persist();
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
          title: const Text('As tuas sagas'),
        ),
        body: Center(
          child: CircularProgressIndicator(
            color: c.primary,
            strokeWidth: 2.5,
          ),
        ),
      );
    }

    final sagas = buildSagas(_items);

    return Scaffold(
      backgroundColor: AppTheme.black,
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            floating: true,
            backgroundColor: AppTheme.black,
            surfaceTintColor: Colors.transparent,
            title: const Text('As tuas sagas'),
            actions: [
              IconButton(
                onPressed: _addFiles,
                icon: const Icon(Icons.file_open_outlined),
                tooltip: 'Importar ficheiros',
              ),
              IconButton(
                onPressed: _addFolder,
                icon: const Icon(Icons.library_add_outlined),
                tooltip: 'Criar coleção (selecionar vários)',
              ),
              IconButton(
                onPressed: _importFolderFromDisk,
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: 'Importar pasta do disco',
              ),
              IconButton(
                onPressed: _createEmptyFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: 'Nova pasta vazia',
              ),
            ],
          ),
          if (sagas.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Center(
                  child: Text(
                    'Importa PDF, CBZ, CBR, CB7, CBT…\n'
                    'Usa o botão de ficheiro para importar avulso,\n'
                    'ou o botão de coleção para agrupar numa pasta.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.62,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final s = sagas[i];
                    final resume = s.resumeTargetItem;
                    return _SagaCard(
                      saga: s,
                      isPastaAlbum: s.isPastaCollection,
                      onDelete: () => _deleteItems(s.issues),
                      onPlayResume:
                          resume == null ? null : () => _openReader(resume),
                      onReadAloud: resume != null &&
                              resume.format == BookFormat.pdf
                          ? () => _openReadModeForPdf(resume)
                          : null,
                      onTap: () {
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SagaDetailScreen(
                              saga: s,
                              allSagas: sagas,
                              onOpenIssue: (it) {
                                if (_getIndexForItem(it) < 0) return;
                                _openReader(it);
                              },
                              onMoveItems: (items, colId, colTitle) {
                                _moveItems(items, colId, colTitle);
                                Navigator.pop(context);
                              },
                              onCreateFolder: (items, title) {
                                _createFolderAndMove(items, title);
                                Navigator.pop(context);
                              },
                              onDeleteItems: (items) {
                                _deleteItems(items);
                                Navigator.pop(context);
                              },
                              onAddFiles: () async {
                                await _addFilesToSaga(s);
                                if (!context.mounted) return;
                                Navigator.pop(context);
                              },
                            ),
                          ),
                        ).then((_) {
                          if (mounted) setState(() {});
                        });
                      },
                    );
                  },
                  childCount: sagas.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SagaCard extends StatelessWidget {
  const _SagaCard({
    required this.saga,
    required this.isPastaAlbum,
    required this.onTap,
    required this.onDelete,
    this.onPlayResume,
    this.onReadAloud,
  });

  static const _resumeGreen = Color(0xFF2E7D32);
  static const _readAloudBlue = Color(0xFF1565C0);

  final Saga saga;
  final bool isPastaAlbum;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onPlayResume;
  final VoidCallback? onReadAloud;

  void _confirmDelete(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir saga'),
        content: Text(
          'Remover "${saga.title}" e todos os seus ${saga.issueCount} itens da biblioteca?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }

  static String _continueLine(Saga s) {
    final lr = s.lastReadItem;
    if (lr == null) {
      return 'Ainda por ler';
    }
    final n = parseComicOriginalName(lr.originalName).issueNumber;
    final p = lr.lastPageIndex + 1;
    final tot = lr.totalPages;
    final cap = tot != null && tot > 0 ? ' · $p / $tot' : ' · p. $p';
    if (n > 0) {
      return 'A ler edição $n$cap';
    }
    return 'A ler$cap';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final path = saga.coverForDisplay;
    final prog = saga.lastReadProgress;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: c.outline.withValues(alpha: 0.4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: c.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _confirmDelete(context),
          splashColor: c.primary.withValues(alpha: 0.12),
          highlightColor: c.primary.withValues(alpha: 0.06),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (path != null && File(path).existsSync())
                      Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) =>
                            _coverFallback(c, folder: isPastaAlbum),
                      )
                    else
                      _coverFallback(c, folder: isPastaAlbum),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            c.surfaceContainerHigh.withValues(alpha: 0.2),
                            c.surfaceContainerHigh,
                          ],
                          stops: const [0.45, 0.72, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isPastaAlbum)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: c.primary.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.folder_outlined,
                                      size: 15,
                                      color: c.onPrimary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Pasta',
                                      style: t.labelSmall?.copyWith(
                                        color: c.onPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${saga.issueCount} vol.',
                              style: t.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (onPlayResume != null || onReadAloud != null)
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onReadAloud != null) ...[
                              Tooltip(
                                message: 'Modo leitura (voz — só PDF)',
                                child: Material(
                                  color: _readAloudBlue,
                                  elevation: 3,
                                  shadowColor:
                                      Colors.black.withValues(alpha: 0.45),
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: onReadAloud,
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 30,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (onPlayResume != null) const SizedBox(width: 8),
                            ],
                            if (onPlayResume != null)
                              Tooltip(
                                message: 'Continuar de onde paraste',
                                child: Material(
                                  color: _resumeGreen,
                                  elevation: 3,
                                  shadowColor:
                                      Colors.black.withValues(alpha: 0.45),
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: onPlayResume,
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 30,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      saga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _continueLine(saga),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(
                        color: c.onSurfaceVariant,
                        height: 1.25,
                      ),
                    ),
                    if (prog != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: prog,
                          minHeight: 5,
                          backgroundColor: c.outline.withValues(alpha: 0.35),
                          color: c.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _coverFallback(ColorScheme c, {bool folder = false}) {
    return Container(
      color: c.surfaceContainerHighest,
      child: Center(
        child: Icon(
          folder ? Icons.folder_open_rounded : Icons.auto_stories_rounded,
          size: 48,
          color: c.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
