import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chave: utilizador já viu o texto introdutório e escolheu continuar.
const _kVaultBgPermIntroDone = 'vault_bg_perm_intro_done_v1';

/// Pedidos úteis para leitura em voz alta / media session no Android (notificações +
/// não limitar pela otimização de bateria). Não substitui políticas agressivas de
/// alguns fabricantes (MIUI etc.).
/// [skipExplanation] — só pedir ao sistema (atalho nas definições da biblioteca).
Future<void> vaultMaybeRequestAndroidBackgroundPermissions(
  BuildContext context, {
  bool skipExplanation = false,
}) async {
  if (kIsWeb || !Platform.isAndroid) return;

  final notifOk = (await Permission.notification.status).isGranted;
  final batOk =
      (await Permission.ignoreBatteryOptimizations.status).isGranted;
  if (notifOk && batOk) {
    if (skipExplanation && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Som em segundo plano: notificações e bateria já estão tratadas neste equipamento.',
          ),
        ),
      );
    }
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final introDone = prefs.getBool(_kVaultBgPermIntroDone) ?? false;

  if (!context.mounted) return;

  if (!skipExplanation && !introDone) {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text('Leitura em segundo plano'),
        content: const Text(
          'Para a leitura em voz alta e os controlos na barra de notificações funcionarem '
          'melhor quando o ecrã está apagado ou está noutra app, o Vault pode pedir:\n\n'
          '• Notificações — aviso com play/pausa;\n'
          '• Ignorar otimização de bateria — reduz cortes impostos pelo Android.\n\n'
          'Isto não remove o bloqueio do telefone com PIN ou impressão digital.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Agora não'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await prefs.setBool(_kVaultBgPermIntroDone, true);
  }

  await Permission.notification.request();
  await Permission.ignoreBatteryOptimizations.request();

  if (!context.mounted) return;

  final stillNotif = !(await Permission.notification.status).isGranted;
  final stillBat =
      !(await Permission.ignoreBatteryOptimizations.status).isGranted;
  if (!context.mounted) return;
  if (!stillNotif && !stillBat) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF121212),
      title: const Text('Permissões'),
      content: Text(
        stillNotif && stillBat
            ? 'Algumas permissões ficaram em falta. Nas Definições da app pode ativar '
                'notificações e permitir execução sem restrições de bateria.'
            : stillNotif
                ? 'Ative as notificações para o Vault nas definições Android.'
                : 'Nas definições de Bateria, permita que o Vault execute sem '
                    'restrições (texto varia conforme o modelo).',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Fechar'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await openAppSettings();
          },
          child: const Text('Abrir definições'),
        ),
      ],
    ),
  );
}
