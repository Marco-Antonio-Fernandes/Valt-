import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool _isComicImagePath(String path) {
  final n = path.toLowerCase();
  return n.endsWith('.jpg') ||
      n.endsWith('.jpeg') ||
      n.endsWith('.png') ||
      n.endsWith('.webp') ||
      n.endsWith('.gif') ||
      n.endsWith('.bmp');
}

String? _cached7z;

Future<String?> find7zExecutable() async {
  if (kIsWeb) return null;
  if (_cached7z != null && File(_cached7z!).existsSync()) return _cached7z;

  if (Platform.isWindows) {
    final candidates = <String>[
      r'C:\Program Files\7-Zip\7z.exe',
      r'C:\Program Files (x86)\7-Zip\7z.exe',
      r'C:\ProgramData\chocolatey\bin\7z.exe',
    ];

    final localApp = Platform.environment['LOCALAPPDATA'] ?? '';
    if (localApp.isNotEmpty) {
      candidates.addAll([
        p.join(localApp, 'Programs', '7-Zip', '7z.exe'),
        p.join(localApp, r'Microsoft\WinGet\Links\7z.exe'),
      ]);
    }
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    if (userProfile.isNotEmpty) {
      candidates.addAll([
        p.join(userProfile, 'scoop', 'apps', '7zip', 'current', '7z.exe'),
        p.join(userProfile, 'scoop', 'shims', '7z.exe'),
      ]);
    }
    final appSupport = await _appCacheDir();
    candidates.add(p.join(appSupport, '7z', '7z.exe'));

    for (final c in candidates) {
      if (File(c).existsSync()) {
        _cached7z = c;
        return c;
      }
    }
    for (final name in ['7z', '7z.exe', '7zz.exe']) {
      try {
        final r = await Process.run('where', [name], runInShell: true);
        if (r.exitCode == 0) {
          for (final line in (r.stdout as String).split(RegExp(r'[\r\n]+'))) {
            final s = line.trim();
            if (s.isNotEmpty && File(s).existsSync()) {
              _cached7z = s;
              return s;
            }
          }
        }
      } catch (_) {}
    }
  } else {
    for (final n in ['7zz', '7z', '7za']) {
      try {
        final r = await Process.run(n, ['-h']);
        if (r.exitCode == 0) {
          _cached7z = n;
          return n;
        }
      } catch (_) {}
    }
  }
  return null;
}

Future<String?> _findUnRar() async {
  if (kIsWeb) return null;
  if (Platform.isWindows) {
    final candidates = <String>[
      r'C:\Program Files\WinRAR\UnRAR.exe',
      r'C:\Program Files (x86)\WinRAR\UnRAR.exe',
      r'C:\Program Files\WinRAR\WinRAR.exe',
    ];
    final localApp = Platform.environment['LOCALAPPDATA'] ?? '';
    if (localApp.isNotEmpty) {
      candidates.add(p.join(localApp, 'Programs', 'WinRAR', 'UnRAR.exe'));
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    try {
      final r = await Process.run('where', ['UnRAR.exe'], runInShell: true);
      if (r.exitCode == 0) {
        final s = (r.stdout as String).trim().split(RegExp(r'[\r\n]+')).first.trim();
        if (s.isNotEmpty && File(s).existsSync()) return s;
      }
    } catch (_) {}
  } else {
    for (final n in ['unrar', 'rar']) {
      try {
        final r = await Process.run('which', [n]);
        if (r.exitCode == 0) return n;
      } catch (_) {}
    }
  }
  return null;
}

Future<String> _appCacheDir() async {
  final d = await getApplicationSupportDirectory();
  return d.path;
}

/// Tenta instalar 7-Zip automaticamente via winget (Windows 10/11).
Future<bool> tryAutoInstall7z() async {
  if (kIsWeb || !Platform.isWindows) return false;

  try {
    final r = await Process.run(
      'winget',
      [
        'install',
        '--id', '7zip.7zip',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent',
      ],
      runInShell: true,
    );
    if (r.exitCode == 0) {
      _cached7z = null;
      final z = await find7zExecutable();
      return z != null;
    }
  } catch (_) {}
  return false;
}

/// Abre a página de download do 7-Zip no browser.
Future<void> open7zDownloadPage() async {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', 'https://www.7-zip.org/download.html'], runInShell: true);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['https://www.7-zip.org/download.html']);
  } else {
    await Process.run('xdg-open', ['https://www.7-zip.org/download.html']);
  }
}

