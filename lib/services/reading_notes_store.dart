import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_book_annotations.dart';
import '../models/reading_highlight.dart';
import '../models/reading_note.dart';

/// Persistência das notas e grifos de leitura por [LibraryItem.id].
///
/// JSON: por livro pode ser formato legado `[{nota…}]` ou objeto
/// `{ "notes":[…], "highlights":[…] }`.
class ReadingNotesStore {
  static const _fileName = 'reading_notes.json';
  static const _prefsJsonKey = 'vault_reading_notes_json_v1';

  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File(p.join(d.path, _fileName));
  }

  ReadingBookAnnotations _parseBookEntry(dynamic raw) {
    if (raw is List<dynamic>) {
      final notes = <ReadingNote>[];
      for (final x in raw) {
        if (x is! Map<String, dynamic>) continue;
        try {
          notes.add(ReadingNote.fromJson(x));
        } catch (_) {}
      }
      return ReadingBookAnnotations(notes: notes, highlights: []);
    }
    if (raw is Map<String, dynamic>) {
      final notesRaw = raw['notes'];
      final hilitesRaw = raw['highlights'];
      final notes = <ReadingNote>[];
      final highlights = <ReadingHighlight>[];
      if (notesRaw is List<dynamic>) {
        for (final x in notesRaw) {
          if (x is! Map<String, dynamic>) continue;
          try {
            notes.add(ReadingNote.fromJson(x));
          } catch (_) {}
        }
      }
      if (hilitesRaw is List<dynamic>) {
        for (final x in hilitesRaw) {
          if (x is! Map<String, dynamic>) continue;
          try {
            highlights.add(ReadingHighlight.fromJson(x));
          } catch (_) {}
        }
      }
      return ReadingBookAnnotations(notes: notes, highlights: highlights);
    }
    return const ReadingBookAnnotations(notes: [], highlights: []);
  }

  Future<Map<String, ReadingBookAnnotations>> loadAllAnnotated() async {
    Map<String, dynamic>? root;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsJsonKey);
      if (raw == null || raw.trim().isEmpty) return {};
      try {
        root = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return {};
      }
    } else {
      final f = await _file();
      if (!f.existsSync()) return {};
      try {
        root = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        return {};
      }
    }

    final out = <String, ReadingBookAnnotations>{};
    for (final e in root.entries) {
      out[e.key] = _parseBookEntry(e.value);
    }
    return out;
  }

  Map<String, dynamic> _annotationsToWritable(ReadingBookAnnotations a) =>
      <String, dynamic>{
        'notes': a.notes.map((n) => n.toJson()).toList(),
        'highlights': a.highlights.map((h) => h.toJson()).toList(),
      };

  Future<void> _saveRoot(Map<String, ReadingBookAnnotations> all) async {
    final enc = jsonEncode(
      all.map((k, v) => MapEntry(k, _annotationsToWritable(v))),
    );
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsJsonKey, enc);
      return;
    }
    final f = await _file();
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    await f.writeAsString(enc);
  }

  Future<ReadingBookAnnotations> book(String libraryItemId) async {
    final all = await loadAllAnnotated();
    return all[libraryItemId] ??
        const ReadingBookAnnotations(notes: [], highlights: []);
  }

  Future<List<ReadingNote>> notesForBook(String libraryItemId) async =>
      (await book(libraryItemId)).notes;

  Future<List<ReadingHighlight>> highlightsForBook(String libraryItemId) async =>
      (await book(libraryItemId)).highlights;

  /// Substitui só as notas; mantém os grifos já guardados para o mesmo livro.
  Future<void> saveNotesForBook(
    String libraryItemId,
    List<ReadingNote> notes,
  ) async {
    final all = await loadAllAnnotated();
    final prev = all[libraryItemId] ??
        const ReadingBookAnnotations(notes: [], highlights: []);
    all[libraryItemId] =
        ReadingBookAnnotations(notes: notes, highlights: prev.highlights);
    await _saveRoot(all);
  }

  /// Grava notas + grifos de uma só vez (substitui a entrada do livro).
  Future<void> saveAnnotationsForBook(
    String libraryItemId,
    ReadingBookAnnotations data,
  ) async {
    final all = await loadAllAnnotated();
    all[libraryItemId] = data;
    await _saveRoot(all);
  }
}
