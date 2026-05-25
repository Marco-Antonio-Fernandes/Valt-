import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Catálogo público (proxies no backend).
class PublicLibrariesScreen extends StatelessWidget {
  const PublicLibrariesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar.large(
          floating: true,
          backgroundColor: AppTheme.black,
          surfaceTintColor: Colors.transparent,
          flexibleSpace: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  c.surfaceContainerLow.withValues(alpha: 0.55),
                  AppTheme.black,
                ],
              ),
            ),
          ),
          title: const Text('Bibliotecas públicas'),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        c.tertiary.withValues(alpha: 0.22),
                        c.primary.withValues(alpha: 0.14),
                      ],
                    ),
                    border: Border.all(
                      color: c.outline.withValues(alpha: 0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: c.tertiary.withValues(alpha: 0.12),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(26),
                    child: Icon(
                      Icons.cloud_download_rounded,
                      size: 48,
                      color: c.tertiary.withValues(alpha: 0.95),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Descarregar livros gratuitos',
                  textAlign: TextAlign.center,
                  style: t.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Explorações de catálogos públicos através do teu servidor.\n'
                  'Importação automática poderá ligar‑se mais tarde ao backend.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.onSurfaceVariant,
                    height: 1.45,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
