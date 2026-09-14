import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _keyWork = 'work_minutes';
  static const _keyBreak = 'break_minutes';
  static const _keyCycles = 'total_cycles';
  static const _keySound = 'sound_enabled';

  static int defaultWork = 20;
  static int defaultBreak = 3;
  static int defaultCycles = 4;
  static bool defaultSound = true;

  static Future<Map<String, dynamic>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'workMinutes': prefs.getInt(_keyWork) ?? defaultWork,
      'breakMinutes': prefs.getInt(_keyBreak) ?? defaultBreak,
      'totalCycles': prefs.getInt(_keyCycles) ?? defaultCycles,
      'soundEnabled': prefs.getBool(_keySound) ?? defaultSound,
    };
  }

  static Future<void> save({
    required int workMinutes,
    required int breakMinutes,
    required int totalCycles,
    required bool soundEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyWork, workMinutes);
    await prefs.setInt(_keyBreak, breakMinutes);
    await prefs.setInt(_keyCycles, totalCycles);
    await prefs.setBool(_keySound, soundEnabled);
  }
}
