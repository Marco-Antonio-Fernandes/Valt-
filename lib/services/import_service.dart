import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/library_item.dart';
import 'cover_service.dart';

const _exts = ['pdf', 'cbz', 'cbr', 'zip', 'rar', 'cb7', '7z', 'cbt', 'tar'];

typedef ImportProgressCallback = void Function(int completed, int total);

class ImportService {
  final _cover = CoverService();

  static String _extLower(String path) => p.extension(path).toLowerCase();

  static bool _isImportableFile(String path) {
    final e = _extLower(path);
    switch (e) {
      case '.pdf':
      case '.cbz':
      case '.cbr':
      case '.zip':
      case '.rar':
      case '.cb7':
      case '.7z':
      case '.cbt':
      case '.tar':
        return true;
      default:
        return false;
    }
  }

  static String _absoluteFilePath(String path) {
    if (path.isEmpty) return path;
    try {
      return p.normalize(File(path).absolute.path);
    } catch (_) {
      return p.normalize(path);
    }
  }

  static Future<void> _yieldUi() =>
      Future<void>.delayed(const Duration(milliseconds: 16));

  static Future<void> _copyFileBytes(String from, String to) async {
    final out = File(to).openWrite();
    try {
      await File(from).openRead().pipe(out);
    } finally {
      await out.close();
    }
  }

  static Future<void> _copyInRobust(String from, String to) async {
    try {
      await File(from).copy(to);
    } on FileSystemException {
      await _copyFileBytes(from, to);
    } catch (e) {
      await _copyFileBytes(from, to);
    }
  }

  int _idNonce = 0;

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${_idNonce++}';

  Future<Directory> _importsDir() async {
    final d = await getApplicationDocumentsDirectory();
    final sub = Directory(p.join(d.path, 'imports'));
    if (!sub.existsSync()) {
      sub.createSync(recursive: true);
    }
    return sub;
  }

  Future<LibraryItem?> _copyIn(
    String path, {
    required String originalName,
    String? collectionId,
    String? collectionTitle,
  }) async {
    final pathAbs = _absoluteFilePath(path);
    if (!_isImportableFile(pathAbs)) return null;
    final f = File(pathAbs);
    if (!f.existsSync()) return null;
    final dir = await _importsDir();
    final onDisk = p.basename(pathAbs);
    final name = p.basename(originalName);
    final id = _newId();
    final destName = '$id${p.extension(onDisk).toLowerCase()}';
    final dest = p.join(dir.path, destName);
    try {
      await _copyInRobust(pathAbs, dest);
    } catch (_) {
      return null;
    }
    final format = LibraryItem.formatFromPath(dest);
    final item = LibraryItem(
      id: id,
      filePath: dest,
      format: format,
      addedAt: DateTime.now(),
      originalName: name,
      collectionId: collectionId,
      collectionTitle: collectionTitle,
    );
    return item;
  }

  Future<LibraryItem?> _copyInFromBytes(
    Uint8List bytes,
    String originalName, {
    String? collectionId,
    String? collectionTitle,
  }) async {
    if (originalName.isEmpty) return null;
    if (!_isImportableFile(originalName)) return null;
    final dir = await _importsDir();
    final name = p.basename(originalName);
    final id = _newId();
    final destName = '$id${p.extension(name).toLowerCase()}';
    final dest = p.join(dir.path, destName);
    try {
      await File(dest).writeAsBytes(bytes, flush: true);
    } catch (_) {
      return null;
    }
    final format = LibraryItem.formatFromPath(dest);
    final item = LibraryItem(
      id: id,
      filePath: dest,
      format: format,
      addedAt: DateTime.now(),
      originalName: name,
      collectionId: collectionId,
      collectionTitle: collectionTitle,
    );
    return item;
  }

  /// Gera capas em segundo plano (um de cada vez, com pausa para o UI).
  Future<void> fillMissingCovers(
    Iterable<LibraryItem> items, {
    void Function(LibraryItem item)? onCoverApplied,
    ImportProgressCallback? onProgress,
  }) async {
    final todo = items
        .where((e) => e.filePath.isNotEmpty)
        .where((e) => e.originalName != '.folder_placeholder')
        .where((e) => e.coverPath == null || e.coverPath!.isEmpty)
        .toList();
    final total = todo.length;
    if (total == 0) return;
    onProgress?.call(0, total);
    for (var i = 0; i < todo.length; i++) {
      final item = todo[i];
      try {
        final path = await _cover.buildCover(item);
        if (path != null) item.coverPath = path;
      } catch (_) {}
      onCoverApplied?.call(item);
      onProgress?.call(i + 1, total);
      await _yieldUi();
    }
  }

