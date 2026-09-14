import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  final AudioPlayer _player = AudioPlayer();
  Uint8List? _cachedChime;
  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      await _player.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
      _initialized = true;
    } catch (_) {}
  }

  Future<void> playChime() async {
    try {
      await _ensureInit();
      await _player.stop();
      await _player.play(BytesSource(_getChime()));
    } catch (_) {}
  }

  Uint8List _getChime() {
    _cachedChime ??= _generateChime();
    return _cachedChime!;
  }

  Uint8List _generateChime() {
    // Two-tone chime: E5 (659Hz) then A5 (880Hz), with smooth decay.
    const sampleRate = 44100;
    const durationMs = 750;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final dataSize = numSamples * 2;
    final buffer = BytesBuilder();

    // WAV header
    buffer.add(ascii.encode('RIFF'));
    buffer.add(_int32LE(36 + dataSize));
    buffer.add(ascii.encode('WAVE'));
    buffer.add(ascii.encode('fmt '));
    buffer.add(_int32LE(16));
    buffer.add(_int16LE(1)); // PCM
    buffer.add(_int16LE(1)); // mono
    buffer.add(_int32LE(sampleRate));
    buffer.add(_int32LE(sampleRate * 2)); // byte rate
    buffer.add(_int16LE(2)); // block align
    buffer.add(_int16LE(16)); // bits per sample
    buffer.add(ascii.encode('data'));
    buffer.add(_int32LE(dataSize));

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      double sample;
      if (t < 0.32) {
        final env = math.exp(-3.5 * t) * (1 - math.exp(-60 * t));
        sample = math.sin(2 * math.pi * 659 * t) * env;
      } else {
        final tt = t - 0.32;
        final env = math.exp(-3.5 * tt) * (1 - math.exp(-60 * tt));
        sample = math.sin(2 * math.pi * 880 * tt) * env;
      }
      final v = (sample * 32767 * 0.55).round();
      buffer.add(_int16LE(v));
    }

    return buffer.toBytes();
  }

  List<int> _int32LE(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];

  List<int> _int16LE(int v) {
    final x = v & 0xFFFF;
    return [x & 0xFF, (x >> 8) & 0xFF];
  }
}
