import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'app_theme.dart';
import 'screens/library_screen.dart';
import 'services/vault_android_permissions.dart';
import 'services/vault_reading_audio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    initBindings();
    if (Platform.isAndroid || Platform.isIOS) {
      await VaultReadingAudio.init();
    }
  }
  await pdfrxFlutterInitialize();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(VaultApp(navigatorKey: GlobalKey<NavigatorState>()));
}

class VaultApp extends StatefulWidget {
  const VaultApp({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = widget.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        unawaited(vaultMaybeRequestAndroidBackgroundPermissions(ctx));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = AppTheme.dark();
    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      title: 'Vault',
      theme: d,
      darkTheme: d,
      themeMode: ThemeMode.dark,
      color: AppTheme.black,
      home: const LibraryScreen(),
    );
  }
}
