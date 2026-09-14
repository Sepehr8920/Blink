import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'services/sound_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const BlinkApp());
}

// Color palette — Slate Blue theme
const Color kBgDeep = Color(0xFF0F172A);
const Color kBgMid = Color(0xFF1E293B);
const Color kAccentFocus = Color(0xFF7DD3FC);
const Color kAccentBreak = Color(0xFFFCD34D);
const Color kSurface = Color(0xFF334155);

class BlinkApp extends StatelessWidget {
  const BlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBgDeep,
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

class TimerPage extends StatefulWidget {
  const TimerPage({super.key});

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _workMinutes = SettingsService.defaultWork;
  int _breakMinutes = SettingsService.defaultBreak;
  int _totalCycles = SettingsService.defaultCycles;
  bool _soundEnabled = SettingsService.defaultSound;
  bool _vibrateEnabled = SettingsService.defaultVibrate;

  Timer? _ticker;

  int _currentCycle = 1;
  bool _isWorking = true;
  bool _isRunning = false;
  int _secondsLeft = 0;
  int _totalSecondsForPhase = 0;

  // Monotonic timer:
  // Stopwatch is not affected by changing the phone's wall-clock time.
  final Stopwatch _phaseStopwatch = Stopwatch();

  // Prevent the same phase from being switched more than once
  // when lifecycle/ticker callbacks happen close together.
  bool _isSwitchingPhase = false;

  late AnimationController _progressController;

  bool get _isLocked => !_isWorking && _isRunning;

  @override
  void initState() {
    super.initState();

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      lowerBound: 0.0,
      upperBound: 1.0,
    );

    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _ticker?.cancel();
    _phaseStopwatch.stop();

    _progressController.dispose();

