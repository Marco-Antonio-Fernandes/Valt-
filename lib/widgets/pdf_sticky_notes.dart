import 'dart:async' show Timer, unawaited;

import 'package:flutter/services.dart' show HapticFeedback;
import 'dart:math' show cos, sin;

import 'package:flutter/material.dart';

import '../models/reading_note.dart';

/// Papéis pós‑it — ARGB inteiro `(papel, texto)`.
const kPdfStickyPalettes = <(int paper, int ink)>[
  (0xFFFFF9E8, 0xFF4A3728),
  (0xFFF1F8E9, 0xFF1B5E20),
  (0xFFE8F4FC, 0xFF0D47A1),
  (0xFFFFEBF4, 0xFF880E4F),
  (0xFFF3E8F8, 0xFF4A148C),
  (0xFFFFF6E9, 0xFFE65100),
];

typedef PdfStickyPeekDeleted = Future<void> Function();
typedef PdfStickyPeekEditRequested = Future<void> Function();

/// Folha rápida: ver / editar / apagar. Sem botão ouvir — uso em leitura com voz.
Future<void> showPdfStickyPeekSheet({
  required BuildContext context,
  required ReadingNote note,
  required PdfStickyPeekEditRequested onEdit,
  required PdfStickyPeekDeleted onDeleted,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 22 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nota de rodapé · pág. ${note.pageNumber}',
              style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 12),
            _StickyPaperFrame(
              paperArgb: note.paperArgb,
              textArgb: note.textArgb,
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  note.body,
                  style: TextStyle(
                    color: Color(note.textArgb),
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await onEdit();
                  },
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('Editar'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await onDeleted();
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Apagar'),
                ),
              ],
            ),
            Text(
              'Arrasta o alfinete pelo PDF para mudar só a posição (não faz parte da leitura em voz).',
              style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
            ),
          ],
        ),
      );
    },
  );
}

class PdfStickyComposerResult {
  const PdfStickyComposerResult({
    required this.note,
    required this.createdNew,
  });

  final ReadingNote note;
  final bool createdNew;
}

/// Formulário de nota que devolve resultado via [Navigator.pop].
/// O [TextEditingController] vive no [State] — evita assert `_dependents` ao fechar a folha.
class PdfStickyComposerSheet extends StatefulWidget {
  const PdfStickyComposerSheet({
    super.key,
    required this.libraryItemId,
    required this.pageNumber,
    required this.anchorX,
    required this.anchorY,
    required this.initialPaperArgb,
    required this.initialTextArgb,
    this.existing,
    this.linkedPrepCharIndex,
  });

  final String libraryItemId;
  final int pageNumber;
  final double anchorX;
  final double anchorY;
  final int initialPaperArgb;
  final int initialTextArgb;
  final ReadingNote? existing;

  /// Texto preparado (`trim`…) — modo “Ler” intercala narração; `null` no leitor simples.
  final int? linkedPrepCharIndex;

  @override
  State<PdfStickyComposerSheet> createState() => _PdfStickyComposerSheetState();
}

