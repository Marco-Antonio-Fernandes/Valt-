import 'package:path/path.dart' as p;

enum BookFormat { pdf, cbz, cbr }

class LibraryItem {
  LibraryItem({
    required this.id,
    required this.filePath,
    required this.format,
    required this.addedAt,
    required this.originalName,
    this.lastPageIndex = 0,
    this.lastReadAt,
    this.coverPath,
    this.totalPages,
    this.collectionId,
    this.collectionTitle,
  });

  final String id;
  final String filePath;
  final BookFormat format;
  final DateTime addedAt;

  /// Nome do ficheiro na origem (ex.: "Batman 01.cbr") — usado para agrupar sagas.
  final String originalName;

  int lastPageIndex;
  DateTime? lastReadAt;
  String? coverPath;
  int? totalPages;

  /// Se veio de "importar pasta": todos com o mesmo id formam um álbum com [collectionTitle].
  String? collectionId;
  String? collectionTitle;

  String get displayName => originalName;

  static BookFormat formatFromPath(String path) {
    final e = p.extension(path).toLowerCase();
    switch (e) {
      case '.pdf':
        return BookFormat.pdf;
      case '.cbz':
      case '.zip':
        return BookFormat.cbz;
      case '.cbr':
      case '.rar':
      case '.cb7':
      case '.7z':
      case '.cbt':
      case '.tar':
        return BookFormat.cbr;
      default:
        return BookFormat.pdf;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'format': format.name,
        'addedAt': addedAt.toIso8601String(),
        'originalName': originalName,
        'lastPageIndex': lastPageIndex,
        if (lastReadAt != null) 'lastReadAt': lastReadAt!.toIso8601String(),
        if (coverPath != null) 'coverPath': coverPath,
        if (totalPages != null) 'totalPages': totalPages,
        if (collectionId != null) 'collectionId': collectionId,
        if (collectionTitle != null) 'collectionTitle': collectionTitle,
      };

  static LibraryItem fromJson(Map<String, dynamic> m) {
    final fp = m['filePath'] as String;
    return LibraryItem(
      id: m['id'] as String,
      filePath: fp,
      format: BookFormat.values.byName(m['format'] as String),
      addedAt: DateTime.parse(m['addedAt'] as String),
      originalName: (m['originalName'] as String?) ?? p.basename(fp),
      lastPageIndex: (m['lastPageIndex'] as num?)?.toInt() ?? 0,
      lastReadAt: m['lastReadAt'] != null
          ? DateTime.tryParse(m['lastReadAt'] as String)
          : null,
      coverPath: m['coverPath'] as String?,
      totalPages: (m['totalPages'] as num?)?.toInt(),
      collectionId: m['collectionId'] as String?,
      collectionTitle: m['collectionTitle'] as String?,
    );
  }
}
