import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../widgets/local_cover_image.dart';
import '../models/library_item.dart';
import '../models/saga.dart';
import '../utils/comic_name_parser.dart';

class SagaDetailScreen extends StatelessWidget {
  const SagaDetailScreen({
    super.key,
    required this.saga,
    required this.onOpenIssue,
    required this.allSagas,
    required this.onMoveItems,
    required this.onCreateFolder,
    required this.onDeleteItems,
    required this.onAddFiles,
  });

  final Saga saga;
  final void Function(LibraryItem item) onOpenIssue;
  final List<Saga> allSagas;

  final void Function(List<LibraryItem> items, String targetCollectionId, String targetTitle)
      onMoveItems;

  final void Function(List<LibraryItem> items, String title) onCreateFolder;

  final void Function(List<LibraryItem> items) onDeleteItems;

  /// Importa ficheiros para esta saga/coleção.
  final VoidCallback onAddFiles;

  List<LibraryItem> get _realIssues =>
      saga.issues.where((e) => e.originalName != '.folder_placeholder').toList();

  void _confirmDeleteAll(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir saga'),
        content: Text(
          'Remover "${saga.title}" e todos os seus ${_realIssues.length} itens?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.error),
            onPressed: () {
              Navigator.pop(ctx);
              onDeleteItems(saga.issues);
            },
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteItem(BuildContext context, LibraryItem item) {
    final c = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir item'),
        content: Text('Remover "${item.originalName}" da biblioteca?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.error),
            onPressed: () {
              Navigator.pop(ctx);
              onDeleteItems([item]);
            },
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }

  void _showMoveDialog(BuildContext context, List<LibraryItem> items) {
    final c = Theme.of(context).colorScheme;
    final destinations = allSagas.where((s) => s.id != saga.id).toList();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Mover ${items.length} item(s)',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 16),
                Material(
                  color: c.primaryContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(14),
                  child: ListTile(
                    leading: Icon(Icons.create_new_folder_outlined, color: c.primary),
                    title: const Text('Criar nova pasta'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showNewFolderDialog(context, items);
                    },
                  ),
                ),
                if (destinations.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Ou mover para:',
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                          color: c.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: (destinations.length * 52.0).clamp(0, 260),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: destinations.length,
                      itemBuilder: (_, i) {
                        final d = destinations[i];
                        return Material(
                          color: c.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              d.isPastaCollection ? Icons.folder_outlined : Icons.auto_stories_rounded,
                              size: 20,
                              color: c.onSurfaceVariant,
                            ),
                            title: Text(
                              d.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${d.issueCount} vol.'),
                            onTap: () {
                              Navigator.pop(ctx);
                              final colId = d.isPastaCollection
                                  ? d.id.replaceFirst('c:', '')
                                  : 'col_${DateTime.now().microsecondsSinceEpoch}';
                              onMoveItems(items, colId, d.title);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _showNewFolderDialog(BuildContext context, List<LibraryItem> items) {
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
            decoration: const InputDecoration(
              hintText: 'Ex.: Dragon Ball, Marvel…',
            ),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) {
                Navigator.pop(ctx);
                onCreateFolder(items, v.trim());
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
                  onCreateFolder(items, v);
                }
              },
              child: const Text('Criar'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppTheme.black,
      appBar: AppBar(
        backgroundColor: AppTheme.black,
        surfaceTintColor: Colors.transparent,
        title: Text(
          saga.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: onAddFiles,
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Adicionar ficheiros aqui',
          ),
          IconButton(
            onPressed: () => _showMoveDialog(context, _realIssues),
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Mover tudo',
          ),
          IconButton(
            onPressed: () => _confirmDeleteAll(context),
            icon: Icon(Icons.delete_outline, color: color.error),
            tooltip: 'Excluir tudo',
          ),
        ],
        bottom: saga.issueCount > 0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(32),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${saga.issueCount} edições · toca para ler, arrasta para mover',
                    style: TextStyle(
                      color: color.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            : null,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        itemCount: _realIssues.length,
        separatorBuilder: (context, index) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          final it = _realIssues[i];
          final parsed = parseComicOriginalName(it.originalName);
          final n = parsed.issueNumber;
          final ext = it.originalName.contains('.')
              ? it.originalName.split('.').last.toUpperCase()
              : it.format.name.toUpperCase();
          final type = ext;
          final label = n > 0 ? '#$n · ${it.originalName}' : it.originalName;
          final t = it.totalPages;
          final cur = it.lastPageIndex + 1;
          final sub = it.lastReadAt != null
              ? (t != null && t > 0
                  ? '$type · p. $cur de $t'
                  : '$type · parou na p. $cur')
              : type;
          final progress = t != null && t > 0 && it.lastReadAt != null
              ? (cur / t).clamp(0.0, 1.0)
              : null;
          Widget? lead;
          final cp = it.coverPath;
          if (cp != null && cp.isNotEmpty) {
            lead = ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 64,
                child: localCoverImage(
                  path: cp,
                  fit: BoxFit.cover,
                  fallback: SizedBox(
                    width: 48,
                    height: 64,
                    child: ColoredBox(
                      color: color.surfaceContainerHighest,
                      child: Icon(
                        Icons.menu_book_rounded,
                        color: color.onSurfaceVariant,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          return Material(
            color: color.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              leading: lead,
              title: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 2),
                  Text(sub),
                  if (progress != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: color.outline.withValues(alpha: 0.3),
                        color: color.primary,
                      ),
                    ),
                  ],
                ],
              ),
              isThreeLine: progress != null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (it.lastReadAt != null)
                    Icon(Icons.bookmark, color: color.tertiary, size: 20),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.drive_file_move_outline, size: 20, color: color.onSurfaceVariant),
                    tooltip: 'Mover',
                    onPressed: () => _showMoveDialog(context, [it]),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 20, color: color.error),
                    tooltip: 'Excluir',
                    onPressed: () => _confirmDeleteItem(context, it),
                  ),
                ],
              ),
              onTap: () => onOpenIssue(it),
            ),
          );
        },
      ),
    );
  }
}
