import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Tema escuro: preto, acento violeta, tipografia nítida.
class AppTheme {
  AppTheme._();

  static const Color black = Color(0xFF000000);
  static const Color ink = Color(0xFFF4F4F5);
  static const Color muted = Color(0xFFA1A1AA);

  static ThemeData dark() {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B5CF6),
      brightness: Brightness.dark,
    );

    final cs = base.copyWith(
      surface: black,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerLowest: const Color(0xFF040404),
      surfaceContainerLow: const Color(0xFF09090B),
      surfaceContainer: const Color(0xFF0C0C0E),
      surfaceContainerHigh: const Color(0xFF141416),
      surfaceContainerHighest: const Color(0xFF1C1C1F),
      primary: const Color(0xFFC4B5FD),
      onPrimary: const Color(0xFF1E1B3A),
      primaryContainer: const Color(0xFF2D2640),
      onPrimaryContainer: const Color(0xFFE9D5FF),
      tertiary: const Color(0xFF34D399),
      onTertiary: const Color(0xFF041F18),
      outline: const Color(0xFF2E2E33),
      outlineVariant: const Color(0xFF3F3F46),
    );

    final text = TextTheme(
      displayLarge: const TextStyle(letterSpacing: -1.0, fontWeight: FontWeight.w600),
      titleLarge: const TextStyle(letterSpacing: -0.3, fontWeight: FontWeight.w600),
      titleSmall: const TextStyle(letterSpacing: -0.1, fontWeight: FontWeight.w600),
    ).apply(
      bodyColor: ink,
      displayColor: ink,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      scaffoldBackgroundColor: black,
      splashColor: cs.primary.withValues(alpha: 0.12),
      highlightColor: cs.primary.withValues(alpha: 0.07),
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: black,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: ink,
        ),
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: black,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      ),
      cardTheme: CardThemeData(
        color: cs.surfaceContainerHigh,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        margin: EdgeInsets.zero,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: cs.onSurfaceVariant,
          hoverColor: cs.primary.withValues(alpha: 0.1),
        ),
      ),
    );
  }
}
