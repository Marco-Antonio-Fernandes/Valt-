import '../utils/comic_name_parser.dart';
import '../utils/natural_compare.dart';
import 'library_item.dart';

/// Uma história: ficheiros com o mesmo título base, ou um álbum importado de uma pasta.
class Saga {
  Saga({
    required this.id,
    required this.title,
    required this.issues,
  });

  final String id;
  final String title;
  final List<LibraryItem> issues;

  int get issueCount =>
      issues.where((e) => e.originalName != '.folder_placeholder').length;

  /// Importação por "Escolher pasta" (um álbum com o nome da pasta).
  bool get isPastaCollection => id.startsWith('c:');

  String? get coverForDisplay {
    final lr = lastReadItem;
    if (lr != null) {
      final c = lr.coverPath;
      if (c != null && c.isNotEmpty) return c;
    }
    for (final o in issues) {
      final c = o.coverPath;
      if (c != null && c.isNotEmpty) return c;
    }
    return null;
  }

  double? get lastReadProgress {
    final lr = lastReadItem;
    if (lr == null) return null;
    final t = lr.totalPages;
    if (t == null || t <= 0) return null;
    return ((lr.lastPageIndex + 1) / t).clamp(0.0, 1.0);
  }

  LibraryItem? get lastReadItem {
    LibraryItem? best;
    DateTime? bestT;
    for (final o in issues) {
      final t = o.lastReadAt;
      if (t == null) continue;
      if (bestT == null || t.isAfter(bestT)) {
        bestT = t;
        best = o;
      }
    }
    return best;
  }

  /// Volume a abrir em «continuar»: o último lido, se existir; senão o primeiro da saga.
  LibraryItem? get resumeTargetItem {
    final real = issues
        .where(
          (e) =>
              e.originalName != '.folder_placeholder' && e.filePath.isNotEmpty,
        )
        .toList();
    if (real.isEmpty) return null;
    final lr = lastReadItem;
    if (lr != null && real.any((e) => e.id == lr.id)) {
      return lr;
    }
    return real.first;
  }
}

List<Saga> buildSagas(List<LibraryItem> items) {
  final map = <String, List<LibraryItem>>{};
  final titles = <String, String>{};

  for (final it in items) {
    String key;
    if (it.collectionId != null && it.collectionId!.isNotEmpty) {
      key = 'c:${it.collectionId}';
      map.putIfAbsent(key, () => []).add(it);
      titles.putIfAbsent(
        key,
        () => it.collectionTitle?.trim().isNotEmpty == true
            ? it.collectionTitle!
            : 'Álbum',
      );
    } else {
      final parsed = parseComicOriginalName(it.originalName);
      key = 'n:${parsed.sagaId}';
      map.putIfAbsent(key, () => []).add(it);
      titles.putIfAbsent(key, () => parsed.sagaTitle);
    }
  }

  final out = <Saga>[];
  for (final e in map.entries) {
    final list = e.value;
    list.sort((a, b) => naturalCompare(a.originalName, b.originalName));
    out.add(
      Saga(
        id: e.key,
        title: titles[e.key] ?? e.key,
        issues: list,
      ),
    );
  }
  out.sort((a, b) => naturalCompare(a.title, b.title));
  return out;
}
