import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rar/rar.dart';

import '../models/library_item.dart';
import '../utils/comic_file_bytes.dart';
import 'rar7_util.dart';

bool isImagePathName(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.jpg') ||
      n.endsWith('.jpeg') ||
      n.endsWith('.png') ||
      n.endsWith('.webp') ||
      n.endsWith('.gif') ||
      n.endsWith('.bmp');
}

sealed class ComicPageSource {
  int get pageCount;
  Future<Uint8List> pageAt(int index);
  Future<void> dispose();

  static Future<ComicPageSource> open(LibraryItem item) async {
    if (item.format == BookFormat.pdf) {
      throw UnsupportedError('use PdfViewer for PDF');
    }

    final path = item.filePath;
    final errors = <String>[];

    // 1) 7z nativo — abre ZIP, RAR, 7z, etc. de forma confiável
    try {
      final result = await ComicPageSourceNative.fromFile(item.id, path);
      if (result != null) return result;
    } catch (e) {
      errors.add('7z: $e');
    }

    // 2) ZIP via Dart (fallback se 7z não estiver instalado)
    try {
      return await ComicPageSourceZip.fromFile(path);
    } catch (e) {
      errors.add('ZIP: $e');
    }

    // 3) TAR
    try {
      return await ComicPageSourceTar.fromFile(path);
    } catch (e) {
      errors.add('TAR: $e');
    }

    // 4) Plugin rar (Android/iOS/macOS — JUnRar)
    try {
      final src = await ComicPageSourceRarPlugin.fromFile(item.id, path);
      if (src != null) return src;
      errors.add('RarPlugin: retornou null');
    } catch (e) {
      errors.add('RarPlugin: $e');
    }

    String hint = 'No Windows, instala o 7-Zip e reinicia a app.';
    try {
      final kind = await detectArchiveKind(path);
      if (kind == ArchiveKind.rar5) {
        hint = 'Este ficheiro é RAR5. Precisa do 7-Zip ou WinRAR instalado.';
      } else if (kind == ArchiveKind.rar4) {
        hint = 'Este ficheiro é RAR4. Precisa do 7-Zip ou WinRAR instalado.';
      } else if (kind == ArchiveKind.zip) {
        hint = 'Ficheiro ZIP detectado mas nenhum método conseguiu extrair.';
      }
    } catch (_) {}

    throw ComicOpenError(
      'Não foi possível abrir este ficheiro.\n\n'
      '$hint\n'
      'Detalhes:\n${errors.join('\n')}',
    );
  }
}

class ComicOpenError implements Exception {
  ComicOpenError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ──────────────────────── ZIP ────────────────────────

class ComicPageSourceZip extends ComicPageSource {
  ComicPageSourceZip._(this._pages);

  final List<Uint8List> _pages;

  static Future<ComicPageSourceZip> fromFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final pages = await compute(_decodeZipImages, bytes);
    if (pages.isEmpty) {
      throw StateError('Nenhuma imagem no arquivo ZIP');
    }
    return ComicPageSourceZip._(pages);
  }

  static List<Uint8List> _decodeZipImages(Uint8List bytes) {
    final arch = ZipDecoder().decodeBytes(bytes);
    final entries = <(String, Uint8List)>[];
    for (final f in arch.files) {
      if (!f.isFile) continue;
      if (isImagePathName(f.name)) {
        final data = f.readBytes();
        if (data != null && data.isNotEmpty) {
          entries.add((f.name.toLowerCase(), data));
        }
      }
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return entries.map((e) => e.$2).toList();
  }

  @override
  int get pageCount => _pages.length;

  @override
  Future<Uint8List> pageAt(int index) async => _pages[index];

  @override
  Future<void> dispose() async {}
}

// ──────────────────────── TAR ────────────────────────

class ComicPageSourceTar extends ComicPageSource {
  ComicPageSourceTar._(this._pages);

  final List<Uint8List> _pages;

