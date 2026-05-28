import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:showcaseview/showcaseview.dart';

import '../app_theme.dart';
import '../models/library_item.dart';
import '../models/saga.dart';
import '../services/import_service.dart';
import '../services/library_store.dart';
import '../services/vault_android_permissions.dart';
import '../services/vault_auth_api.dart';
import '../services/vault_auth_store.dart';
import '../services/vault_tutorial_store.dart';
import '../utils/comic_name_parser.dart';
import '../widgets/local_cover_image.dart';
import 'comic_reader_screen.dart';
import 'pdf_reading_mode_screen.dart';
import 'pdf_reader_screen.dart';
import 'account_screen.dart';
import 'saga_detail_screen.dart';
import '../tutorial/vault_app_tutorial.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.authApi,
    required this.authStore,
    this.runTutorialOnStart = false,
    this.onTutorialFinished,
    this.onSessionEnded,
  });

  final VaultAuthApi authApi;
  final VaultAuthStore authStore;
  final bool runTutorialOnStart;
  final VoidCallback? onTutorialFinished;
  final VoidCallback? onSessionEnded;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _store = LibraryStore();
  final _import = ImportService();
  List<LibraryItem> _items = [];
  var _loading = true;
  var _tabIndex = 0;
  VaultAppTutorial? _tutorial;

  static bool get _isAndroidDevice =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  int get _boundedTabIndex =>
      _tabIndex < 0 ? 0 : (_tabIndex > 2 ? 2 : _tabIndex);

  @override
  void dispose() {
    _tutorial?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _reload();
    if (widget.runTutorialOnStart) {
      _setupTutorial();
    }
  }

  void _setupTutorial() {
    final t = VaultAppTutorial();
    _tutorial = t;
    void finish() => widget.onTutorialFinished?.call();
    t.register(
      onFinish: finish,
      onDismiss: (_) => finish(),
      onStart: (_, key) {
        if (!mounted) return;
        if (key == t.importKey) {
          setState(() => _tabIndex = 1);
        } else if (key == t.accountKey) {
          setState(() => _tabIndex = 2);
        } else if (key == t.welcomeKey ||
            key == t.readListenKey ||
            key == t.notesKey) {
          setState(() => _tabIndex = 0);
        }
      },
    );
    t.start();
  }

  Widget _wrapTutorialWelcome(Widget child) {
    final t = _tutorial;
    if (t == null) return child;
    return VaultAppTutorial.wrap(
      showcaseKey: t.welcomeKey,
      title: 'Bem-vindo ao Vault',
      description:
          'Este é o Início. Quando leres algo, o último volume aparece aqui '
          'com atalhos rápidos.',
      child: child,
    );
  }

  Widget _wrapTutorialReadListen(Widget child) {
    final t = _tutorial;
    if (t == null) return child;
    return VaultAppTutorial.wrap(
      showcaseKey: t.readListenKey,
      title: 'Ler e Ouvir',
      description:
          'Em PDFs: «Ler» abre o leitor visual; «Ouvir» activa leitura em voz '
          'com destaque de texto e fila de reprodução. Bandas desenhadas abrem '
          'só em modo Ler.',
      child: child,
    );
  }

  Widget _wrapTutorialNotes(Widget child) {
    final t = _tutorial;
    if (t == null) return child;
    return VaultAppTutorial.wrap(
      showcaseKey: t.notesKey,
      title: 'Notas e grifos',
      description:
          'Dentro do leitor PDF, usa «Marcadores — notas e grifos»: notas '
          'fixas nas páginas e grifos coloridos no texto. Guardados por livro '
          'neste dispositivo.',
      child: child,
    );
  }

  Widget _wrapTutorialImport(Widget child) {
    final t = _tutorial;
    if (t == null) return child;
    return VaultAppTutorial.wrap(
      showcaseKey: t.importKey,
      title: 'Importar ficheiros',
      description:
          'Toca em «Adicionar» para importar PDF, CBZ, CBR, pastas ou criar '
          'coleções. Os ficheiros ficam na biblioteca deste dispositivo.',
      tooltipPosition: TooltipPosition.bottom,
      child: child,
    );
  }

  Widget _wrapTutorialAccount(Widget child) {
    final t = _tutorial;
    if (t == null) return child;
    return VaultAppTutorial.wrap(
      showcaseKey: t.accountKey,
      title: 'A tua conta',
      description:
          'Gere nome, bio e sessão. Ao sair, voltas ao ecrã de login.',
      child: child,
    );
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

    if (openItem.format == BookFormat.pdf || openItem.format == BookFormat.epub) {
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

  void _openReadModeForPdf(LibraryItem item) async {
    final idx = _getIndexForItem(item);
    if (idx < 0 || item.format != BookFormat.pdf) return;
    final tutorialStore = VaultTutorialStore();
    final showReaderTutorial = !await tutorialStore.isReaderTutorialCompleted();
    if (!mounted) return;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PdfReadingModeScreen(
          item: _items[idx],
          runTutorialOnStart: showReaderTutorial,
          onTutorialFinished: () => tutorialStore.markReaderTutorialCompleted(),
          onPagePersist: (p, {int? totalPages}) {
            final i = _items.indexWhere((e) => e.id == item.id);
            if (i < 0) return;
            _items[i].lastPageIndex = p;
            _items[i].lastReadAt = DateTime.now();
            if (totalPages != null) _items[i].totalPages = totalPages;
            _persist();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
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

  LibraryItem? _latestReadIssueItem() {
    LibraryItem? best;
    DateTime? bestAt;
    for (final it in _items) {
      if (it.originalName == '.folder_placeholder' || it.filePath.isEmpty) {
        continue;
      }
      final at = it.lastReadAt;
      if (at == null) continue;
      if (bestAt == null || at.isAfter(bestAt)) {
        bestAt = at;
        best = it;
      }
    }
    return best;
  }

  Saga? _sagaContainingItem(LibraryItem it, List<Saga> sagas) {
    for (final s in sagas) {
      if (s.issues.any((o) => o.id == it.id)) return s;
    }
    return null;
  }

  /// Última leitura (volume + saga) para o ecrã Início.
  ///
  /// Se [lastReadAt] existir mas a saga falhar por dados antigos/incoerentes,
  /// construímos uma saga mínima para o hero não ficar vazio.
  ({LibraryItem issue, Saga saga})? _lastReadHeroTuple(List<Saga> sagas) {
    final it = _latestReadIssueItem();
    if (it == null) return null;
    final s = _sagaContainingItem(it, sagas);
    if (s != null) return (issue: it, saga: s);
    final parsed = parseComicOriginalName(it.originalName);
    final title =
        parsed.sagaTitle.trim().isNotEmpty ? parsed.sagaTitle : it.displayName;
    return (
      issue: it,
      saga: Saga(
        id: 'o:${it.id}',
        title: title,
        issues: [it],
      ),
    );
  }

  void _openSagaDetail(Saga s, List<Saga> allSagas) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SagaDetailScreen(
          saga: s,
          allSagas: allSagas,
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
            if (!mounted) return;
            Navigator.pop(context);
          },
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Widget _mainNavigationBar(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final bar = NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 76,
        indicatorColor: c.primary.withValues(alpha: 0.28),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        elevation: 12,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        backgroundColor: c.surfaceContainerHigh.withValues(alpha: 0.96),
      ),
      child: SafeArea(
        top: false,
        minimum: EdgeInsets.zero,
        child: NavigationBar(
          selectedIndex: _boundedTabIndex,
          onDestinationSelected: (value) => setState(() => _tabIndex = value),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          destinations: const [
            NavigationDestination(
              tooltip: 'Início',
              label: ' ',
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
            ),
            NavigationDestination(
              tooltip: 'Biblioteca',
              label: ' ',
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book_rounded),
            ),
            NavigationDestination(
              tooltip: 'Conta · perfil',
              label: ' ',
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
            ),
          ],
        ),
      ),
    );

    final t = _tutorial;
    if (t == null) return bar;

    return VaultAppTutorial.wrap(
      showcaseKey: t.navKey,
      title: 'Navegação',
      description:
          'Início: continuar a ler. Biblioteca: importar e organizar. '
          'Conta: o teu perfil Vault.',
      tooltipPosition: TooltipPosition.top,
      child: bar,
    );
  }

  Widget _buildRecentHome(ColorScheme c, List<Saga> sagas) {
    final hero = _lastReadHeroTuple(sagas);
    return ColoredBox(
      color: AppTheme.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _homePinnedHeader(context, c, hero != null),
          Expanded(
            child:
                hero == null
                    ? _homeEmptyNoRecentRead(c)
                    : _homeLastReadHero(context, c, sagas, hero),
          ),
        ],
      ),
    );
  }

  Widget _homePinnedHeader(
    BuildContext context,
    ColorScheme c,
    bool hasHero,
  ) {
    final topPad = MediaQuery.paddingOf(context).top;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.surfaceContainerLow.withValues(alpha: 0.52),
            AppTheme.black,
          ],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, topPad + 14, 24, 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _wrapTutorialWelcome(
            Text(
              hasHero ? 'Continuar a ler' : 'Início',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.45,
                color: AppTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _homeEmptyNoRecentRead(ColorScheme c) {
    return LayoutBuilder(
      builder: (context, cons) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: cons.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _wrapTutorialReadListen(
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            c.primary.withValues(alpha: 0.35),
                            c.primary.withValues(alpha: 0.08),
                          ],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Icon(
                          Icons.auto_stories_rounded,
                          size: 56,
                          color: c.primary.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Ainda não abriste nenhum livro',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color: AppTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _wrapTutorialNotes(
                    Text(
                      'Na barra inferior, abre Biblioteca (2.º ícone) e importa um PDF '
                      'ou banda desenhada. Depois de leres pelo menos uma vez, '
                      'o último volume aparece aqui em grande, com Ler e Ouvir.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.muted,
                        height: 1.5,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _homeLastReadHero(
    BuildContext context,
    ColorScheme c,
    List<Saga> sagas,
    ({LibraryItem issue, Saga saga}) hero,
  ) {
    return LayoutBuilder(
      builder: (context, cons) {
        final it = hero.issue;
        final saga = hero.saga;
        final coverPath = it.coverPath ?? saga.coverForDisplay;
        final isPasta = saga.isPastaCollection;
        final tot = it.totalPages;
        final progD =
            tot != null && tot > 0
                ? ((it.lastPageIndex + 1) / tot).clamp(0.0, 1.0).toDouble()
                : null;
        final title = saga.title;
        final sub = _SagaCard.continueLineFor(saga);
        final canListen = it.format == BookFormat.pdf;
        final cardW = math.min(
          400.0,
          math.max(260.0, cons.maxWidth * 0.88),
        );
        final maxCardH = math.max(180.0, cons.maxHeight * 0.55);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Hero(
                  tag: 'vault_last_read_${it.id}',
                  child: Material(
                    color: Colors.transparent,
                    elevation: 16,
                    shadowColor: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(32),
                    child: InkWell(
                      onTap: () => _openReader(it),
                      borderRadius: BorderRadius.circular(32),
                      child: Container(
                        width: cardW,
                        constraints: BoxConstraints(maxHeight: maxCardH),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(
                            color: c.outline.withValues(alpha: 0.28),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 24,
                              offset: const Offset(0, 12),
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: AspectRatio(
                          aspectRatio: 0.68,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              localCoverImage(
                                path: coverPath,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                heroBackdropLayout: true,
                                fallback: _SagaCard._coverFallback(
                                  c,
                                  folder: isPasta,
                                ),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black.withValues(
                                        alpha: 0.25,
                                      ),
                                      Colors.black.withValues(
                                        alpha: 0.68,
                                      ),
                                    ],
                                    stops: const [0.35, 0.65, 1],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 14,
                                right: 14,
                                bottom: 14,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _HomeCircleAction(
                                      icon: Icons.menu_book_rounded,
                                      label: 'Ler',
                                      fill: c.primary,
                                      onFill: c.onPrimary,
                                      onTap: () => _openReader(it),
                                    ),
                                    const SizedBox(width: 16),
                                    _HomeCircleAction(
                                      icon: Icons.record_voice_over_rounded,
                                      label: 'Ouvir',
                                      fill:
                                          canListen
                                              ? c.primaryContainer
                                              : c.surfaceContainerHighest,
                                      onFill:
                                          canListen
                                              ? c.onPrimaryContainer
                                              : c.onSurfaceVariant,
                                      borderColor:
                                          canListen
                                              ? null
                                              : c.outline.withValues(
                                                  alpha: 0.55,
                                                ),
                                      onTap:
                                          () =>
                                              canListen
                                                  ? _openReadModeForPdf(it)
                                                  : ScaffoldMessenger.of(
                                                        context,
                                                      )
                                                      .showSnackBar(
                                                        const SnackBar(
                                                          behavior:
                                                              SnackBarBehavior
                                                                  .floating,
                                                          content: Text(
                                                            'Ouvir em voz (modo leitura) só está disponível para PDF.',
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
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: cardW),
                  child: Column(
                    children: [
                      Text(
                        title,
                        maxLines: 3,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          letterSpacing: -0.35,
                          color: AppTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        it.displayName,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: c.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        sub,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: c.onSurfaceVariant.withValues(
                            alpha: 0.9,
                          ),
                        ),
                      ),
                      if (progD != null) ...[
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: progD,
                            minHeight: 6,
                            backgroundColor: c.outline.withValues(
                              alpha: 0.35,
                            ),
                            color: c.primary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () => _openSagaDetail(saga, sagas),
                        icon: Icon(
                          Icons.expand_more_rounded,
                          color: c.primary,
                        ),
                        label: Text(
                          'Ver na biblioteca',
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLibraryTab(ColorScheme c, List<Saga> sagas) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar.large(
          floating: true,
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          flexibleSpace: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  c.surfaceContainerLow.withValues(alpha: 0.55),
                  AppTheme.black,
                ],
              ),
            ),
          ),
          title: Text(
            'Biblioteca',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
          ),
          actions: [
            if (_isAndroidDevice)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton.filledTonal(
                  style: IconButton.styleFrom(
                    backgroundColor:
                        c.primaryContainer.withValues(alpha: 0.35),
                  ),
                  onPressed: () {
                    unawaited(
                      vaultMaybeRequestAndroidBackgroundPermissions(
                        context,
                        skipExplanation: true,
                      ),
                    );
                  },
                  icon: Icon(
                    Icons.notifications_active_rounded,
                    color: c.primary,
                  ),
                  tooltip:
                      'Notificações e bateria (leitura em voz — Android)',
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PopupMenuButton<String>(
                tooltip: 'Importar ou adicionar',
                position: PopupMenuPosition.under,
                elevation: 12,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                onSelected: (v) async {
                  switch (v) {
                    case 'files':
                      await _addFiles();
                    case 'col':
                      await _addFolder();
                    case 'dir':
                      await _importFolderFromDisk();
                    case 'empty':
                      _createEmptyFolder();
                  }
                },
                itemBuilder:
                    (ctx) => [
                      PopupMenuItem(
                        value: 'files',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: c.primary.withValues(
                              alpha: 0.16,
                            ),
                            child: Icon(
                              Icons.file_open_outlined,
                              color: c.primary,
                              size: 20,
                            ),
                          ),
                          title: const Text('Importar ficheiros'),
                          subtitle: Text(
                            'PDF, CBZ, CBR…',
                            style: TextStyle(
                              color: c.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'col',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: c.tertiary.withValues(alpha: 0.2),
                            child: Icon(
                              Icons.collections_bookmark_outlined,
                              color: c.tertiary,
                              size: 20,
                            ),
                          ),
                          title: const Text('Nova coleção'),
                          subtitle: Text(
                            'Nome e vários ficheiros',
                            style: TextStyle(
                              color: c.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'dir',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor:
                                c.secondary.withValues(alpha: 0.2),
                            child: Icon(
                              Icons.folder_open_outlined,
                              color: c.secondary,
                              size: 20,
                            ),
                          ),
                          title: const Text('Importar pasta do disco'),
                          subtitle: Text(
                            'Um álbum de uma só vez',
                            style: TextStyle(
                              color: c.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'empty',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.create_new_folder_outlined,
                            color: c.primary,
                          ),
                          title: const Text('Nova pasta vazia'),
                          subtitle: Text(
                            'Para arrastar livros dentro',
                            style: TextStyle(
                              color: c.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                child: _wrapTutorialImport(
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: c.primary,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.add_rounded, color: c.onPrimary),
                          const SizedBox(width: 8),
                          Text(
                            'Adicionar',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  color: c.onPrimary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.expand_more_rounded, color: c.onPrimary),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (sagas.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c.surfaceContainerHighest,
                        border: Border.all(
                          color: c.outline.withValues(alpha: 0.38),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(26),
                        child: Icon(
                          Icons.auto_stories_rounded,
                          size: 48,
                          color: c.primary.withValues(alpha: 0.95),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Começa por importar um livro',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Importa PDF, CBZ, CBR ou banda desenhada.\n'
                      'Primeiro toca em «Adicionar» ↑ e escolhe como queres meter ficheiros na biblioteca.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.onSurfaceVariant,
                        height: 1.45,
                        fontSize: 14,
                      ),
                    ),
                  ],
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
                    onTap: () => _openSagaDetail(s, sagas),
                  );
                },
                childCount: sagas.length,
              ),
            ),
          ),
      ],
    );
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
      body: SizedBox.expand(
        child: IndexedStack(
          index: _boundedTabIndex,
          children: [
            _buildRecentHome(c, sagas),
            _buildLibraryTab(c, sagas),
            _wrapTutorialAccount(
              AccountScreen(
                authApi: widget.authApi,
                authStore: widget.authStore,
                libraryItems: _items,
                embeddedInLibrary: true,
                onSessionEnded: widget.onSessionEnded,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _mainNavigationBar(context),
    );
  }
}

class _HomeCircleAction extends StatelessWidget {
  const _HomeCircleAction({
    required this.icon,
    required this.label,
    required this.fill,
    required this.onFill,
    this.borderColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color fill;
  final Color onFill;
  final Color? borderColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final labelInk = Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border:
                    borderColor != null ? Border.all(color: borderColor!) : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Icon(icon, color: onFill, size: 34),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: t.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.15,
            color: labelInk,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 6,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ],
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

  static String continueLineFor(Saga s) => _continueLine(s);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final path = saga.coverForDisplay;
    final prog = saga.lastReadProgress;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
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
        borderRadius: BorderRadius.circular(24),
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
                    localCoverImage(
                      path: path,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      fallback: _coverFallback(c, folder: isPastaAlbum),
                    ),
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
                                  color: c.primaryContainer,
                                  elevation: 0,
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: onReadAloud,
                                    child: Padding(
                                      padding: const EdgeInsets.all(9),
                                      child: Icon(
                                        Icons.record_voice_over_rounded,
                                        color: c.onPrimaryContainer,
                                        size: 26,
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
    final icon =
        folder ? Icons.folder_open_rounded : Icons.auto_stories_rounded;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.25, -0.45),
          radius: 1.15,
          colors: [
            c.primary.withValues(alpha: folder ? 0.14 : 0.24),
            c.surfaceContainerHigh,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          size: 58,
          color: folder
              ? c.tertiary.withValues(alpha: 0.9)
              : c.primary.withValues(alpha: 0.95),
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.42),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
    );
  }
}