  static Future<List<String>> listImportableFilesInTree(String rootPath) async {
    final root = Directory(rootPath);
    if (!root.existsSync()) return [];
    final out = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isImportableFile(entity.path)) {
        out.add(_absoluteFilePath(entity.path));
      }
    }
    out.sort();
    return out;
  }

  Future<List<LibraryItem>> _importPaths(
    List<String> pathsAbs, {
    String? collectionId,
    String? collectionTitle,
    ImportProgressCallback? onProgress,
  }) async {
    final total = pathsAbs.length;
    onProgress?.call(0, total);
    final out = <LibraryItem>[];
    for (var i = 0; i < pathsAbs.length; i++) {
      final item = await _copyIn(
        pathsAbs[i],
        originalName: p.basename(pathsAbs[i]),
        collectionId: collectionId,
        collectionTitle: collectionTitle,
      );
      if (item != null) out.add(item);
      onProgress?.call(i + 1, total);
      await _yieldUi();
    }
    return out;
  }

  Future<List<LibraryItem>> _importPlatformFiles(
    List<PlatformFile> files, {
    String? collectionId,
    String? collectionTitle,
    ImportProgressCallback? onProgress,
  }) async {
    final work = <({String? path, Uint8List? bytes, String name})>[];
    for (final f in files) {
      final pth = f.path;
      if (pth != null && pth.isNotEmpty) {
        final abs = _absoluteFilePath(pth);
        if (!_isImportableFile(abs)) continue;
        work.add((
          path: abs,
          bytes: null,
          name: f.name.isNotEmpty ? f.name : p.basename(abs),
        ));
        continue;
      }
      if (f.bytes != null &&
          f.bytes!.isNotEmpty &&
          f.name.isNotEmpty &&
          _isImportableFile(f.name)) {
        work.add((path: null, bytes: f.bytes, name: f.name));
      }
    }
    final total = work.length;
    onProgress?.call(0, total);
    final out = <LibraryItem>[];
    for (var i = 0; i < work.length; i++) {
      final w = work[i];
      final LibraryItem? item;
      if (w.path != null) {
        item = await _copyIn(
          w.path!,
          originalName: w.name,
          collectionId: collectionId,
          collectionTitle: collectionTitle,
        );
      } else {
        item = await _copyInFromBytes(
          w.bytes!,
          w.name,
          collectionId: collectionId,
          collectionTitle: collectionTitle,
        );
      }
      if (item != null) out.add(item);
      onProgress?.call(i + 1, total);
      await _yieldUi();
    }
    return out;
  }

  Future<List<PlatformFile>?> pickFiles({String? dialogTitle}) async {
    final r = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _exts,
      dialogTitle: dialogTitle,
    );
    if (r == null || r.files.isEmpty) return null;
    return r.files;
  }

  Future<List<LibraryItem>> processPickedFiles(
    List<PlatformFile> files, {
    String? collectionId,
    String? collectionTitle,
    ImportProgressCallback? onProgress,
  }) =>
      _importPlatformFiles(
        files,
        collectionId: collectionId,
        collectionTitle: collectionTitle,
        onProgress: onProgress,
      );

  Future<List<LibraryItem>> importFiles({ImportProgressCallback? onProgress}) async {
    final files = await pickFiles();
    if (files == null) return [];
    return processPickedFiles(files, onProgress: onProgress);
  }

  Future<List<LibraryItem>> importIntoCollection({
    required String collectionId,
    required String collectionTitle,
    ImportProgressCallback? onProgress,
  }) async {
    final files = await pickFiles();
    if (files == null) return [];
    return processPickedFiles(
      files,
      collectionId: collectionId,
      collectionTitle: collectionTitle,
      onProgress: onProgress,
    );
  }

  Future<List<LibraryItem>> importAsCollection(
    String collectionTitle, {
    ImportProgressCallback? onProgress,
  }) async {
    final files = await pickFiles(
      dialogTitle: 'Selecionar ficheiros para "$collectionTitle"',
    );
    if (files == null) return [];
    final collectionId = 'col_${DateTime.now().microsecondsSinceEpoch}';
    return processPickedFiles(
      files,
      collectionId: collectionId,
      collectionTitle: collectionTitle,
      onProgress: onProgress,
    );
  }

  /// Importa todos os ficheiros suportados dentro de [dirPath] (recursivo).
  /// [collectionTitle] vazio ou null: itens avulsos na biblioteca.
  Future<List<LibraryItem>> importFromDirectoryPath(
    String dirPath, {
    String? collectionTitle,
    ImportProgressCallback? onProgress,
  }) async {
    final paths = await listImportableFilesInTree(dirPath);
    if (paths.isEmpty) return [];
    final t = collectionTitle?.trim();
    if (t == null || t.isEmpty) {
      return _importPaths(paths, onProgress: onProgress);
    }
    final collectionId = 'col_${DateTime.now().microsecondsSinceEpoch}';
    return _importPaths(
      paths,
      collectionId: collectionId,
      collectionTitle: t,
      onProgress: onProgress,
    );
  }
}