  static Future<ComicPageSourceTar> fromFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final pages = await compute(_decodeTarImages, bytes);
    if (pages.isEmpty) {
      throw StateError('Nenhuma imagem no arquivo TAR');
    }
    return ComicPageSourceTar._(pages);
  }

  static List<Uint8List> _decodeTarImages(Uint8List bytes) {
    final arch = TarDecoder().decodeBytes(bytes);
    final entries = <(String, Uint8List)>[];
    for (final f in arch.files) {
      if (!f.isFile) continue;
      if (isImagePathName(f.name)) {
        final data = f.readBytes();
        if (data != null && data.isNotEmpty) {
          entries.add((f.name.toLowerCase(), data));
        }
      }
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return entries.map((e) => e.$2).toList();
  }

  @override
  int get pageCount => _pages.length;

  @override
  Future<Uint8List> pageAt(int index) async => _pages[index];

  @override
  Future<void> dispose() async {}
}

// ──────────────── 7z / UnRAR nativo ─────────────────

class ComicPageSourceNative extends ComicPageSource {
  ComicPageSourceNative._(this._paths);

  final List<String> _paths;

  static Future<ComicPageSourceNative?> fromFile(String id, String archivePath) async {
    if (kIsWeb) return null;
    final tmp = await getTemporaryDirectory();
    final base = p.join(tmp.path, 'cbr_cache', id);
    final dir = Directory(base);

    // Reutiliza cache se já tiver sido extraído antes
    if (dir.existsSync()) {
      final cached = await _collectImages(dir);
      if (cached.isNotEmpty) return ComicPageSourceNative._(cached);
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    final result = await tryNativeExtract(archivePath, base);
    if (!result.ok) {
      throw StateError('Native falhou: ${result.detail}');
    }

    final all = await _collectImages(dir);
    if (all.isEmpty) {
      throw StateError('Native extraiu mas 0 imagens encontradas');
    }
    return ComicPageSourceNative._(all);
  }

  static Future<List<String>> _collectImages(Directory dir) async {
    final all = <String>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (isImagePathName(e.path)) all.add(e.path);
    }
    all.sort(
      (a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return all;
  }

  @override
  int get pageCount => _paths.length;

  @override
  Future<Uint8List> pageAt(int index) async {
    return File(_paths[index]).readAsBytes();
  }

  @override
  Future<void> dispose() async {}
}

// ──────────────── Plugin rar (móvel) ─────────────────

class ComicPageSourceRarPlugin extends ComicPageSource {
  ComicPageSourceRarPlugin._(this._paths);

  final List<String> _paths;

  static Future<ComicPageSourceRarPlugin?> fromFile(String id, String rarPath) async {
    final tmp = await getTemporaryDirectory();
    final base = p.join(tmp.path, 'cbr_cache', id);
    final dir = Directory(base);

    if (dir.existsSync()) {
      final cached = await ComicPageSourceNative._collectImages(dir);
      if (cached.isNotEmpty) return ComicPageSourceRarPlugin._(cached);
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    try {
      final result = await Rar.extractRarFile(
        rarFilePath: rarPath,
        destinationPath: base,
      );
      if (result['success'] != true) {
        throw StateError('rar plugin: success=${result['success']}, msg=${result['message'] ?? result}');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('rar plugin crash: $e');
    }

    final all = <String>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (isImagePathName(e.path)) {
        all.add(e.path);
      }
    }
    all.sort(
      (a, b) => p.basename(a).toLowerCase().compareTo(
            p.basename(b).toLowerCase(),
          ),
    );
    if (all.isEmpty) {
      throw StateError('rar plugin extraiu mas 0 imagens encontradas');
    }
    return ComicPageSourceRarPlugin._(all);
  }

  @override
  int get pageCount => _paths.length;

  @override
  Future<Uint8List> pageAt(int index) async {
    return File(_paths[index]).readAsBytes();
  }

  @override
  Future<void> dispose() async {}
}
