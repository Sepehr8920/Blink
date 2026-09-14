import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'services/sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await NotificationService.instance.init();

  runApp(const BlinkApp());
}

// -----------------------------------------------------------------------------
// Color palette
// -----------------------------------------------------------------------------

const Color kBgAround = Color(0xFF429DAD);

// رنگ دایره فعلاً همان رنگ اصلی قبلی برنامه است.
// در مرحله طراحی نهایی می‌توانیم آن را دقیقاً مطابق چیزی که گفتی تنظیم کنیم.
const Color kTimerCircle = Color(0xFF1E293B);

const Color kBgDeep = Color(0xFF0F172A);
const Color kBgMid = Color(0xFF1E293B);

const Color kAccentFocus = Color(0xFF7DD3FC);
const Color kAccentBreak = Color(0xFFFCD34D);

const Color kSurface = Color(0xFF334155);

// -----------------------------------------------------------------------------
// App
// -----------------------------------------------------------------------------

class BlinkApp extends StatelessWidget {
  const BlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBgAround,
        colorScheme: const ColorScheme.dark(
          primary: kAccentFocus,
          surface: kSurface,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: const TimerPage(),
    );
  }
}

// -----------------------------------------------------------------------------
// Timer Page
// -----------------------------------------------------------------------------

class TimerPage extends StatefulWidget {
  const TimerPage({super.key});

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  int _workMinutes = SettingsService.defaultWork;
  int _breakMinutes = SettingsService.defaultBreak;
  int _totalCycles = SettingsService.defaultCycles;

  bool _soundEnabled = SettingsService.defaultSound;
  bool _vibrateEnabled = SettingsService.defaultVibrate;

  // ---------------------------------------------------------------------------
  // Timer state
  // ---------------------------------------------------------------------------

  int _currentCycle = 1;

  bool _isWorking = true;
  bool _isRunning = false;

  int _secondsLeft = 0;
  int _totalSecondsForPhase = 0;

  // Stopwatch is monotonic and is not affected by changing the phone clock.
  final Stopwatch _phaseStopwatch = Stopwatch();

  // ---------------------------------------------------------------------------
  // UI animation
  // ---------------------------------------------------------------------------

  late final Ticker _uiTicker;

  double _progress = 0.0;

  // ---------------------------------------------------------------------------
  // Background update timer
  //
  // Unlike the UI ticker, this timer is intentionally allowed to continue
  // while the application is in the background.
  // It is responsible for:
  // - phase transitions
  // - seconds countdown
  // - notification updates
  // ---------------------------------------------------------------------------

  Timer? _backgroundTimer;

  // Prevent duplicate phase transitions.
  bool _isSwitchingPhase = false;

  // Last notification second that was sent.
  int _lastNotificationSecond = -1;

  // Whether flutter_background was successfully enabled.
  bool _backgroundEnabled = false;

  bool get _isLocked => !_isWorking && _isRunning;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _uiTicker = createTicker((_) {
      if (!_isRunning) {
        return;
      }

      _updateFromStopwatch(updateNotification: false);
    });

    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _uiTicker.stop();
    _uiTicker.dispose();

    _backgroundTimer?.cancel();
    _backgroundTimer = null;

    _phaseStopwatch.stop();

    _disableBackgroundExecution();

