import 'package:flutter/material.dart';

import '../models/reading_highlight.dart'
    show kDefaultReadingHighlightArgb;

/// Cores rápidas para sobrepor texto no PDF (ARGB opacos).
const kReadingHighlightColorChoices = <int>[
  0xFFFFCA28,
  0xFFFFEB3B,
  0xFF8BC34A,
  0xFF29B6F6,
  0xFFE91E63,
  0xFF9575CD,
  0xFFFF7043,
  0xFF26A69A,
];

/// Folha inferior: utilizador escolhe a cor do próximo(s) grifo(s). `null` = cancelado.
Future<int?> showReadingHighlightColorPicker(BuildContext context) {
  var chosen = kDefaultReadingHighlightArgb;

  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
          child: StatefulBuilder(
            builder: (ctx, setS) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Cor do grifo',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final argb in kReadingHighlightColorChoices)
                        GestureDetector(
                          onTap: () => setS(() => chosen = argb),
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Color(argb),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: chosen == argb
                                    ? Theme.of(ctx).colorScheme.primary
                                    : Colors.black.withValues(alpha: 0.18),
                                width: chosen == argb ? 3 : 1.2,
                              ),
                              boxShadow: [
                                if (chosen == argb)
                                  BoxShadow(
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.35),
                                    blurRadius: 8,
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, chosen),
                    child: const Text('Guardar grifo'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancelar'),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
