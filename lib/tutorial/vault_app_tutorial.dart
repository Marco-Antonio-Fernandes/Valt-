import 'package:flutter/material.dart';
import 'package:showcaseview/showcaseview.dart';

import '../app_theme.dart';

/// Tutorial interativo da biblioteca com ShowcaseView (destaque passo a passo).
class VaultAppTutorial {
  VaultAppTutorial();

  static const showcaseScope = 'vault_library_tutorial';

  final welcomeKey = GlobalKey();
  final navKey = GlobalKey();
  final importKey = GlobalKey();
  final readListenKey = GlobalKey();
  final notesKey = GlobalKey();
  final accountKey = GlobalKey();

  List<GlobalKey> get orderedKeys => [
        welcomeKey,
        navKey,
        importKey,
        readListenKey,
        notesKey,
        accountKey,
      ];

  void register({
    required VoidCallback onFinish,
    void Function(int? index, GlobalKey key)? onStart,
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
      onStart: onStart,
      globalTooltipActionConfig: const TooltipActionConfig(
        position: TooltipActionPosition.inside,
        alignment: MainAxisAlignment.spaceBetween,
        actionGap: 16,
      ),
      globalTooltipActions: [
        TooltipActionButton(
          type: TooltipDefaultActionType.previous,
          textStyle: const TextStyle(color: AppTheme.ink),
          hideActionWidgetForShowcase: [welcomeKey],
        ),
        TooltipActionButton(
          type: TooltipDefaultActionType.next,
          textStyle: const TextStyle(color: AppTheme.ink),
          hideActionWidgetForShowcase: [accountKey],
        ),
      ],
      globalFloatingActionWidget: (context) => FloatingActionWidget(
        left: 20,
        bottom: 20,
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
        delay: const Duration(milliseconds: 400),
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

  static Widget wrap({
    required GlobalKey showcaseKey,
    required String title,
    required String description,
    required Widget child,
    TooltipPosition? tooltipPosition,
  }) {
    return Showcase(
      key: showcaseKey,
      title: title,
      description: description,
      tooltipBackgroundColor: AppTheme.black.withValues(alpha: 0.94),
      textColor: AppTheme.ink,
      titleTextStyle: const TextStyle(
        color: AppTheme.ink,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      descTextStyle: const TextStyle(
        color: AppTheme.muted,
        fontSize: 14,
        height: 1.45,
      ),
      targetBorderRadius: BorderRadius.circular(16),
      tooltipBorderRadius: BorderRadius.circular(16),
      tooltipPosition: tooltipPosition,
      child: child,
    );
  }
}
