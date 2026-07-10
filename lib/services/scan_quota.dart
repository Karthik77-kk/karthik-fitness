import 'package:shared_preferences/shared_preferences.dart';

/// Per-user daily quota for AI photo scans.
///
/// The Gemini free tier is a single shared pool, so every user is capped at
/// [dailyLimit] scans per day — no exemptions. The counter is keyed per calendar
/// day and resets automatically at midnight local.
class ScanQuota {
  static const int dailyLimit = 10;

  static String _todayKey() {
    final n = DateTime.now();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return 'ai_scan_count_${n.year}-$m-$d';
  }

  /// Scans already used today.
  static int usedToday(SharedPreferences prefs) => prefs.getInt(_todayKey()) ?? 0;

  /// Scans left today, clamped to [0, dailyLimit].
  static int remaining(SharedPreferences prefs) =>
      (dailyLimit - usedToday(prefs)).clamp(0, dailyLimit);

  /// Whether the user may run another scan right now.
  static bool canScan(SharedPreferences prefs) => usedToday(prefs) < dailyLimit;

  /// Record one successful scan against today's quota. Call this only after a
  /// scan actually succeeds, so failed calls don't burn credits.
  static Future<void> record(SharedPreferences prefs) async {
    await prefs.setInt(_todayKey(), usedToday(prefs) + 1);
  }
}
