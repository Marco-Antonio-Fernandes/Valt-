/// Grifo persistente no texto do PDF ([start] inclusivo / [end] exclusivo sobre [PdfPageText.fullText]).
const int kDefaultReadingHighlightArgb = 0xFFFFCA28;

class ReadingHighlight {
  ReadingHighlight({
    required this.id,
    required this.libraryItemId,
    required this.pageNumber,
    required int start,
    required int end,
    required this.preview,
    required this.createdAt,
    this.highlightArgb = kDefaultReadingHighlightArgb,
  })  : start = start < 0 ? 0 : start,
        end = (() {
          final normalizedStart = start < 0 ? 0 : start;
          return end < normalizedStart ? normalizedStart : end;
        })();

  final String id;
  final String libraryItemId;
  final int pageNumber;
  final int start;
  final int end;
  final String preview;
  final DateTime createdAt;
  final int highlightArgb;

  ReadingHighlight copyWith({
    String? id,
    String? libraryItemId,
    int? pageNumber,
    int? start,
    int? end,
    String? preview,
    DateTime? createdAt,
    int? highlightArgb,
  }) {
    return ReadingHighlight(
      id: id ?? this.id,
      libraryItemId: libraryItemId ?? this.libraryItemId,
      pageNumber: pageNumber ?? this.pageNumber,
      start: start ?? this.start,
      end: end ?? this.end,
      preview: preview ?? this.preview,
      createdAt: createdAt ?? this.createdAt,
      highlightArgb: highlightArgb ?? this.highlightArgb,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'libraryItemId': libraryItemId,
        'pageNumber': pageNumber,
        'start': start,
        'end': end,
        'preview': preview,
        'createdAt': createdAt.toIso8601String(),
        'highlightArgb': highlightArgb,
      };

  static ReadingHighlight fromJson(Map<String, dynamic> m) {
    final s = (m['start'] as num).toInt();
    var e = (m['end'] as num).toInt();
    if (e < s) e = s;
    return ReadingHighlight(
      id: m['id'] as String,
      libraryItemId: m['libraryItemId'] as String,
      pageNumber: (m['pageNumber'] as num).toInt(),
      start: s,
      end: e,
      preview: m['preview'] as String? ?? '',
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      highlightArgb:
          (m['highlightArgb'] as num?)?.toInt() ?? kDefaultReadingHighlightArgb,
    );
  }
}
