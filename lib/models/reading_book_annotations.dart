import 'reading_highlight.dart';
import 'reading_note.dart';

/// Marcadores de leitura guardados por livro ([LibraryItem.id]).
class ReadingBookAnnotations {
  const ReadingBookAnnotations({
    required this.notes,
    required this.highlights,
  });

  final List<ReadingNote> notes;
  final List<ReadingHighlight> highlights;
}
