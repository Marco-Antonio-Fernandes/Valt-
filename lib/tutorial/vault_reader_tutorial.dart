import 'package:flutter/material.dart';
import 'package:showcaseview/showcaseview.dart';

import '../app_theme.dart';
import 'vault_app_tutorial.dart';

/// Tutorial do modo Ouvir (primeiro livro PDF): voz, reprodução, notas e grifos.
class VaultReaderTutorial {
  VaultReaderTutorial();

  static const showcaseScope = 'vault_reader_tutorial';

  final listenHintKey = GlobalKey();
  final playKey = GlobalKey();
  final voiceKey = GlobalKey();
  final stickyKey = GlobalKey();
  final bookmarksKey = GlobalKey();

  List<GlobalKey> get orderedKeys => [
        listenHintKey,
        playKey,
        voiceKey,
        stickyKey,
        bookmarksKey,
      ];

  void register({
    required VoidCallback onFinish,
    void Function(GlobalKey? dismissedAt)? onDismiss,
  }) {
    ShowcaseView.register(
      scope: showcaseScope,
      skipIfTargetNotPresent: true,
      blurValue: 3,
      enableAutoScroll: true,
      disableBarrierInteraction: true,
      onFinish: onFinish,
      onDismiss: onDismiss,
      globalTooltipActionConfig: const TooltipActionConfig(
        position: TooltipActionPosition.inside,
        alignment: MainAxisAlignment.spaceBetween,
        actionGap: 16,
      ),
      globalTooltipActions: [
        TooltipActionButton(
          type: TooltipDefaultActionType.previous,
          textStyle: const TextStyle(color: AppTheme.ink),
          hideActionWidgetForShowcase: [listenHintKey],
        ),
        TooltipActionButton(
          type: TooltipDefaultActionType.next,
          textStyle: const TextStyle(color: AppTheme.ink),
          hideActionWidgetForShowcase: [bookmarksKey],
        ),
      ],
      globalFloatingActionWidget: (context) => FloatingActionWidget(
        left: 20,
        bottom: 120,
        child: TextButton(
          onPressed: () => ShowcaseView.getNamed(showcaseScope).dismiss(),
          child: const Text(
            'Saltar tutorial',
            style: TextStyle(color: AppTheme.muted, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  void start() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ShowcaseView.getNamed(showcaseScope).startShowCase(
        orderedKeys,
        delay: const Duration(milliseconds: 500),
      );
    });
  }

  void dispose() {
    try {
      ShowcaseView.getNamed(showcaseScope).unregister();
    } catch (_) {
      /* scope já removido */
    }
  }

  Widget wrap({
    required GlobalKey showcaseKey,
    required String title,
    required String description,
    required Widget child,
    TooltipPosition? tooltipPosition,
  }) {
    return VaultAppTutorial.wrap(
      showcaseKey: showcaseKey,
      title: title,
      description: description,
      tooltipPosition: tooltipPosition,
      child: child,
    );
  }
}
