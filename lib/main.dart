import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'services/notification_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const BlinkApp());
}

class BlinkApp extends StatelessWidget {
  const BlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5D0),
          surface: Color(0xFF1A1A1A),
        ),
        useMaterial3: true,
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

class _TimerPageState extends State<TimerPage> with WidgetsBindingObserver {
  // Settings
  int _workMinutes = SettingsService.defaultWork;
  int _breakMinutes = SettingsService.defaultBreak;
  int _totalCycles = SettingsService.defaultCycles;
  bool _soundEnabled = SettingsService.defaultSound;

  // Timer state
  Timer? _ticker;
  int _currentCycle = 1;
  bool _isWorking = true;
  bool _isRunning = false;
  int _secondsLeft = 0;
  int _totalSecondsForPhase = 0;
  DateTime? _phaseEndTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _isRunning) {
      _resyncTimer();
    }
  }

  Future<void> _loadSettings() async {
    final s = await SettingsService.load();
    setState(() {
      _workMinutes = s['workMinutes'];
      _breakMinutes = s['breakMinutes'];
      _totalCycles = s['totalCycles'];
      _soundEnabled = s['soundEnabled'];
      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    });
  }

  void _resyncTimer() {
    if (_phaseEndTime == null) return;
    final now = DateTime.now();
    final diff = _phaseEndTime!.difference(now).inSeconds;
    if (diff <= 0) {
      _switchPhase();
    } else if (diff != _secondsLeft) {
      setState(() => _secondsLeft = diff);
    }
  }

  void _toggleTimer() {
    if (_isRunning) {
      _pauseTimer();
    } else {
      _startTimer();
    }
  }

  void _startTimer() {
    setState(() {
      _isRunning = true;
      _phaseEndTime = DateTime.now().add(Duration(seconds: _secondsLeft));
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft > 0) {
        setState(() => _secondsLeft--);
      } else {
        _switchPhase();
      }
    });
  }

  void _pauseTimer() {
    setState(() {
      _isRunning = false;
      _phaseEndTime = null;
    });
    _ticker?.cancel();
    NotificationService.instance.cancelAll();
  }

  Future<void> _switchPhase() async {
    _ticker?.cancel();

    if (_isWorking) {
      // Work -> Break
      _isWorking = false;
      _totalSecondsForPhase = _breakMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;

      if (_soundEnabled) {
        SystemSound.play(SystemSoundType.alert);
      }

      await WakelockPlus.enable();

      await NotificationService.instance.showNow(
        title: 'Time to rest your eyes 👁️',
        body: 'Take a $_breakMinutes minute break',
      );
    } else {
      // Break -> Work or End
      await WakelockPlus.disable();

      if (_currentCycle >= _totalCycles) {
        setState(() {
          _isRunning = false;
          _currentCycle = 1;
          _isWorking = true;
          _totalSecondsForPhase = _workMinutes * 60;
          _secondsLeft = _totalSecondsForPhase;
          _phaseEndTime = null;
        });
        if (_soundEnabled) {
          SystemSound.play(SystemSoundType.alert);
        }
        await NotificationService.instance.showNow(
          title: 'All cycles complete! 🎉',
          body: 'Great job, take a longer rest',
        );
        return;
      }

      _currentCycle++;
      _isWorking = true;
      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;

      if (_soundEnabled) {
        SystemSound.play(SystemSoundType.alert);
      }

      await NotificationService.instance.showNow(
        title: 'Back to work 💪',
        body: 'Cycle $_currentCycle of $_totalCycles started',
      );
    }

    setState(() {});
    _startTimer();
  }

  void _resetTimer() {
    _ticker?.cancel();
    NotificationService.instance.cancelAll();
    WakelockPlus.disable();
    setState(() {
      _isRunning = false;
      _isWorking = true;
      _currentCycle = 1;
      _totalSecondsForPhase = _workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
      _phaseEndTime = null;
    });
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          workMinutes: _workMinutes,
          breakMinutes: _breakMinutes,
          totalCycles: _totalCycles,
          soundEnabled: _soundEnabled,
        ),
      ),
    );

    if (result != null) {
      await SettingsService.save(
        workMinutes: result['workMinutes'],
        breakMinutes: result['breakMinutes'],
        totalCycles: result['totalCycles'],
        soundEnabled: result['soundEnabled'],
      );
      setState(() {
        _workMinutes = result['workMinutes'];
        _breakMinutes = result['breakMinutes'];
        _totalCycles = result['totalCycles'];
        _soundEnabled = result['soundEnabled'];
      });
      _resetTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalSecondsForPhase == 0
        ? 0.0
        : 1 - (_secondsLeft / _totalSecondsForPhase);
    final accentColor =
        _isWorking ? const Color(0xFF00E5D0) : const Color(0xFFFFB74D);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.settings, color: Colors.white54),
                onPressed: _openSettings,
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    _isWorking ? 'FOCUS' : 'EYE BREAK',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      letterSpacing: 4,
                      color: accentColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Cycle $_currentCycle of $_totalCycles',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 40),
                  GestureDetector(
                    onTap: _toggleTimer,
                    child: SizedBox(
                      width: 280,
                      height: 280,
                      child: CustomPaint(
                        painter: _CirclePainter(
                          progress: progress,
                          color: accentColor,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _formatTime(_secondsLeft),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 56,
                                  fontWeight: FontWeight.w300,
                                  color: Colors.white,
                                  fontFeatures: [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _isRunning ? 'tap to pause' : 'tap to start',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white38,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextButton.icon(
                    onPressed: _resetTimer,
                    icon: const Icon(Icons.refresh, color: Colors.white54),
                    label: const Text(
                      'Reset',
                      style: TextStyle(color: Colors.white54, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CirclePainter extends CustomPainter {
  final double progress;
  final Color color;

  _CirclePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;

    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawCircle(center, radius, bgPaint);

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CirclePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class SettingsPage extends StatefulWidget {
  final int workMinutes;
  final int breakMinutes;
  final int totalCycles;
  final bool soundEnabled;

  const SettingsPage({
    super.key,
    required this.workMinutes,
    required this.breakMinutes,
    required this.totalCycles,
    required this.soundEnabled,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late int _work;
  late int _brk;
  late int _cycles;
  late bool _sound;

  @override
  void initState() {
    super.initState();
    _work = widget.workMinutes;
    _brk = widget.breakMinutes;
    _cycles = widget.totalCycles;
    _sound = widget.soundEnabled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildNumberRow(
            label: 'Work duration (min)',
            value: _work,
            min: 1,
            max: 120,
            onChange: (v) => setState(() => _work = v),
          ),
          const SizedBox(height: 16),
          _buildNumberRow(
            label: 'Break duration (min)',
            value: _brk,
            min: 1,
            max: 30,
            onChange: (v) => setState(() => _brk = v),
          ),
          const SizedBox(height: 16),
          _buildNumberRow(
            label: 'Cycles',
            value: _cycles,
            min: 1,
            max: 30,
            onChange: (v) => setState(() => _cycles = v),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Sound', style: TextStyle(color: Colors.white)),
            value: _sound,
            activeColor: const Color(0xFF00E5D0),
            onChanged: (v) => setState(() => _sound = v),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5D0),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: () {
              Navigator.pop(context, {
                'workMinutes': _work,
                'breakMinutes': _brk,
                'totalCycles': _cycles,
                'soundEnabled': _sound,
              });
            },
            child: const Text('Save', style: TextStyle(fontSize: 16)),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove, color: Colors.white70),
            onPressed: value > min ? () => onChange(value - 1) : null,
          ),
          Text(
            '$value',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white70),
            onPressed: value < max ? () => onChange(value + 1) : null,
          ),
        ],
      ),
    );
  }
}
