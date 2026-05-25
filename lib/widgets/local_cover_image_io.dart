import 'dart:io';

import 'package:flutter/material.dart';

Widget localCoverImage({
  required String? path,
  required Widget fallback,
  BoxFit fit = BoxFit.cover,
  bool gaplessPlayback = true,
}) {
  final p = path;
  if (p == null || p.isEmpty) return fallback;
  final f = File(p);
  if (!f.existsSync()) return fallback;
  return Image.file(
    f,
    fit: fit,
    gaplessPlayback: gaplessPlayback,
    errorBuilder: (context, error, stackTrace) => fallback,
  );
}