Future<void> _emptyDirectory(String path) async {
  final d = Directory(path);
  if (!d.existsSync()) return;
  await for (final e in d.list(followLinks: false)) {
    if (e is File) {
      try { await e.delete(); } catch (_) {}
    } else if (e is Directory) {
      try { await e.delete(recursive: true); } catch (_) {}
    }
  }
}

Future<bool> _dirHasImage(String root) async {
  await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (_isComicImagePath(e.path)) return true;
  }
  return false;
}

String _outArg(String dest) {
  var out = dest;
  if (!out.endsWith(Platform.pathSeparator)) {
    out = out + Platform.pathSeparator;
  }
  return out;
}

class NativeExtractResult {
  NativeExtractResult(this.ok, [this.detail = '']);
  final bool ok;
  final String detail;
}

Future<NativeExtractResult> _run7z(String sevenZ, String mode, String archivePath, String dest) async {
  if (!File(archivePath).existsSync()) {
    return NativeExtractResult(false, 'arquivo não existe: $archivePath');
  }
  final out = _outArg(dest);
  final r = await Process.run(sevenZ, [mode, '-y', archivePath, '-o$out']);
  if (r.exitCode != 0) {
    final stderr = (r.stderr as String? ?? '').trim();
    final stdout = (r.stdout as String? ?? '').trim();
    final msg = stderr.isNotEmpty ? stderr : stdout;
    return NativeExtractResult(false, '7z $mode exit=${r.exitCode}: $msg');
  }
  if (await _dirHasImage(dest)) return NativeExtractResult(true);
  return NativeExtractResult(false, '7z $mode ok mas nenhuma imagem encontrada');
}

Future<NativeExtractResult> _runUnRar(String unrar, String rarPath, String dest) async {
  if (!File(rarPath).existsSync()) {
    return NativeExtractResult(false, 'arquivo não existe: $rarPath');
  }
  if (!Directory(dest).existsSync()) {
    await Directory(dest).create(recursive: true);
  }
  final d = _outArg(p.normalize(dest));
  final r = await Process.run(unrar, ['x', '-o+', '-y', rarPath, d]);
  if (r.exitCode != 0) {
    final stderr = (r.stderr as String? ?? '').trim();
    final stdout = (r.stdout as String? ?? '').trim();
    final msg = stderr.isNotEmpty ? stderr : stdout;
    return NativeExtractResult(false, 'UnRAR exit=${r.exitCode}: $msg');
  }
  if (await _dirHasImage(dest)) return NativeExtractResult(true);
  return NativeExtractResult(false, 'UnRAR ok mas nenhuma imagem encontrada');
}

/// Cadeia completa: 7z x → 7z e → UnRAR → auto-install 7z → retry.
/// Retorna (true, '') se OK, ou (false, detalhes) se falhou.
Future<NativeExtractResult> tryNativeExtract(String archivePath, String dest) async {
  if (kIsWeb) return NativeExtractResult(false, 'Não disponível na web');
  await _emptyDirectory(dest);
  if (!Directory(dest).existsSync()) {
    await Directory(dest).create(recursive: true);
  }

  final details = <String>[];

  var z = await find7zExecutable();
  if (z != null) {
    var r = await _run7z(z, 'x', archivePath, dest);
    if (r.ok) return r;
    details.add(r.detail);
    await _emptyDirectory(dest);

    r = await _run7z(z, 'e', archivePath, dest);
    if (r.ok) return r;
    details.add(r.detail);
    await _emptyDirectory(dest);
  } else {
    details.add('7-Zip não encontrado');
  }

  final u = await _findUnRar();
  if (u != null) {
    final r = await _runUnRar(u, archivePath, dest);
    if (r.ok) return r;
    details.add(r.detail);
    await _emptyDirectory(dest);
  } else {
    details.add('UnRAR não encontrado');
  }

  if (z == null && Platform.isWindows) {
    final installed = await tryAutoInstall7z();
    if (installed) {
      z = await find7zExecutable();
      if (z != null) {
        var r = await _run7z(z, 'x', archivePath, dest);
        if (r.ok) return r;
        details.add('retry ${r.detail}');
        await _emptyDirectory(dest);

        r = await _run7z(z, 'e', archivePath, dest);
        if (r.ok) return r;
        details.add('retry ${r.detail}');
      }
    } else {
      details.add('auto-install 7z falhou');
    }
  }

  return NativeExtractResult(false, details.join(' | '));
}

@Deprecated('Use tryNativeExtract instead')
Future<NativeExtractResult> tryNativeExtractCbr(String rarPath, String dest) =>
    tryNativeExtract(rarPath, dest);
