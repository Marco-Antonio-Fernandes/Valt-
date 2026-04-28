import 'package:path/path.dart' as p;

/// Separa título base (saga) e número de edição a partir do nome do ficheiro.
/// [stem] = nome sem extensão. Ordenação: [issueNumber] crescente (sem número = 0).
class ParsedComicName {
  const ParsedComicName({
    required this.sagaId,
    required this.sagaTitle,
    required this.issueNumber,
    required this.stem,
  });

  final String sagaId;
  final String sagaTitle;
  final int issueNumber;
  final String stem;
}

String _normKey(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_]+'), ' ')
      .trim();
}

/// Usa o nome de ficheiro real na importação (não o nome interno em `imports/`).
ParsedComicName parseComicOriginalName(String originalName) {
  return parseComicFileName(
    p.join('f', p.basename(originalName)),
  );
}

/// Tenta, por ordem: "Nome - 12", "Nome #3", "Nome 05", "Nome12".
ParsedComicName parseComicFileName(String filePath) {
  final stem = p.basenameWithoutExtension(filePath);

  var re = RegExp(
    r'^(.+?)[\s\-#_]+(\d{1,5})\s*$',
    caseSensitive: false,
  );
  var m = re.firstMatch(stem);
  if (m != null) {
    final base = m[1]!.trim();
    final n = int.tryParse(m[2]!) ?? 0;
    final title = _titleCaseIfNeeded(base);
    return ParsedComicName(
      sagaId: _normKey(base),
      sagaTitle: title,
      issueNumber: n,
      stem: stem,
    );
  }

  re = RegExp(r'^(.+?)(\d{1,5})\s*$', caseSensitive: false);
  m = re.firstMatch(stem);
  if (m != null) {
    final base = m[1]!.trim();
    if (base.isNotEmpty) {
      final n = int.tryParse(m[2]!) ?? 0;
      final title = _titleCaseIfNeeded(base);
      return ParsedComicName(
        sagaId: _normKey(base),
        sagaTitle: title,
        issueNumber: n,
        stem: stem,
      );
    }
  }

  re = RegExp(
    r'^\s*(\d{1,5})[\s\-_.#]+(.+?)\s*$',
    caseSensitive: false,
  );
  m = re.firstMatch(stem);
  if (m != null) {
    final n = int.tryParse(m[1]!) ?? 0;
    final base = m[2]!.trim();
    if (base.isNotEmpty && n > 0) {
      final title = _titleCaseIfNeeded(base);
      return ParsedComicName(
        sagaId: _normKey(base),
        sagaTitle: title,
        issueNumber: n,
        stem: stem,
      );
    }
  }

  final digitRuns = RegExp(r'\d{1,6}').allMatches(stem).toList();
  if (digitRuns.isNotEmpty) {
    final last = digitRuns.last;
    final n = int.tryParse(last.group(0)!) ?? 0;
    if (n > 0) {
      var baseKey = stem
          .replaceAll(RegExp(r'\d+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (baseKey.isEmpty) baseKey = stem;
      final title = _titleCaseIfNeeded(baseKey);
      return ParsedComicName(
        sagaId: _normKey(baseKey),
        sagaTitle: title,
        issueNumber: n,
        stem: stem,
      );
    }
  }

  final title = _titleCaseIfNeeded(stem);
  return ParsedComicName(
    sagaId: _normKey(stem),
    sagaTitle: title,
    issueNumber: 0,
    stem: stem,
  );
}

String _titleCaseIfNeeded(String s) {
  if (s.isEmpty) return s;
  if (s != s.toLowerCase() && s != s.toUpperCase()) {
    return s;
  }
  return s
      .split(RegExp(r'\s+'))
      .map((w) {
        if (w.isEmpty) return w;
        return w[0].toUpperCase() + w.substring(1).toLowerCase();
      })
      .join(' ');
}
