import '../models/library_item.dart';

/// Livro já aberto pelo utilizador (tem registo de leitura).
bool readingLogIncludes(LibraryItem item) => item.lastReadAt != null;

/// Última página lida (1-based).
int readingCurrentPage(LibraryItem item) => item.lastPageIndex + 1;

/// Progresso 0–1 quando [totalPages] é conhecido; senão null.
double? readingProgressFraction(LibraryItem item) {
  final tot = item.totalPages;
  if (!readingLogIncludes(item) || tot == null || tot <= 0) return null;
  return (readingCurrentPage(item) / tot).clamp(0.0, 1.0);
}

/// Verdadeiro quando chegou à última página e o total é conhecido.
bool isReadingCompleted(LibraryItem item) {
  if (!readingLogIncludes(item)) return false;
  final tot = item.totalPages;
  if (tot == null || tot <= 0) return false;
  return item.lastPageIndex >= tot - 1;
}

/// Texto curto de progresso ou conclusão.
String readingProgressLabel(LibraryItem item) {
  if (isReadingCompleted(item)) {
    final tot = item.totalPages;
    if (tot != null && tot > 0) {
      return 'Concluído · $tot páginas';
    }
    return 'Concluído';
  }
  final cur = readingCurrentPage(item);
  final tot = item.totalPages;
  if (tot != null && tot > 0) {
    final left = (tot - cur).clamp(0, tot);
    if (left == 0) return 'Concluído · p. $tot de $tot';
    if (left == 1) return 'Pág. $cur de $tot · falta 1 página';
    return 'Pág. $cur de $tot · faltam ~$left páginas';
  }
  return 'A ler · parou na pág. $cur';
}

/// Percentagem arredondada para exibição (ex.: 67%).
int? readingProgressPercent(LibraryItem item) {
  final f = readingProgressFraction(item);
  if (f == null) return null;
  return (f * 100).round().clamp(0, 100);
}

List<LibraryItem> readingLogCompleted(Iterable<LibraryItem> items) {
  return items.where((e) => isReadingCompleted(e)).toList()
    ..sort((a, b) => b.lastReadAt!.compareTo(a.lastReadAt!));
}

List<LibraryItem> readingLogInProgress(Iterable<LibraryItem> items) {
  return items
      .where((e) => readingLogIncludes(e) && !isReadingCompleted(e))
      .toList()
    ..sort((a, b) => b.lastReadAt!.compareTo(a.lastReadAt!));
}
