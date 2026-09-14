import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance =
      NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'blink_timer';
  static const String _channelName = 'Blink timer';
  static const String _channelDesc =
      'Blink timer and eye break notifications';

  static const int _timerNotificationId = 10;
  static const int _alertNotificationId = 11;

  Future<void> init() async {
    tz.initializeTimeZones();

    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {}

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const initSettings = InitializationSettings(
      android: androidInit,
    );

    await _plugin.initialize(initSettings);

    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await android?.requestNotificationsPermission();

    // Android 14+ / full-screen notifications.
    try {
      await android?.requestFullScreenIntentPermission();
    } catch (_) {}

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,
      playSound: false,
      enableVibration: false,
    );

    await android?.createNotificationChannel(channel);
  }

  Future<void> showTimer({
    required String phase,
    required int secondsRemaining,
    required int totalSeconds,
    required bool paused,
  }) async {
    final progress = totalSeconds <= 0
        ? 0
        : (((totalSeconds - secondsRemaining) /
                    totalSeconds) *
                100)
            .round()
            .clamp(0, 100);

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        ongoing: !paused,
        autoCancel: paused,
        onlyAlertOnce: true,
        showWhen: false,
        showProgress: true,
        maxProgress: 100,
        progress: progress,
        subText: paused ? 'Paused' : 'Running',
      ),
    );

    await _plugin.show(
      _timerNotificationId,
      '$phase · ${_formatTime(secondsRemaining)}',
      paused ? 'Timer paused' : 'Time remaining',
      details,
    );
  }

  Future<void> showBreakAlert({
    required String title,
    required String body,
  }) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        playSound: false,
        enableVibration: false,
        ongoing: true,
        autoCancel: false,
      ),
    );

    await _plugin.show(
      _alertNotificationId,
      title,
      body,
      details,
    );
  }

  Future<void> showSimple({
    required String title,
    required String body,
  }) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
    );

    await _plugin.show(
      _alertNotificationId,
      title,
      body,
      details,
    );
  }

  Future<void> cancelTimer() async {
    await _plugin.cancel(_timerNotificationId);
  }

  Future<void> cancelAlert() async {
    await _plugin.cancel(_alertNotificationId);
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  String _formatTime(int seconds) {
    final minutes =
        (seconds ~/ 60).toString().padLeft(2, '0');

    final remainingSeconds =
        (seconds % 60).toString().padLeft(2, '0');

    return '$minutes:$remainingSeconds';
  }
}
