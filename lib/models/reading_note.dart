/// Marcador numa página de PDF — ancorável ao texto ou só posição livre ([linkedPrepCharIndex]).
class ReadingNote {
  ReadingNote({
    required this.id,
    required this.libraryItemId,
    required this.pageNumber,
    double anchorX = 0.72,
    double anchorY = 0.22,
    required this.paperArgb,
    required this.textArgb,
    required this.body,
    required this.createdAt,
    this.linkedPrepCharIndex,
  })  : anchorX = anchorX.clamp(0.0, 1.0),
        anchorY = anchorY.clamp(0.0, 1.0);

  final String id;
  final String libraryItemId;

  /// 1-based — alinhado com ecrãs de leitura PDF.
  final int pageNumber;
  final double anchorX;
  final double anchorY;
  final int paperArgb;
  final int textArgb;
  final String body;
  final DateTime createdAt;

  /// Índice no mesmo texto preparado (`trim` + `\n` colapsados) que a fila TTS usa por página.
  /// `null` = notas antigas; leitura lê bloco agrupado no fim da página.
  final int? linkedPrepCharIndex;

  ReadingNote copyWith({
    String? id,
    String? libraryItemId,
    int? pageNumber,
    double? anchorX,
    double? anchorY,
    int? paperArgb,
    int? textArgb,
    String? body,
    DateTime? createdAt,
    int? linkedPrepCharIndex,
  }) {
    return ReadingNote(
      id: id ?? this.id,
      libraryItemId: libraryItemId ?? this.libraryItemId,
      pageNumber: pageNumber ?? this.pageNumber,
      anchorX: anchorX ?? this.anchorX,
      anchorY: anchorY ?? this.anchorY,
      paperArgb: paperArgb ?? this.paperArgb,
      textArgb: textArgb ?? this.textArgb,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      linkedPrepCharIndex:
          linkedPrepCharIndex ?? this.linkedPrepCharIndex,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'libraryItemId': libraryItemId,
        'pageNumber': pageNumber,
        'anchorX': anchorX,
        'anchorY': anchorY,
        'paperArgb': paperArgb,
        'textArgb': textArgb,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        if (linkedPrepCharIndex != null)
          'linkedPrepCharIndex': linkedPrepCharIndex,
      };

  static ReadingNote fromJson(Map<String, dynamic> m) {
    return ReadingNote(
      id: m['id'] as String,
      libraryItemId: m['libraryItemId'] as String,
      pageNumber: (m['pageNumber'] as num).toInt(),
      anchorX: (m['anchorX'] as num).toDouble(),
      anchorY: (m['anchorY'] as num).toDouble(),
      paperArgb: (m['paperArgb'] as num).toInt(),
      textArgb: (m['textArgb'] as num).toInt(),
      body: m['body'] as String,
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      linkedPrepCharIndex:
          (m['linkedPrepCharIndex'] as num?)?.toInt(),
    );
  }
}
