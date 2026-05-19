import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_theme.dart';
import 'screens/library_screen.dart';
import 'screens/startup_loading_screen.dart';
import 'services/vault_android_permissions.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  /// Bindings ONNX Sherpa apenas no isolate de síntese (`sherpa_tts_isolate`).
  /// `VaultReadingAudio` só ao iniciar reprodução com voz offline em
  /// [PdfReadingModeScreen] — evita serviço em primeiro plano / AudioSession
  /// quando o utilizador só abre biblioteca, comics ou PDF sem TTS.
  ///
  /// Inicialização do PDF (`pdfrxFlutterInitialize`) corre dentro de [VaultApp]
  /// para poder mostrar [StartupLoadingScreen] durante o trabalho.
  runApp(VaultApp(navigatorKey: GlobalKey<NavigatorState>()));
}

class VaultApp extends StatefulWidget {
  const VaultApp({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> {
  var _startupReady = false;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    unawaited(_runStartup());
  }

  Future<void> _runStartup() async {
    if (mounted) setState(() => _startupError = null);
    try {
      await pdfrxFlutterInitialize();
      if (!mounted) return;
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: AppTheme.black,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );
      setState(() => _startupReady = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = widget.navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          unawaited(vaultMaybeRequestAndroidBackgroundPermissions(ctx));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startupReady = false;
        _startupError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = AppTheme.dark();
    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: d,
      darkTheme: d,
      themeMode: ThemeMode.dark,
      color: AppTheme.black,
      home:
          _startupReady
              ? const LibraryScreen()
              : StartupLoadingScreen(
                  errorMessage: _startupError,
                  onRetry: _startupError != null ? () => unawaited(_runStartup()) : null,
                ),
    );
  }
}