class _PdfStickyComposerSheetState extends State<PdfStickyComposerSheet> {
  late TextEditingController _controller;
  late int _paper;
  late int _ink;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.existing?.body ?? '');
    _paper = widget.existing?.paperArgb ?? widget.initialPaperArgb;
    _ink = widget.existing?.textArgb ?? widget.initialTextArgb;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _paletteRow(BuildContext ctx) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < kPdfStickyPalettes.length; i++)
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => setState(() {
                _paper = kPdfStickyPalettes[i].$1;
                _ink = kPdfStickyPalettes[i].$2;
              }),
              customBorder: const CircleBorder(),
              child: Ink(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Color(kPdfStickyPalettes[i].$1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _paper == kPdfStickyPalettes[i].$1
                        ? Theme.of(ctx).colorScheme.primary
                        : Colors.black.withValues(alpha: 0.12),
                    width: _paper == kPdfStickyPalettes[i].$1 ? 2.8 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 4,
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _submit(BuildContext modalCtx) {
    final txt = _controller.text.trim();
    if (txt.isEmpty) {
      ScaffoldMessenger.of(modalCtx).showSnackBar(
        const SnackBar(content: Text('Escreve algo na nota.')),
      );
      return;
    }
    final ReadingNote out;
    if (widget.existing == null) {
      final nid =
          '${widget.libraryItemId}-n-${DateTime.now().microsecondsSinceEpoch}';
      out = ReadingNote(
        id: nid,
        libraryItemId: widget.libraryItemId,
        pageNumber: widget.pageNumber,
        anchorX: widget.anchorX,
        anchorY: widget.anchorY,
        paperArgb: _paper,
        textArgb: _ink,
        body: txt,
        createdAt: DateTime.now(),
        linkedPrepCharIndex: widget.linkedPrepCharIndex,
      );
      Navigator.pop(
        modalCtx,
        PdfStickyComposerResult(note: out, createdNew: true),
      );
    } else {
      out = widget.existing!.copyWith(
        body: txt,
        paperArgb: _paper,
        textArgb: _ink,
        linkedPrepCharIndex:
            widget.existing!.linkedPrepCharIndex ?? widget.linkedPrepCharIndex,
      );
      Navigator.pop(
        modalCtx,
        PdfStickyComposerResult(note: out, createdNew: false),
      );
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
    final w = MediaQuery.sizeOf(ctx).width;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.existing == null ? 'Nova nota' : 'Editar nota',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              Text(
                widget.linkedPrepCharIndex != null
                    ? 'Marcador ligado ao texto nesta página (nota de rodapé)'
                    : 'Arrasta para mover o marcador no ecrã',
                style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                onChanged: (_) => setState(() {}),
                autofocus: widget.existing == null,
                maxLines: 8,
                maxLength: 3000,
                decoration: InputDecoration(
                  hintText: 'Algo que queiras lembrar…',
                  border: const OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(ctx).colorScheme.primary,
                      width: 1.4,
                    ),
                  ),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Papel / tinta',
                style: Theme.of(ctx).textTheme.labelLarge,
              ),
              const SizedBox(height: 10),
              _paletteRow(ctx),
              const SizedBox(height: 10),
              Text(
                'Pré-visualização',
                style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Transform.rotate(
                  angle: -0.035,
                  child: _StickyPaperFrame(
                    paperArgb: _paper,
                    textArgb: _ink,
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: (w > 520 ? 340.0 : w - 96).clamp(180.0, 340),
                        child: Text(
                          _controller.text.trim().isEmpty
                              ? 'Texto aparece assim no papel'
                              : _controller.text,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.28,
                            color: Color(_ink),
                          ),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: Icon(
                  widget.existing == null
                      ? Icons.note_add_rounded
                      : Icons.save_rounded,
                ),
                label: Text(
                  widget.existing == null ? 'Guardar papelzinho' : 'Atualizar',
                ),
                onPressed: () => _submit(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<PdfStickyComposerResult?> pushPdfStickyComposer({
  required BuildContext context,
  required String libraryItemId,
  required int pageNumber,
  required double anchorX,
  required double anchorY,
  ReadingNote? existing,
  required int initialPaperArgb,
  required int initialTextArgb,
  int? linkedPrepCharIndex,
}) {
  return showModalBottomSheet<PdfStickyComposerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => PdfStickyComposerSheet(
      libraryItemId: libraryItemId,
      pageNumber: pageNumber,
      anchorX: anchorX,
      anchorY: anchorY,
      existing: existing,
      initialPaperArgb: initialPaperArgb,
      initialTextArgb: initialTextArgb,
      linkedPrepCharIndex: linkedPrepCharIndex,
    ),
  );
}

/// Normaliza centro do marcador (0–1) no Stack do leitor.
typedef PdfStickyAnchorResolver = Offset Function(ReadingNote n);

/// Post-its sobre o viewport do leitor PDF (coords normalizados 0–1 ao corpo Stack).
class PdfStickyNotesViewport extends StatelessWidget {
  const PdfStickyNotesViewport({
    super.key,
    required this.notesForCurrentPage,
    required this.anchorNormalizedFor,
    required this.onOpenNote,
    required this.onPersistNotes,
    required this.onDragMove,
    required this.beforeDragHoldDuration,
    this.enableFootnoteInteractions = true,
    this.onStickyDragArmNote,
    this.onStickyFingerRelinkEnded,
    this.onStickyHoldMenuNote,
    this.armDragHapticFeedback = false,
    this.onStickyHoldCanceledNote,
  });

  final List<ReadingNote> notesForCurrentPage;
  final PdfStickyAnchorResolver anchorNormalizedFor;
  final Future<void> Function(ReadingNote n) onOpenNote;
  final Future<void> Function() onPersistNotes;
  final ValueChanged<(ReadingNote note, DragUpdateDetails d, Size viewport)>
      onDragMove;

  /// [Duration.zero] → arrastar de imediato (ex.: leitor PDF sem TTS).
  /// Com duração (ex.: 460 ms — modo Ler): segura → arma o arrastar; solta sem mover → menu rápido.
  final Duration beforeDragHoldDuration;

  /// Chips respondem ao toque/arrastar. Desliga se não quiser sobrepor o gesto ao viewer.
  final bool enableFootnoteInteractions;

  final void Function(ReadingNote note)? onStickyDragArmNote;
  /// Largaste depois de arrastar: religar texto + âncora na linha sob o dedo.
  final Future<void> Function(
    ReadingNote note,
    Offset globalFingerUp,
    Offset totalDragPx,
    Size viewport,
  )?
      onStickyFingerRelinkEnded;

  /// Após segurar e largar sem arrastar uma distância mínima (modo segurar-arrastar ligado).
  final Future<void> Function(ReadingNote note, Offset globalFinger)?
      onStickyHoldMenuNote;

  final bool armDragHapticFeedback;

  /// Gestos interrompidos (ex.: pointer cancelado) durante o segurar-arrastar — repor estado no pai.
  final void Function(ReadingNote note)? onStickyHoldCanceledNote;

  bool get _timedHoldArm => beforeDragHoldDuration > Duration.zero;

  @override
  Widget build(BuildContext context) {
    if (notesForCurrentPage.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (ctx, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final n in notesForCurrentPage)
              Builder(
                builder: (_) {
                  final an = anchorNormalizedFor(n).stickyClamp();
                  return Positioned(
                    left: an.dx * size.width - PdfStickyFootnoteChip.halfBiasX,
                    top: an.dy * size.height - PdfStickyFootnoteChip.halfBiasY,
                    child: PdfStickyFootnoteChip(
                      note: n,
                      holdBeforeDragArm: beforeDragHoldDuration,
                      gesturesEnabled: enableFootnoteInteractions,
                      dragArmUsesHaptics: armDragHapticFeedback,
                      onFingerDragArm: onStickyDragArmNote == null
                          ? null
                          : () => onStickyDragArmNote!.call(n),
                      onFingerDragMove: (d) => onDragMove((n, d, size)),
                      onPersistAfterImmediatePan: () =>
                          unawaited(onPersistNotes()),
                      onFingerRelinkFingerUp:
                          !_timedHoldArm || onStickyFingerRelinkEnded == null
                              ? null
                              : (global, total) =>
                                    onStickyFingerRelinkEnded!(
                                      n,
                                      global,
                                      total,
                                      size,
                                    ),
                      onFingerHoldOpenedMenuAsync:
                          !_timedHoldArm || onStickyHoldMenuNote == null
                              ? null
                              : (global) =>
                                  onStickyHoldMenuNote!.call(n, global),
                      onFingerHoldCanceled: !_timedHoldArm ||
                              onStickyHoldCanceledNote == null
                          ? null
                          : () => onStickyHoldCanceledNote!.call(n),
                      onPeekFromExpanded: () async {
                        await onOpenNote(n);
                      },
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

extension PdfStickyAnch on Offset {
  Offset stickyClamp() {
    return Offset(
      dx.clamp(0.04, 0.96),
      dy.clamp(0.04, 0.96),
    );
  }
}

Offset stickySpawnAnchorsNormalized(int indexOnPage) {
  const cx = 0.68;
  const cy = 0.22;
  final step = indexOnPage * 0.065;
  final ang = indexOnPage * 0.88;
  return Offset(
    (cx + step * cos(ang)).clamp(0.08, 0.9),
    (cy + step * sin(ang)).clamp(0.08, 0.86),
  );
}

class PdfStickyFootnoteChip extends StatefulWidget {
  const PdfStickyFootnoteChip({
    super.key,
    required this.note,
    required this.onPeekFromExpanded,
    this.holdBeforeDragArm = Duration.zero,
    this.gesturesEnabled = true,
    this.dragArmUsesHaptics = true,
    this.onFingerDragArm,
    required this.onFingerDragMove,
    required this.onPersistAfterImmediatePan,
    this.onFingerRelinkFingerUp,
    this.onFingerHoldOpenedMenuAsync,
    this.onFingerHoldCanceled,
  });

  static const halfBiasX = 16.0;
  static const halfBiasY = 16.0;

  final ReadingNote note;

  /// [Duration.zero] — arrastar já no primeiro pixel (leitor PDF).
  final Duration holdBeforeDragArm;
  final bool gesturesEnabled;
  final bool dragArmUsesHaptics;
  final void Function()? onFingerDragArm;
  final ValueChanged<DragUpdateDetails> onFingerDragMove;
  final VoidCallback onPersistAfterImmediatePan;
  /// Larga após segurar → arrastar; posição onde soltaste + deltas acumulados.
  final Future<void> Function(Offset globalUp, Offset totalDragPx)?
      onFingerRelinkFingerUp;

  /// Soltaste depois da vibração sem arrastar bastante → menu rápido.
  final Future<void> Function(Offset globalFinger)? onFingerHoldOpenedMenuAsync;
  final VoidCallback? onFingerHoldCanceled;

  /// Abre folha (editar/apagar…) a partir da vista expandida.
  final Future<void> Function() onPeekFromExpanded;

  bool get immediatePanDrag => holdBeforeDragArm <= Duration.zero;

  @override
  State<PdfStickyFootnoteChip> createState() => _PdfStickyFootnoteChipState();
}

class _PdfStickyFootnoteChipState extends State<PdfStickyFootnoteChip> {
  static const double _moveSlopBeforeArmPx = 12;
  static const double _meaningfulFingerDragPx = 10;

  Timer? _armTimer;
  var _timedArmed = false;
  Offset _timedAccumDrag = Offset.zero;
  Offset _moveBeforeArm = Offset.zero;

  /// Evita dois pointer-up quando um fluxo async ainda corre.
  var _fingerBusy = false;

  var _expanded = false;

  @override
  void dispose() {
    _armTimer?.cancel();
    super.dispose();
  }

  void _cancelArmTimer() {
    _armTimer?.cancel();
    _armTimer = null;
  }

  DragUpdateDetails _detailsFromMove(PointerMoveEvent e) => DragUpdateDetails(
        delta: e.delta,
        globalPosition: e.position,
        localPosition: e.localPosition,
      );

  @override
  Widget build(BuildContext context) {
    final ink = Color(widget.note.textArgb);
    final paper = Color(widget.note.paperArgb);

    Widget mini() {
      return Tooltip(
        message: widget.note.body.trim().isEmpty
            ? 'Toque rápido: expandir · Arrastar: mover na página'
            : widget.note.body.trim(),
        child: Material(
          color: paper.withValues(alpha: 0.95),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(color: ink.withValues(alpha: 0.52), width: 1.3),
          ),
          elevation: (_timedArmed && !widget.immediatePanDrag) ? 12 : 5,
          shadowColor: Colors.black.withValues(alpha: 0.35),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: Transform.rotate(
                angle: -0.35,
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 20,
                  color: ink.withValues(alpha: 0.95),
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      offset: const Offset(0, 0.75),
                      blurRadius: 1.5,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget expandedPaper() {
      final preview =
          widget.note.body.trim().replaceAll(RegExp(r'\s+'), ' ');
      final line = preview.length > 120
          ? '${preview.substring(0, 120)}…'
          : preview;
      final w =
          PdfStickyChipStyle.expandedChipWidth(MediaQuery.sizeOf(context).width);

      void peekFromExpandedSheet() =>
          unawaited(widget.onPeekFromExpanded());

      return Transform.rotate(
        angle: -0.038,
        child: _StickyPaperFrame(
          paperArgb: widget.note.paperArgb,
          textArgb: widget.note.textArgb,
          elevation: 7,
          child: SizedBox(
            width: w,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 8, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        visualDensity:
                            VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 30,
                          minHeight: 30,
                        ),
                        tooltip: 'Minimizar',
                        onPressed: () =>
                            setState(() => _expanded = false),
                        icon: Icon(
                          Icons.unfold_less_rounded,
                          size: 18,
                          color: ink.withValues(alpha: 0.75),
                        ),
                      ),
                      Icon(
                        Icons.push_pin_rounded,
                        size: 15,
                        color: ink.withValues(alpha: 0.62),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Recado',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: ink.withValues(alpha: 0.78),
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity:
                            VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 30,
                          minHeight: 30,
                        ),
                        tooltip: 'Detalhes',
                        onPressed: peekFromExpandedSheet,
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 20,
                          color: ink.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  InkWell(
                    onTap: peekFromExpandedSheet,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line.isEmpty ? 'Sem texto.' : line,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.9,
                          height: 1.32,
                          color: ink,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget core = AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: !_expanded
          ? KeyedSubtree(key: ValueKey('m-${widget.note.id}'), child: mini())
          : KeyedSubtree(
              key: ValueKey('e-${widget.note.id}'),
              child: expandedPaper(),
            ),
    );

    if (!widget.gesturesEnabled || _expanded) return core;

    if (widget.immediatePanDrag) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _expanded = true),
        onPanUpdate: widget.onFingerDragMove,
        onPanEnd: (_) => widget.onPersistAfterImmediatePan(),
        child: core,
      );
    }

    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (_) {
        if (_fingerBusy || !mounted) return;
        _cancelArmTimer();
        _timedArmed = false;
        _timedAccumDrag = Offset.zero;
        _moveBeforeArm = Offset.zero;
        _armTimer = Timer(widget.holdBeforeDragArm, () {
          if (!mounted || _expanded || _fingerBusy) return;
          widget.onFingerDragArm?.call();
          if (widget.dragArmUsesHaptics) {
            HapticFeedback.lightImpact();
          }
          setState(() => _timedArmed = true);
        });
      },
      onPointerMove: (PointerMoveEvent e) {
        if (_fingerBusy || !mounted || !widget.gesturesEnabled || _expanded) return;
        final d = e.delta;
        if (!_timedArmed) {
          _moveBeforeArm += d;
          if (_moveBeforeArm.distance > _moveSlopBeforeArmPx) _cancelArmTimer();
          return;
        }
        _timedAccumDrag += d;
        widget.onFingerDragMove(_detailsFromMove(e));
      },
      onPointerUp: (PointerUpEvent e) async {
        if (_fingerBusy || !mounted || !widget.gesturesEnabled || _expanded) return;
        _cancelArmTimer();
        final armedNow = _timedArmed;

        try {
          if (!armedNow) {
            if (_moveBeforeArm.distance <= _moveSlopBeforeArmPx) {
              setState(() => _expanded = true);
            }
          } else {
            _timedArmed = false;
            final meaningful = _timedAccumDrag.distance >=
                    _meaningfulFingerDragPx &&
                widget.onFingerRelinkFingerUp != null;

            if (meaningful) {
              _fingerBusy = true;
              await widget.onFingerRelinkFingerUp!(
                e.position,
                _timedAccumDrag,
              );
            } else if (widget.onFingerHoldOpenedMenuAsync != null) {
              _fingerBusy = true;
              await widget.onFingerHoldOpenedMenuAsync!(e.position);
            }
          }
        } finally {
          _fingerBusy = false;
          _timedAccumDrag = Offset.zero;
          if (mounted) setState(() {});
        }
      },
      onPointerCancel: (_) {
        _cancelArmTimer();
        final wasTimed = _timedArmed;
        _timedArmed = false;
        _timedAccumDrag = Offset.zero;
        if (wasTimed) widget.onFingerHoldCanceled?.call();
        if (mounted) setState(() {});
      },
      child: core,
    );
  }
}

class PdfStickyChipStyle {
  PdfStickyChipStyle._();

  static double expandedChipWidth(double mediaW) {
    return mediaW.clamp(280.0, 620) * 0.46;
  }
}

class _StickyPaperFrame extends StatelessWidget {
  const _StickyPaperFrame({
    required this.paperArgb,
    required this.textArgb,
    required this.child,
    this.elevation = 4,
  });

  final int paperArgb;
  final int textArgb;
  final Widget child;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: elevation,
      shadowColor: Colors.black.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(11),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(paperArgb),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: Color(textArgb).withValues(alpha: 0.09),
              width: 0.85,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RuledStickyPainter(
                    ink: Color(textArgb).withValues(alpha: 0.08),
                  ),
                ),
              ),
              child,
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.32),
                      border: Border(
                        left: BorderSide(
                          color: Color(textArgb).withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                    child: const SizedBox(width: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuledStickyPainter extends CustomPainter {
  _RuledStickyPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..strokeWidth = 0.85
      ..color = ink;
    final startY = 32.0;
    const spacing = 11.5;
    for (var y = startY; y < size.height - 6; y += spacing) {
      canvas.drawLine(Offset(8, y), Offset(size.width - 12, y), pen);
    }
  }

  @override
  bool shouldRepaint(covariant _RuledStickyPainter oldDelegate) =>
      oldDelegate.ink != ink;
}
