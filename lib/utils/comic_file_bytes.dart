import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

Future<Uint8List> readFileStart(String path, int n) async {
  if (kIsWeb) return Uint8List(0);
  final f = await File(path).open();
  try {
    return await f.read(n);
  } finally {
    await f.close();
  }
}

bool isZipMagic(Uint8List b) {
  if (b.length < 2) return false;
  return b[0] == 0x50 && b[1] == 0x4b;
}

/// RAR4: Rar!\x1a\x07\x00  |  RAR5: Rar!\x1a\x07\x01\x00
bool isRarMagic(Uint8List b) {
  if (b.length < 7) return false;
  return b[0] == 0x52 &&
      b[1] == 0x61 &&
      b[2] == 0x72 &&
      b[3] == 0x21 &&
      b[4] == 0x1a &&
      b[5] == 0x07;
}

bool isRar5Magic(Uint8List b) {
  if (b.length < 8) return false;
  return isRarMagic(b) && b[6] == 0x01 && b[7] == 0x00;
}

enum ArchiveKind { zip, rar4, rar5, unknown }

Future<ArchiveKind> detectArchiveKind(String path) async {
  if (kIsWeb) return ArchiveKind.unknown;
  final b = await readFileStart(path, 8);
  if (isZipMagic(b)) return ArchiveKind.zip;
  if (isRar5Magic(b)) return ArchiveKind.rar5;
  if (isRarMagic(b)) return ArchiveKind.rar4;
  return ArchiveKind.unknown;
}

Future<bool> fileLooksLikeZipAtPath(String path) async {
  if (kIsWeb) return false;
  final b = await readFileStart(path, 4);
  return isZipMagic(b);
}

