import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_item.dart';

class LibraryStore {
  static const _fileName = 'library.json';
  /// Web não usa ficheiros do disco mesmo caminho que mobile.
  static const _prefsJsonKey = 'vault_library_items_json_v1';

  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File(p.join(d.path, _fileName));
  }

  Future<List<LibraryItem>> load() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsJsonKey);
      if (raw == null || raw.trim().isEmpty) return [];
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .map((e) => LibraryItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        return [];
      }
    }
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
    final encoded =
        jsonEncode(items.map((e) => e.toJson()).toList());
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsJsonKey, encoded);
      return;
    }
    final f = await _file();
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    await f.writeAsString(encoded);
  }
}