    WakelockPlus.disable();

    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (_isRunning) {
        _updateFromStopwatch(
          updateNotification: true,
        );

        if (!_uiTicker.isActive) {
          _uiTicker.start();
        }

        if (_backgroundTimer == null) {
          _startBackgroundTimer();
        }
      }
    } else {
      // We intentionally stop ONLY the UI frame ticker.
      //
      // The Stopwatch continues.
      // The background timer continues.
      // The foreground service keeps the Flutter isolate alive when enabled.
      _uiTicker.stop();

      if (_isRunning && _backgroundTimer == null) {
        _startBackgroundTimer();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<void> _loadSettings() async {
    final s = await SettingsService.load();

    if (!mounted) {
      return;
    }

    setState(() {
      _workMinutes = s['workMinutes'];
      _breakMinutes = s['breakMinutes'];
      _totalCycles = s['totalCycles'];

      _soundEnabled = s['soundEnabled'];
      _vibrateEnabled = s['vibrateEnabled'];

      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;

      _progress = 0.0;
    });
  }

  // ---------------------------------------------------------------------------
  // Background execution
  // ---------------------------------------------------------------------------

  Future<bool> _initializeBackgroundExecution() async {
    if (_backgroundEnabled) {
      return true;
    }

    try {
      final config = FlutterBackgroundAndroidConfig(
        notificationTitle: 'Blink',
        notificationText: _isWorking
            ? 'Focus timer is running'
            : 'Eye break is running',
        notificationImportance:
            AndroidNotificationImportance.normal,
        notificationIcon: const AndroidResource(
          name: 'ic_launcher',
          defType: 'mipmap',
        ),
        enableWifiLock: false,
        showBadge: false,
        shouldRequestBatteryOptimizationsOff: true,
      );

      final initialized =
          await FlutterBackground.initialize(
        androidConfig: config,
      );

      if (!initialized) {
        return false;
      }

      _backgroundEnabled =
          await FlutterBackground.enableBackgroundExecution();

      return _backgroundEnabled;
    } catch (_) {
      // If the device/plugin refuses background execution,
      // Blink should still be usable in the foreground.
      _backgroundEnabled = false;
      return false;
    }
  }

  Future<void> _disableBackgroundExecution() async {
    if (!_backgroundEnabled) {
      return;
    }

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}

    _backgroundEnabled = false;
  }

  // ---------------------------------------------------------------------------
  // Start / Pause
  // ---------------------------------------------------------------------------

  Future<void> _toggleTimer() async {
    if (_isRunning) {
      _pauseTimer();
    } else {
      await _startTimer();
    }
  }

  Future<void> _startTimer() async {
    if (_secondsLeft <= 0 ||
        _totalSecondsForPhase <= 0) {
      return;
    }

    if (_isRunning) {
      return;
    }

    // Try to start Android foreground/background execution.
    await _initializeBackgroundExecution();

    if (!mounted) {
      return;
    }

    setState(() {
      _isRunning = true;
    });

    if (!_phaseStopwatch.isRunning) {
      _phaseStopwatch.start();
    }

    _lastNotificationSecond = -1;

    _updateFromStopwatch(
      updateNotification: true,
    );

    _startBackgroundTimer();

    if (WidgetsBinding.instance.lifecycleState ==
        AppLifecycleState.resumed) {
      if (!_uiTicker.isActive) {
        _uiTicker.start();
      }
    }

    await WakelockPlus.enable();
  }

  void _pauseTimer() {
    if (!_isRunning) {
      return;
    }

    _phaseStopwatch.stop();

    _updateFromStopwatch(
      updateNotification: true,
    );

    _backgroundTimer?.cancel();
    _backgroundTimer = null;

    _uiTicker.stop();

    if (mounted) {
      setState(() {
        _isRunning = false;
      });
    }

    _lastNotificationSecond = -1;

    unawaited(
      NotificationService.instance.cancelAll(),
    );

    unawaited(
      _disableBackgroundExecution(),
    );

    WakelockPlus.disable();
  }

  // ---------------------------------------------------------------------------
  // Background timer
  // ---------------------------------------------------------------------------

  void _startBackgroundTimer() {
    _backgroundTimer?.cancel();

    _backgroundTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        if (!_isRunning) {
          return;
        }

        _updateFromStopwatch(
          updateNotification: true,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Stopwatch calculations
  // ---------------------------------------------------------------------------

  void _updateFromStopwatch({
    required bool updateNotification,
  }) {
    if (!_isRunning) {
      return;
    }

    final elapsedMilliseconds =
        _phaseStopwatch.elapsedMilliseconds;

    final totalMilliseconds =
        _totalSecondsForPhase * 1000;

    if (elapsedMilliseconds >= totalMilliseconds) {
      _secondsLeft = 0;
      _progress = 1.0;

      if (mounted) {
        setState(() {});
      }

      if (!_isSwitchingPhase) {
        unawaited(
          _switchPhase(),
        );
      }

      return;
    }

    final remainingMilliseconds =
        totalMilliseconds - elapsedMilliseconds;

    final remainingSeconds =
        (remainingMilliseconds / 1000).ceil();

    final newProgress =
        elapsedMilliseconds /
            totalMilliseconds;

    if (_secondsLeft != remainingSeconds ||
        (_progress - newProgress).abs() > 0.001) {
      _secondsLeft = remainingSeconds;
      _progress = newProgress;

      if (mounted) {
        setState(() {});
      }
    }

    if (updateNotification &&
        _lastNotificationSecond !=
            remainingSeconds) {
      _lastNotificationSecond =
          remainingSeconds;

      unawaited(
        _updateNotification(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Phase transition
  // ---------------------------------------------------------------------------

  Future<void> _switchPhase() async {
    if (_isSwitchingPhase) {
      return;
    }

    _isSwitchingPhase = true;

    try {
      _phaseStopwatch.stop();
      _phaseStopwatch.reset();

      if (_isWorking) {
        // Work -> Break
        _isWorking = false;

        _totalSecondsForPhase =
            _breakMinutes * 60;

        _secondsLeft =
            _totalSecondsForPhase;

        _progress = 0.0;

        _lastNotificationSecond = -1;

        if (mounted) {
          setState(() {});
        }

        if (_soundEnabled) {
          unawaited(
            SoundService.playBreakSound(),
          );
        }

        if (_vibrateEnabled) {
          HapticFeedback.heavyImpact();
        }

        await NotificationService.instance
            .showBreakAlert();

        if (!_isRunning) {
          return;
        }

        _phaseStopwatch.start();

        _updateFromStopwatch(
          updateNotification: true,
        );
      } else {
        // Break -> next work phase
        if (_currentCycle >= _totalCycles) {
          _isRunning = false;

          _phaseStopwatch.stop();

          _backgroundTimer?.cancel();
          _backgroundTimer = null;

          _uiTicker.stop();

          await NotificationService.instance
              .cancelAll();

          await _disableBackgroundExecution();

          WakelockPlus.disable();

          if (mounted) {
            setState(() {});
          }

          return;
        }

        _currentCycle++;

        _isWorking = true;

        _totalSecondsForPhase =
            _workMinutes * 60;

        _secondsLeft =
            _totalSecondsForPhase;

        _progress = 0.0;

        _lastNotificationSecond = -1;

        if (mounted) {
          setState(() {});
        }

        _phaseStopwatch.start();

        _updateFromStopwatch(
          updateNotification: true,
        );
      }
    } finally {
      _isSwitchingPhase = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Notification
  // ---------------------------------------------------------------------------

  Future<void> _updateNotification() async {
    if (!_isRunning) {
      return;
    }

    try {
      await NotificationService.instance.showTimer(
        secondsLeft: _secondsLeft,
        isWorking: _isWorking,
        cycle: _currentCycle,
        totalCycles: _totalCycles,
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Reset
  // ---------------------------------------------------------------------------

  Future<void> _resetTimer() async {
    _phaseStopwatch.stop();
    _phaseStopwatch.reset();

    _backgroundTimer?.cancel();
    _backgroundTimer = null;

    _uiTicker.stop();

    await _disableBackgroundExecution();

    WakelockPlus.disable();

    _currentCycle = 1;
    _isWorking = true;
    _isRunning = false;

    _totalSecondsForPhase =
        _workMinutes * 60;

    _secondsLeft =
        _totalSecondsForPhase;

    _progress = 0.0;

    _lastNotificationSecond = -1;

    await NotificationService.instance
        .cancelAll();

    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  Future<void> _openSettings() async {
    if (_isRunning) {
      return;
    }

    final result =
        await Navigator.push<
            Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          workMinutes: _workMinutes,
          breakMinutes: _breakMinutes,
          totalCycles: _totalCycles,
          soundEnabled: _soundEnabled,
          vibrateEnabled: _vibrateEnabled,
        ),
      ),
    );

    if (result == null ||
        !mounted) {
      return;
    }

    await SettingsService.save(
      workMinutes:
          result['workMinutes'],
      breakMinutes:
          result['breakMinutes'],
      totalCycles:
          result['totalCycles'],
      soundEnabled:
          result['soundEnabled'],
      vibrateEnabled:
          result['vibrateEnabled'],
    );

    setState(() {
      _workMinutes =
          result['workMinutes'];

      _breakMinutes =
          result['breakMinutes'];

      _totalCycles =
          result['totalCycles'];

      _soundEnabled =
          result['soundEnabled'];

      _vibrateEnabled =
          result['vibrateEnabled'];

      _currentCycle = 1;
      _isWorking = true;

      _totalSecondsForPhase =
          _workMinutes * 60;

      _secondsLeft =
          _totalSecondsForPhase;

      _progress = 0.0;
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _formatTime(
    int seconds,
  ) {
    final minutes =
        seconds ~/ 60;

    final secs =
        seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(
    BuildContext context,
  ) {
    final phaseColor =
        _isWorking
            ? kAccentFocus
            : kAccentBreak;

    return PopScope(
      canPop: !_isLocked,
      child: Scaffold(
        backgroundColor:
            kBgAround,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Blink',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight:
                              FontWeight.w700,
                          color:
                              Colors.white,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),

                    _buildTopButton(
                      icon:
                          Icons.settings_outlined,
                      onPressed:
                          _isRunning
                              ? null
                              : _openSettings,
                    ),
                  ],
                ),
              ),

              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [
                      Text(
                        _isWorking
                            ? 'FOCUS'
                            : 'EYE BREAK',
                        style:
                            TextStyle(
                          color:
                              phaseColor,
                          fontSize: 14,
                          fontWeight:
                              FontWeight.w700,
                          letterSpacing:
                              2.0,
                        ),
                      ),

                      const SizedBox(
                        height: 18,
                      ),

                      SizedBox(
                        width: 330,
                        height: 330,
                        child: CustomPaint(
                          painter:
                              _CirclePainter(
                            progress:
                                _progress,
                            color:
                                phaseColor,
                          ),
                          child:
                              Center(
                            child:
                                Column(
                              mainAxisSize:
                                  MainAxisSize.min,
                              children: [
                                Text(
                                  _formatTime(
                                    _secondsLeft,
                                  ),
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white,
                                    fontSize:
                                        52,
                                    fontWeight:
                                        FontWeight.w300,
                                    letterSpacing:
                                        1.5,
                                  ),
                                ),

                                const SizedBox(
                                  height: 8,
                                ),

                                Text(
                                  'Cycle $_currentCycle / $_totalCycles',
                                  style:
                                      const TextStyle(
                                    color:
                                        Colors.white60,
                                    fontSize:
                                        13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 30,
                      ),

                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.center,
                        children: [
                          _buildActionButton(
                            icon:
                                _isRunning
                                    ? Icons.pause
                                    : Icons.play_arrow,
                            label:
                                _isRunning
                                    ? 'Pause'
                                    : 'Start',
                            onPressed:
                                _toggleTimer,
                            primary: true,
                          ),

                          const SizedBox(
                            width: 14,
                          ),

                          _buildActionButton(
                            icon:
                                Icons.refresh,
                            label:
                                'Reset',
                            onPressed:
                                _resetTimer,
                            primary: false,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              Padding(
                padding:
                    const EdgeInsets.only(
                  bottom: 20,
                  left: 20,
                  right: 20,
                ),
                child: Text(
                  _isLocked
                      ? 'Please complete your eye break.'
                      : 'Rest your eyes regularly.',
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Container(
      decoration:
          BoxDecoration(
        color: kTimerCircle,
        borderRadius:
            BorderRadius.circular(
          12,
        ),
        border:
            Border.all(
          color:
              Colors.white24,
        ),
      ),
      child: IconButton(
        icon:
            Icon(
          icon,
          color:
              Colors.white,
        ),
        onPressed:
            onPressed,
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool primary,
  }) {
    return OutlinedButton(
      style:
          OutlinedButton.styleFrom(
        backgroundColor:
            kTimerCircle,
        foregroundColor:
            Colors.white,
        side:
            BorderSide(
          color:
              primary
                  ? Colors.white38
                  : Colors.white24,
          width: 1.2,
        ),
        padding:
            const EdgeInsets.symmetric(
          horizontal: 22,
          vertical: 14,
        ),
        shape:
            RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(
            14,
          ),
        ),
      ),
      onPressed:
          onPressed,
      child: Row(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
          ),
          const SizedBox(
            width: 7,
          ),
          Text(
            label,
            style:
                const TextStyle(
              fontSize: 14,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Progress ring + timer circle
// -----------------------------------------------------------------------------

class _CirclePainter
    extends CustomPainter {
  final double progress;
  final Color color;

  const _CirclePainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final center =
        Offset(
      size.width / 2,
      size.height / 2,
    );

    // Outer circle background.
    // It is intentionally larger than the progress ring and fades
    // very softly toward the surrounding blue.
    final circleRadius =
        size.width / 2 - 2;

    final circleRect = Rect.fromCircle(
      center: center,
      radius: circleRadius,
    );

    final circlePaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          kTimerCircle,
          Color(0xFF263F4B),
          kBgAround,
        ],
        stops: const [
          0.0,
          0.72,
          1.0,
        ],
      ).createShader(circleRect)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      center,
      circleRadius,
      circlePaint,
    );

    // Very subtle fixed edge.
    final edgePaint = Paint()
      ..color =
          Colors.white.withOpacity(0.06)
      ..style =
          PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawCircle(
      center,
      circleRadius,
      edgePaint,
    );

    // Progress ring.
    final radius =
        size.width / 2 - 20;

    final backgroundRing =
        Paint()
          ..color =
              Colors.white.withOpacity(0.08)
          ..style =
              PaintingStyle.stroke
          ..strokeWidth = 10;

    canvas.drawCircle(
      center,
      radius,
      backgroundRing,
    );

    final progressPaint =
        Paint()
          ..color = color
          ..style =
              PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap =
              StrokeCap.round;

    final clampedProgress =
        progress.clamp(
      0.0,
      1.0,
    );

    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius,
      ),
      -math.pi / 2,
      2 *
          math.pi *
          clampedProgress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(
    covariant _CirclePainter oldDelegate,
  ) {
    return oldDelegate.progress !=
            progress ||
        oldDelegate.color != color;
  }
}

// -----------------------------------------------------------------------------
// Settings Page
// -----------------------------------------------------------------------------

class SettingsPage
    extends StatefulWidget {
  final int workMinutes;
  final int breakMinutes;
  final int totalCycles;
  final bool soundEnabled;
  final bool vibrateEnabled;

  const SettingsPage({
    super.key,
    required this.workMinutes,
    required this.breakMinutes,
    required this.totalCycles,
    required this.soundEnabled,
    required this.vibrateEnabled,
  });

  @override
  State<SettingsPage> createState() =>
      _SettingsPageState();
}

class _SettingsPageState
    extends State<SettingsPage> {
  late int _work;
  late int _brk;
  late int _cycles;

  late bool _sound;
  late bool _vibrate;

  @override
  void initState() {
    super.initState();

    _work =
        widget.workMinutes;

    _brk =
        widget.breakMinutes;

    _cycles =
        widget.totalCycles;

    _sound =
        widget.soundEnabled;

    _vibrate =
        widget.vibrateEnabled;
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          kBgAround,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            letterSpacing: 1.2,
          ),
        ),
        iconTheme:
            const IconThemeData(
          color: Colors.white,
        ),
      ),
      body: ListView(
        padding:
            const EdgeInsets.all(20),
        children: [
          _buildNumberRow(
            label:
                'Focus duration (min)',
            value: _work,
            min: 1,
            max: 120,
            onChange: (v) =>
                setState(
              () => _work = v,
            ),
          ),

          const SizedBox(height: 14),

          _buildNumberRow(
            label:
                'Break duration (min)',
            value: _brk,
            min: 1,
            max: 30,
            onChange: (v) =>
                setState(
              () => _brk = v,
            ),
          ),

          const SizedBox(height: 14),

          _buildNumberRow(
            label: 'Cycles',
            value: _cycles,
            min: 1,
            max: 30,
            onChange: (v) =>
                setState(
              () => _cycles = v,
            ),
          ),

          const SizedBox(height: 14),

          _buildSwitchTile(
            label: 'Sound',
            value: _sound,
            onChange: (v) =>
                setState(
              () => _sound = v,
            ),
          ),

          const SizedBox(height: 14),

          _buildSwitchTile(
            label: 'Vibration',
            value: _vibrate,
            onChange: (v) =>
                setState(
              () => _vibrate = v,
            ),
          ),

          const SizedBox(height: 32),

          ElevatedButton(
            style:
                ElevatedButton.styleFrom(
              backgroundColor:
                  kAccentFocus,
              foregroundColor:
                  Colors.black,
              padding:
                  const EdgeInsets.symmetric(
                vertical: 16,
              ),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  14,
                ),
              ),
            ),
            onPressed: () {
              Navigator.pop(
                context,
                {
                  'workMinutes':
                      _work,
                  'breakMinutes':
                      _brk,
                  'totalCycles':
                      _cycles,
                  'soundEnabled':
                      _sound,
                  'vibrateEnabled':
                      _vibrate,
                },
              );
            },
            child: const Text(
              'Save',
              style: TextStyle(
                fontSize: 16,
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberRow({
    required String label,
    required int value,
    required int min,
    required int max,
    required ValueChanged<int>
        onChange,
  }) {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 10,
      ),
      decoration:
          BoxDecoration(
        color: kTimerCircle,
        borderRadius:
            BorderRadius.circular(
          16,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
          ),

          IconButton(
            icon:
                const Icon(
              Icons.remove,
              color:
                  Colors.white70,
            ),
            onPressed:
                value > min
                    ? () => onChange(
                          value - 1,
                        )
                    : null,
          ),

          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight:
                    FontWeight.w500,
              ),
            ),
          ),

          IconButton(
            icon:
                const Icon(
              Icons.add,
              color:
                  Colors.white70,
            ),
            onPressed:
                value < max
                    ? () => onChange(
                          value + 1,
                        )
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String label,
    required bool value,
    required ValueChanged<bool>
        onChange,
  }) {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 4,
      ),
      decoration:
          BoxDecoration(
        color: kTimerCircle,
        borderRadius:
            BorderRadius.circular(
          16,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
          ),
          Switch(
            value: value,
            activeColor:
                kAccentFocus,
            onChanged:
                onChange,
          ),
        ],
      ),
    );
  }
}
