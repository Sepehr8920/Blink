import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

void main() {
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

class _TimerPageState extends State<TimerPage> {
  // تنظیمات پیش‌فرض
  int workMinutes = 20;
  int breakMinutes = 3;
  int totalCycles = 4;

  // وضعیت تایمر
  Timer? _ticker;
  int _currentCycle = 1;
  bool _isWorking = true;      // true = کار، false = استراحت
  bool _isRunning = false;     // آیا تایمر داره می‌شمره؟
  int _secondsLeft = 20 * 60;  // ثانیه‌های باقی‌مونده
  int _totalSecondsForPhase = 20 * 60;  // کل ثانیه‌های این فاز

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _toggleTimer() {
    if (_isRunning) {
      _pauseTimer();
    } else {
      _startTimer();
    }
  }

  void _startTimer() {
    setState(() => _isRunning = true);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
        } else {
          _switchPhase();
        }
      });
    });
  }

  void _pauseTimer() {
    setState(() => _isRunning = false);
    _ticker?.cancel();
  }

  void _switchPhase() {
    _ticker?.cancel();
    if (_isWorking) {
      // کار تموم شد، برو استراحت
      _isWorking = false;
      _totalSecondsForPhase = breakMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    } else {
      // استراحت تموم شد
      if (_currentCycle >= totalCycles) {
        // همه‌ی چرخه‌ها تموم شد
        _isRunning = false;
        _currentCycle = 1;
        _isWorking = true;
        _totalSecondsForPhase = workMinutes * 60;
        _secondsLeft = _totalSecondsForPhase;
        return;
      }
      _currentCycle++;
      _isWorking = true;
      _totalSecondsForPhase = workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    }
    // خودکار فاز بعدی رو شروع کن
    _startTimer();
  }

  void _resetTimer() {
    _ticker?.cancel();
    setState(() {
      _isRunning = false;
      _isWorking = true;
      _currentCycle = 1;
      _totalSecondsForPhase = workMinutes * 60;
      _secondsLeft = _totalSecondsForPhase;
    });
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = 1 - (_secondsLeft / _totalSecondsForPhase);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 32),
            // عنوان فاز
            Text(
              _isWorking ? 'زمان کار' : 'استراحت چشم',
              style: TextStyle(
                fontSize: 22,
                color: _isWorking
                    ? const Color(0xFF00E5D0)
                    : const Color(0xFFFFB74D),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            // شمارنده‌ی چرخه
            Text(
              'چرخه $_currentCycle از $totalCycles',
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white54,
              ),
            ),
            const Spacer(),
            // دایره‌ی تایمر
            GestureDetector(
              onTap: _toggleTimer,
              child: SizedBox(
                width: 280,
                height: 280,
                child: CustomPaint(
                  painter: _CirclePainter(
                    progress: progress,
                    color: _isWorking
                        ? const Color(0xFF00E5D0)
                        : const Color(0xFFFFB74D),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _formatTime(_secondsLeft),
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w300,
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isRunning ? 'برای توقف بزن' : 'برای شروع بزن',
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
            const Spacer(),
            // دکمه‌ی ریست
            TextButton.icon(
              onPressed: _resetTimer,
              icon: const Icon(Icons.refresh, color: Colors.white54),
              label: const Text(
                'شروع دوباره',
                style: TextStyle(color: Colors.white54, fontSize: 15),
              ),
            ),
            const SizedBox(height: 32),
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

    // دایره‌ی پس‌زمینه (کم‌رنگ)
    final bgPaint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawCircle(center, radius, bgPaint);

    // دایره‌ی پیشرفت (رنگی)
    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,           // از بالا شروع کن
      2 * math.pi * progress, // چقدر پر شده
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CirclePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
