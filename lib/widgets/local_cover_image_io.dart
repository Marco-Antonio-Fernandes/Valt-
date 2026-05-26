import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

Widget localCoverImage({
  required String? path,
  required Widget fallback,
  BoxFit fit = BoxFit.cover,
  bool gaplessPlayback = true,
  bool heroBackdropLayout = false,
}) {
  final p = path;
  if (p == null || p.isEmpty) return fallback;
  final f = File(p);
  if (!f.existsSync()) return fallback;

  if (!heroBackdropLayout) {
    return Image.file(
      f,
      fit: fit,
      gaplessPlayback: gaplessPlayback,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }

  return LayoutBuilder(
    builder: (context, bc) {
      final inset =
          (bc.biggest.shortestSide * 0.09).clamp(12.0, 32.0).toDouble();
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform.scale(
              scale: 1.22,
              alignment: Alignment.center,
              filterQuality: FilterQuality.low,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Image.file(
                  f,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  gaplessPlayback: gaplessPlayback,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 0.95,
                  colors: [
                    Colors.black.withValues(alpha: 0.06),
                    Colors.black.withValues(alpha: 0.48),
                  ],
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: EdgeInsets.all(inset),
                child: FractionallySizedBox(
                  widthFactor: 0.86,
                  heightFactor: 0.92,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                          width: 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(17),
                        child: Image.file(
                          f,
                          fit: BoxFit.cover,
                          gaplessPlayback: gaplessPlayback,
                          filterQuality: FilterQuality.high,
                          errorBuilder: (context, error, stackTrace) =>
                              fallback,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
