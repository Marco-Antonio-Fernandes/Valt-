import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/library_item.dart';

class LibraryStore {
  static const _fileName = 'library.json';

  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File(p.join(d.path, _fileName));
  }

  Future<List<LibraryItem>> load() async {
    final f = await _file();
    if (!f.existsSync()) return [];
    try {
      final list = (jsonDecode(await f.readAsString()) as List<dynamic>)
          .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<LibraryItem> items) async {
    final f = await _file();
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    await f.writeAsString(
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}
