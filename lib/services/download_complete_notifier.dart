import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notificação local com som do sistema quando um download termina.
class DownloadCompleteNotifier {
  DownloadCompleteNotifier._();
  static final instance = DownloadCompleteNotifier._();

  static const _channelId = 'vault_download_complete';
  static const _channelName = 'Downloads';
  static const _channelDesc = 'Som ao concluir uma descarga para a biblioteca.';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _initFuture;
  bool _darwinPermissionRequested = false;

  static bool _supportedTarget() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Inicializa plugin e canal Android (só Android / iOS / macOS).
  Future<void> initialize() {
    if (!_supportedTarget()) return Future.value();
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    if (!_supportedTarget()) return;

    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: defaultTargetPlatform == TargetPlatform.android
              ? const AndroidInitializationSettings('@mipmap/ic_launcher')
              : null,
          iOS: defaultTargetPlatform == TargetPlatform.iOS
              ? const DarwinInitializationSettings(
                  requestAlertPermission: false,
                  requestBadgePermission: false,
                  requestSoundPermission: false,
                  defaultPresentAlert: true,
                  defaultPresentSound: true,
                )
              : null,
          macOS: defaultTargetPlatform == TargetPlatform.macOS
              ? const DarwinInitializationSettings(
                  requestAlertPermission: false,
                  requestBadgePermission: false,
                  requestSoundPermission: false,
                  defaultPresentAlert: true,
                  defaultPresentSound: true,
                )
              : null,
        ),
      );

      if (defaultTargetPlatform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(
              const AndroidNotificationChannel(
                _channelId,
                _channelName,
                description: _channelDesc,
                importance: Importance.high,
                playSound: true,
                enableVibration: true,
              ),
            );
      }
    } catch (e, st) {
      debugPrint('DownloadCompleteNotifier init: $e\n$st');
    }
  }

  Future<void> _requestDarwinIfNeeded() async {
    if (_darwinPermissionRequested) return;
    _darwinPermissionRequested = true;

    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugPrint('DownloadCompleteNotifier permissions: $e');
    }
  }

  Future<void> notifyDownloadComplete(String fileLabel) async {
    if (!_supportedTarget()) return;
    await initialize();
    await _requestDarwinIfNeeded();

    final body = _truncate(fileLabel, 200);
    final id = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;

    try {
      await _plugin.show(
        id: id,
        title: 'Download concluído',
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            presentList: true,
          ),
          macOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('DownloadCompleteNotifier show: $e\n$st');
    }
  }

  static String _truncate(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }
}