    WakelockPlus.disable();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (_isRunning) {
        // Recalculate immediately using the monotonic stopwatch,
        // then restart the UI ticker.
        _updateTimerFromElapsed();
        _startTicker();
      }
    } else {
      // Do not stop the stopwatch.
      // We only stop the UI ticker to avoid unnecessary work while
      // the app is not visible.
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _loadSettings() async {
    final s = await SettingsService.load();

    if (!mounted) return;

    setState(() {
      _workMinutes = s['workMinutes'];
      _breakMinutes = s['breakMinutes'];
      _totalCycles = s['totalCycles'];
      _soundEnabled = s['soundEnabled'];
      _vibrateEnabled = s['vibrateEnabled'];

      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    });
  }

  void _toggleTimer() {
    if (_isRunning) {
      _pauseTimer();
    } else {
      _startTimer();
    }
  }

  void _startTimer() {
    if (_secondsLeft <= 0 || _totalSecondsForPhase <= 0) {
      return;
    }

    if (_isRunning) {
      return;
    }

    setState(() {
      _isRunning = true;
    });

    // Continue the same Stopwatch from exactly where it was paused.
    // If this is the first start, it starts from zero.
    if (!_phaseStopwatch.isRunning) {
      _phaseStopwatch.start();
    }

    // Immediately synchronize the UI with the stopwatch.
    _updateTimerFromElapsed();

    // Then keep the visible countdown/progress updated.
    _startTicker();

    WakelockPlus.enable();
  }

  void _startTicker() {
    _ticker?.cancel();

    if (!_isRunning) {
      return;
    }

    _ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (!_isRunning || _isSwitchingPhase) {
          return;
        }

        _updateTimerFromElapsed();
      },
    );
  }

  void _updateTimerFromElapsed() {
    if (!_isRunning || _totalSecondsForPhase <= 0) {
      return;
    }

    final totalMs = _totalSecondsForPhase * 1000;
    final elapsedMs = _phaseStopwatch.elapsedMilliseconds;

    final remainingMs = totalMs - elapsedMs;

    if (remainingMs <= 0) {
      _progressController.value = 1.0;

      _secondsLeft = 0;

      if (mounted) {
        setState(() {});
      }

      _switchPhase();
      return;
    }

    final progress = (elapsedMs / totalMs).clamp(0.0, 1.0);

    // The progress ring is driven directly from elapsed time.
    // There is no separate animation that can jump when pausing/resuming.
    _progressController.value = progress;

    final remainingSeconds = (remainingMs / 1000).ceil();

    if (mounted) {
      if (_secondsLeft != remainingSeconds) {
        setState(() {
          _secondsLeft = remainingSeconds;
        });
      } else {
        // Rebuild is still useful for the progress ring because its
        // value can change between visible seconds.
        setState(() {});
      }
    }
  }

  void _pauseTimer() {
    if (!_isRunning) {
      return;
    }

    // Stop the stopwatch at the exact current elapsed position.
    _phaseStopwatch.stop();

    // Update one final time while stopped so the UI represents the
    // exact pause position.
    _updateTimerFromElapsed();

    _ticker?.cancel();
    _ticker = null;

    if (mounted) {
      setState(() {
        _isRunning = false;
      });
    }

    NotificationService.instance.cancelAll();
    WakelockPlus.disable();
  }

  Future<void> _alert({
    required bool fullScreen,
    required String title,
    required String body,
  }) async {
    if (_soundEnabled) {
      SoundService.instance.playChime();
    }

    if (_vibrateEnabled) {
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 200));
      HapticFeedback.heavyImpact();
    }

    if (fullScreen) {
      await NotificationService.instance.showBreakAlert(
        title: title,
        body: body,
      );
    } else {
      await NotificationService.instance.showSimple(
        title: title,
        body: body,
      );
    }
  }

  Future<void> _switchPhase() async {
    if (_isSwitchingPhase) {
      return;
    }

    _isSwitchingPhase = true;

    _ticker?.cancel();
    _ticker = null;

    _phaseStopwatch.stop();
    _phaseStopwatch.reset();

    _progressController.value = 0.0;

    if (_isWorking) {
      _isWorking = false;
      _totalSecondsForPhase = _breakMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;

      if (mounted) {
        setState(() {});
      }

      await WakelockPlus.enable();

      await _alert(
        fullScreen: true,
        title: 'Rest your eyes 👁️',
        body:
            'Look away for $_breakMinutes minute${_breakMinutes > 1 ? 's' : ''}',
      );

      _isSwitchingPhase = false;

      if (mounted) {
        setState(() {});
      }

      _startTimer();
      return;
    }

    await WakelockPlus.disable();

    if (_currentCycle >= _totalCycles) {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _currentCycle = 1;
          _isWorking = true;
          _totalSecondsForPhase = _workMinutes * 60;
          _secondsLeft = _totalSecondsForPhase;
        });
      }

      await _alert(
        fullScreen: false,
        title: 'All done! 🎉',
        body: 'Great job today',
      );

      _isSwitchingPhase = false;
      return;
    }

    _currentCycle++;
    _isWorking = true;
    _totalSecondsForPhase = _workMinutes * 60;
    _secondsLeft = _totalSecondsForPhase;

    if (mounted) {
      setState(() {});
    }

    await _alert(
      fullScreen: false,
      title: 'Back to focus 💪',
      body: 'Cycle $_currentCycle of $_totalCycles',
    );

    _isSwitchingPhase = false;

    _startTimer();
  }

  void _resetTimer() {
    _ticker?.cancel();
    _ticker = null;

    _phaseStopwatch.stop();
    _phaseStopwatch.reset();

    _progressController.stop();
    _progressController.value = 0.0;

    NotificationService.instance.cancelAll();
    WakelockPlus.disable();

    if (!mounted) {
      return;
    }

    setState(() {
      _isRunning = false;
      _isWorking = true;
      _currentCycle = 1;
      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    });
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _openSettings() async {
    if (_isLocked) {
      return;
    }

    final result = await Navigator.push<Map<String, dynamic>>(
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

    if (result != null) {
      await SettingsService.save(
        workMinutes: result['workMinutes'],
        breakMinutes: result['breakMinutes'],
        totalCycles: result['totalCycles'],
        soundEnabled: result['soundEnabled'],
        vibrateEnabled: result['vibrateEnabled'],
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _workMinutes = result['workMinutes'];
        _breakMinutes = result['breakMinutes'];
        _totalCycles = result['totalCycles'];
        _soundEnabled = result['soundEnabled'];
        _vibrateEnabled = result['vibrateEnabled'];
      });

      _resetTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _isWorking ? kAccentFocus : kAccentBreak;

    return PopScope(
      canPop: !_isLocked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isLocked) {
          HapticFeedback.lightImpact();
        }
      },
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.4,
              colors: [
                accent.withOpacity(0.12),
                kBgMid,
                kBgDeep,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                if (!_isLocked)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      icon: const Icon(
                        Icons.settings,
                        color: Colors.white54,
                      ),
                      onPressed: _openSettings,
                    ),
                  ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: Text(
                          _isWorking ? 'FOCUS' : 'EYE BREAK',
                          key: ValueKey(_isWorking),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            letterSpacing: 6,
                            color: accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isLocked
                            ? 'Look away from the screen'
                            : 'Cycle $_currentCycle of $_totalCycles',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: _isLocked ? 15 : 14,
                          color: Colors.white.withOpacity(0.55),
                        ),
                      ),
                      const SizedBox(height: 44),
                      GestureDetector(
                        onTap: _isLocked ? null : _toggleTimer,
                        child: SizedBox(
                          width: 290,
                          height: 290,
                          child: AnimatedBuilder(
                            animation: _progressController,
                            builder: (context, child) {
                              return CustomPaint(
                                painter: _CirclePainter(
                                  progress: _progressController.value,
                                  color: accent,
                                ),
                                child: child,
                              );
                            },
                            child: Center(
                              child: Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _formatTime(_secondsLeft),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 60,
                                      fontWeight: FontWeight.w200,
                                      color: Colors.white,
                                      letterSpacing: 1.5,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  _buildHint(accent),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 44),
                      if (!_isLocked)
                        TextButton.icon(
                          onPressed: _resetTimer,
                          icon: const Icon(
                            Icons.refresh,
                            color: Colors.white54,
                          ),
                          label: const Text(
                            'Reset',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 15,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHint(Color accent) {
    final hintColor = Colors.white.withOpacity(0.35);
    final iconColor = accent.withOpacity(0.75);

    if (_isLocked) {
      return Text(
        'breathe slowly',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: hintColor,
          letterSpacing: 0.5,
        ),
      );
    }

    final label = _isRunning ? 'tap to pause' : 'tap to start';
    final icon =
        _isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: animation,
            child: child,
          ),
        );
      },
      child: Row(
        key: ValueKey(_isRunning),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 18,
            color: iconColor,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: hintColor,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CirclePainter extends CustomPainter {
  final double progress;
  final Color color;

  _CirclePainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;

    final glowPaint = Paint()
      ..color = color.withOpacity(0.14)
      ..maskFilter = const MaskFilter.blur(
        BlurStyle.normal,
        20,
      );

    canvas.drawCircle(
      center,
      radius,
      glowPaint,
    );

    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;

    canvas.drawCircle(
      center,
      radius,
      bgPaint,
    );

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(
        center: center,
        radius: radius,
      ),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CirclePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color;
  }
}

class SettingsPage extends StatefulWidget {
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
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late int _work;
  late int _brk;
  late int _cycles;
  late bool _sound;
  late bool _vibrate;

  @override
  void initState() {
    super.initState();

    _work = widget.workMinutes;
    _brk = widget.breakMinutes;
    _cycles = widget.totalCycles;
    _sound = widget.soundEnabled;
    _vibrate = widget.vibrateEnabled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            letterSpacing: 1.2,
          ),
        ),
        iconTheme: const IconThemeData(
          color: Colors.white,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildNumberRow(
            label: 'Focus duration (min)',
            value: _work,
            min: 1,
            max: 120,
            onChange: (v) => setState(() => _work = v),
          ),
          const SizedBox(height: 14),
          _buildNumberRow(
            label: 'Break duration (min)',
            value: _brk,
            min: 1,
            max: 30,
            onChange: (v) => setState(() => _brk = v),
          ),
          const SizedBox(height: 14),
          _buildNumberRow(
            label: 'Cycles',
            value: _cycles,
            min: 1,
            max: 30,
            onChange: (v) => setState(() => _cycles = v),
          ),
          const SizedBox(height: 14),
          _buildSwitchTile(
            label: 'Sound',
            value: _sound,
            onChange: (v) => setState(() => _sound = v),
          ),
          const SizedBox(height: 14),
          _buildSwitchTile(
            label: 'Vibration',
            value: _vibrate,
            onChange: (v) => setState(() => _vibrate = v),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kAccentFocus,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                vertical: 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: () {
              Navigator.pop(
                context,
                {
                  'workMinutes': _work,
                  'breakMinutes': _brk,
                  'totalCycles': _cycles,
                  'soundEnabled': _sound,
                  'vibrateEnabled': _vibrate,
                },
              );
            },
            child: const Text(
              'Save',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
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
    required ValueChanged<int> onChange,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.remove,
              color: Colors.white70,
            ),
            onPressed: value > min
                ? () => onChange(value - 1)
                : null,
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.add,
              color: Colors.white70,
            ),
            onPressed: value < max
                ? () => onChange(value + 1)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChange,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
          ),
          Switch(
            value: value,
            activeColor: kAccentFocus,
            onChanged: onChange,
          ),
        ],
      ),
    );
  }
}
