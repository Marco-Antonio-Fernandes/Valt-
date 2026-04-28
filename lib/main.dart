import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'app_theme.dart';
import 'screens/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    initBindings();
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
  runApp(const VaultApp());
}

class VaultApp extends StatelessWidget {
  const VaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    final d = AppTheme.dark();
    return MaterialApp(
      title: 'Vault',
      theme: d,
      darkTheme: d,
      themeMode: ThemeMode.dark,
      color: AppTheme.black,
      home: const LibraryScreen(),
    );
  }
}
