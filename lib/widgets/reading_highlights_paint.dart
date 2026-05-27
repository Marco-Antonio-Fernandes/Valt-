import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/reading_highlight.dart';

/// Junta bounding boxes por fragmento (palavras) na mesma linha visual,
/// cobrindo espaços como um só bloco fluido sem emendas entre palavras.
List<Rect> mergeAdjacentPdfHighlightRects(List<Rect> rects) {
  if (rects.length <= 1) return List<Rect>.from(rects);

  final sortedHeights = rects.map((r) => r.height).toList()..sort();
  final medH = sortedHeights[sortedHeights.length ~/ 2];
  if (medH <= 0) return List<Rect>.from(rects);
  final lineTol = medH * 0.42;
  final gapSlop = medH * 1.65;

  var clusters =
      rects.map((r) => <Rect>[r]).toList();
  bool mergedCluster;
  do {
    mergedCluster = false;
    outer:
    for (var i = 0; i < clusters.length; i++) {
      for (var j = i + 1; j < clusters.length; j++) {
        if (_fragmentsOnSameTextLine(clusters[i], clusters[j], lineTol)) {
          clusters[i].addAll(clusters[j]);
          clusters.removeAt(j);
          mergedCluster = true;
          break outer;
        }
      }
    }
  } while (mergedCluster);

  final result = <Rect>[];
  for (final cluster in clusters) {
    result.addAll(_mergeHorizontallyBridgingGaps(cluster, gapSlop));
  }
  return result;
}

bool _fragmentsOnSameTextLine(List<Rect> a, List<Rect> b, double lineTol) {
  for (final ra in a) {
    for (final rb in b) {
      if (_rectPairSameLine(ra, rb, lineTol)) return true;
    }
  }
  return false;
}

bool _rectPairSameLine(Rect a, Rect b, double lineTol) {
  final overlapY = math.max(
    0.0,
    math.min(a.bottom, b.bottom) - math.max(a.top, b.top),
  );
  final minH = math.min(a.height, b.height);
  if (minH > 0 && overlapY / minH >= 0.28) return true;
  return (a.center.dy - b.center.dy).abs() <= lineTol;
}

List<Rect> _mergeHorizontallyBridgingGaps(List<Rect> cluster, double gapSlop) {
  cluster.sort((a, b) {
    final c = (a.center.dy).compareTo(b.center.dy);
    if (c != 0) return c;
    return a.left.compareTo(b.left);
  });
  final runs = <List<Rect>>[];
  List<Rect> run = [cluster.first];
  for (var k = 1; k < cluster.length; k++) {
    final r = cluster[k];
    final prev = run.last;
    final gap = r.left - prev.right;
    if (gap <= gapSlop &&
        math.max(0.0, math.min(prev.bottom, r.bottom) - math.max(prev.top, r.top)) >
            math.min(prev.height, r.height) * 0.22) {
      run.add(r);
    } else {
      runs.add(run);
      run = [r];
    }
  }
  runs.add(run);

  final out = <Rect>[];
  for (final seg in runs) {
    Rect u = seg.first;
    for (final r in seg.skip(1)) {
      u = Rect.fromLTRB(
        math.min(u.left, r.left),
        math.min(u.top, r.top),
        math.max(u.right, r.right),
        math.max(u.bottom, r.bottom),
      );
    }
    out.add(u);
  }
  return out;
}

/// Desenha [ReadingHighlight]s na página, usando [structuredByPage] em cache.
void paintReadingHighlightsOnPdfPage({
  required ui.Canvas canvas,
  required Rect pageRect,
  required PdfPage page,
  required List<ReadingHighlight> highlights,
  required Map<int, PdfPageText> structuredByPage,
  double rectInflate = 0.45,
}) {
  for (final h in highlights.where((x) => x.pageNumber == page.pageNumber)) {
    final structured = structuredByPage[page.pageNumber];
    if (structured == null) continue;
    final len = structured.fullText.length;
    final s = h.start.clamp(0, len);
    final e = h.end.clamp(s, len);
    if (s >= e) continue;

    final base = Color(h.highlightArgb);
    final fill = ui.Paint()
      ..color = base.withValues(alpha: 0.42);
    final stroke = ui.Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.85
      ..color =
          Color.lerp(base, Colors.black, 0.38)?.withValues(alpha: 0.88) ??
              base.withValues(alpha: 0.88);

    final range =
        PdfPageTextRange(pageText: structured, start: s, end: e);

    final rawRects = [
      for (final br in range.enumerateFragmentBoundingRects())
        br.bounds
            .toRect(page: page, scaledPageSize: pageRect.size)
            .translate(pageRect.left, pageRect.top),
    ];
    final bandRects =
        mergeAdjacentPdfHighlightRects(rawRects).map((r) => r.inflate(rectInflate));

    for (final r in bandRects) {
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }
}
