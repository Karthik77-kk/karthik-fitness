import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';
import 'package:pedometer/pedometer.dart';
import 'package:home_widget/home_widget.dart';

import '../models/models.dart';
import '../services/smart_insight_engine.dart' show topInsights, Insight;
import '../services/notification_center.dart';
import '../services/chat_session_service.dart';
import '../services/food_repository.dart' show normalizeFood, FoodRepository;
import '../services/gemini_text_service.dart';
import '../services/integrity_check_service.dart';
import '../services/haptics.dart';

/// Where the AI coach runs: on-device Gemma (offline, private, ~600 MB download)
/// or a cheap/fast cloud model (Gemini Flash-Lite — needs internet + the built-in
/// key, but nothing to download). Default is [local].
enum AiCoachMode { local, cloud }

class FitnessProvider extends ChangeNotifier {
  // ── Data-version counter (hot-path memoization) ────────────────────────────
  // Bumped on every [notifyListeners] — i.e. on every state mutation — so
  // memoized derived values (the insight snapshot, the merged food/water maps)
  // can cheaply detect "did anything change since I last computed?" without
  // re-deriving on rebuilds that carry no data change. Correct by construction:
  // any mutation that matters already calls notifyListeners.
  int _dataVersion = 0;

  @override
  void notifyListeners() {
    _dataVersion++;
    super.notifyListeners();
  }

  // ── Daily targets (defaults — overridden by user settings) ────────────────
  static const int kDefaultCalorieGoal = 1700;
  static const int kDefaultProteinGoal = 100;
  static const int kDefaultWaterGoalMl = 2500;
  static const int kDefaultStepGoal = 8000;

  // Mutable goals (loaded from prefs, fallback to defaults)
  int _calorieGoal = kDefaultCalorieGoal;
  int _proteinGoal = kDefaultProteinGoal;
  int _waterGoalMl = kDefaultWaterGoalMl;
  int _stepGoal = kDefaultStepGoal;

  int get calorieGoal => _calorieGoal;
  int get proteinGoal => _proteinGoal;
  int get waterGoalMl => _waterGoalMl;
  int get stepGoal => _stepGoal;

  // Keep static consts as aliases so old static references compile
  static const int kCalorieGoal = kDefaultCalorieGoal;
  static const int kProteinGoal = kDefaultProteinGoal;
  static const int kWaterGoalMl = kDefaultWaterGoalMl;
  static const int kStepGoal = kDefaultStepGoal;

  Future<void> saveCalorieGoal(int kcal) async {
    _calorieGoal = kcal.clamp(800, 5000);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('calorie_goal', _calorieGoal);
    notifyListeners();
  }

  Future<void> saveProteinGoal(int g) async {
    _proteinGoal = g.clamp(20, 300);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('protein_goal', _proteinGoal);
    notifyListeners();
  }

  Future<void> saveWaterGoal(int ml) async {
    _waterGoalMl = ml.clamp(500, 8000);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('water_goal_ml', _waterGoalMl);
    notifyListeners();
  }

  Future<void> saveStepGoal(int steps) async {
    _stepGoal = steps.clamp(1000, 30000);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('step_goal', _stepGoal);
    notifyListeners();
  }

  // ── Macro goals (carbs / fat) ──────────────────────────────────────────────
  // Defaults reflect a moderate fat-loss split; both are user-configurable.
  static const int kDefaultCarbGoal = 200; // grams/day
  static const int kDefaultFatGoal = 55;   // grams/day

  int _carbGoal = kDefaultCarbGoal;
  int _fatGoal = kDefaultFatGoal;
  int get carbGoal => _carbGoal;
  int get fatGoal => _fatGoal;

  Future<void> saveCarbGoal(int g) async {
    _carbGoal = g.clamp(20, 600);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('carb_goal', _carbGoal);
    notifyListeners();
  }

  Future<void> saveFatGoal(int g) async {
    _fatGoal = g.clamp(10, 300);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('fat_goal', _fatGoal);
    notifyListeners();
  }

  double get carbProgress =>
      carbGoal > 0 ? (todayCarbsEstimate / carbGoal).clamp(0.0, 1.0) : 0.0;
  double get fatProgress =>
      fatGoal > 0 ? (todayFatEstimate / fatGoal).clamp(0.0, 1.0) : 0.0;

  /// Protein still needed to hit today's goal (0 once reached). Protein is a
  /// target to *reach*, so this never goes negative.
  int get proteinRemaining =>
      (proteinGoal - todayProteinTotal).round().clamp(0, 1 << 30);

  // ── Per-food portion memory ────────────────────────────────────────────────
  // Remembers the last quantity (servings for curated items, grams for per-100g
  // items) logged for a food, keyed by its normalized name, so the quantity
  // picker can default to it next time.
  Map<String, double> _foodPortions = {};

  double? lastPortion(String foodName) {
    final v = _foodPortions[normalizeFood(foodName)];
    return (v != null && v > 0) ? v : null;
  }

  Future<void> rememberPortion(String foodName, double qty) async {
    final key = normalizeFood(foodName);
    if (key.isEmpty || qty <= 0) return;
    if (_foodPortions[key] == qty) return;
    _foodPortions[key] = qty;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('food_portions', jsonEncode(_foodPortions));
  }

  // ── Favorite foods (pinned to top of Add-Food) ─────────────────────────────
  Set<String> _favoriteFoods = {}; // normalized names

  bool isFavoriteFood(String name) =>
      _favoriteFoods.contains(normalizeFood(name));

  Future<void> toggleFavoriteFood(String name) async {
    final key = normalizeFood(name);
    if (key.isEmpty) return;
    if (!_favoriteFoods.remove(key)) _favoriteFoods.add(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorite_foods', _favoriteFoods.toList());
    notifyListeners();
  }

  /// Favorited foods resolved to [FoodItem]s from the curated DB + IFCT, in the
  /// curated-then-IFCT order, deduped by name.
  List<FoodItem> get favoriteFoodItems {
    if (_favoriteFoods.isEmpty) return const [];
    final out = <FoodItem>[];
    final seen = <String>{};
    for (final f in [...kFoodDatabase, ...FoodRepository.instance.ifctFoods]) {
      final key = normalizeFood(f.name);
      if (_favoriteFoods.contains(key) && seen.add(key)) out.add(f);
    }
    return out;
  }

  // ── Backup reminder ────────────────────────────────────────────────────────
  int _lastBackupMs = 0;
  int get lastBackupMs => _lastBackupMs;

  /// Whole days since the last successful export, or null if never backed up.
  int? get daysSinceBackup {
    if (_lastBackupMs <= 0) return null;
    final ms = DateTime.now().millisecondsSinceEpoch - _lastBackupMs;
    return ms ~/ const Duration(days: 1).inMilliseconds;
  }

  /// True when the user has real data worth protecting and either never backed
  /// up or it's been >14 days — drives the gentle Home/Settings nudge.
  bool get needsBackupReminder {
    final hasData = _workoutHistory.isNotEmpty ||
        _foodHistory.isNotEmpty ||
        _bodyHistory.isNotEmpty ||
        _todayFood.isNotEmpty;
    if (!hasData) return false;
    final d = daysSinceBackup;
    return d == null || d >= 14;
  }

  Future<void> markBackedUp() async {
    _lastBackupMs = DateTime.now().millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_backup_ms', _lastBackupMs);
    notifyListeners();
  }

  // ── User profile ───────────────────────────────────────────────────────────
  double _heightCm = 170.0;
  double get heightCm => _heightCm;

  int _age = 24;
  int get age => _age;

  bool _isMale = true;
  bool get isMale => _isMale;
  bool get isFemale => !_isMale;

  double _goalWeightKg = 70.0;
  double get goalWeightKg => _goalWeightKg;

  // ── Goal direction (lose / maintain / gain) ────────────────────────────────
  // Drives the calorie recommendation and flips the coaching copy. Defaults to
  // [GoalDirection.lose] for a brand-new profile; existing users are migrated
  // once in [loadData] by inferring from goal vs current weight.
  GoalDirection _goalDirection = GoalDirection.lose;
  GoalDirection get goalDirection => _goalDirection;

  /// True when the user is bulking — being *under* the calorie goal is the
  /// problem, not the win. The insight/notification copy reads this.
  bool get wantsSurplus => _goalDirection == GoalDirection.gain;

  /// True when the user is cutting — the classic fat-loss framing applies.
  bool get wantsDeficit => _goalDirection == GoalDirection.lose;

  Future<void> saveGoalDirection(GoalDirection dir) async {
    _goalDirection = dir;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('goal_direction', dir.name);
    notifyListeners();
  }

  /// Infers a goal direction from goal weight vs current weight — goal clearly
  /// below current → lose, clearly above → gain, within ~1 kg → maintain. Used
  /// as the one-time migration default for users predating the setting.
  static GoalDirection inferGoalDirection(
      {required double goalWeightKg, double? currentWeightKg}) {
    final current = currentWeightKg;
    if (current == null) return GoalDirection.lose; // no data — keep old default
    final delta = goalWeightKg - current; // +ve = goal above current = gain
    if (delta > 1.0) return GoalDirection.gain;
    if (delta < -1.0) return GoalDirection.lose;
    return GoalDirection.maintain;
  }

  // ── Haptic feedback preference ─────────────────────────────────────────────
  // Governs the app-wide [Haptics] helper. Defaults on. The static
  // [Haptics.enabled] flag is kept in sync here so every widget can fire a
  // haptic without reading the provider.
  bool _hapticsEnabled = true;
  bool get hapticsEnabled => _hapticsEnabled;

  Future<void> saveHapticsEnabled(bool value) async {
    _hapticsEnabled = value;
    Haptics.enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('haptics_enabled', value);
    notifyListeners();
  }

  String _userName = 'Friend';
  String get userName => _userName;

  bool _onboardingDone = false;
  bool get onboardingDone => _onboardingDone;

  /// When false, the AI Coach is fully disabled — hidden from the Home screen
  /// and its sub-tiles/chat entry collapsed in Settings. Defaults to true so
  /// existing users keep the feature unless they opt out.
  bool _aiCoachEnabled = true;
  bool get aiCoachEnabled => _aiCoachEnabled;

  /// AI-coach backend: on-device Gemma (default) or cheap cloud model. Persisted.
  AiCoachMode _aiCoachMode = AiCoachMode.local;
  AiCoachMode get aiCoachMode => _aiCoachMode;

  /// Cached once-a-day AI "daily brief" (cloud). Null until generated for today.
  String? _dailyBrief;
  String? get dailyBrief => _dailyBrief;

  bool _autoUpdateCheck = true;
  bool get autoUpdateCheck => _autoUpdateCheck;

  /// True if this APK's signing certificate doesn't match the official
  /// release build — see [IntegrityCheckService]. Resolved as part of
  /// [loadData]'s critical path (before [_isLoaded] flips true) so the app
  /// never shows a real screen before this is known — always false on
  /// local/debug builds, where the check is a no-op.
  bool _isTampered = false;
  bool get isTampered => _isTampered;

  /// Test-only seam for exercising the tampered-block gate in main.dart
  /// without needing a --dart-define at test-run time.
  @visibleForTesting
  void debugSetTampered(bool value) {
    _isTampered = value;
    notifyListeners();
  }

  /// Epoch ms until which the user has snoozed update prompts (via "Later").
  int _updateSnoozedUntilMs = 0;
  /// Epoch ms when the user last tapped "Update" — suppresses re-prompts for 2 h
  /// so the app doesn't immediately ask for another update right after an install.
  int _updateInitiatedAtMs = 0;

  /// True when the update dialog should be suppressed — either the user snoozed
  /// it for 3 days via "Later", or they just initiated an install (2-h window).
  bool get shouldSuppressUpdateCheck {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _updateSnoozedUntilMs) return true;
    if (now - _updateInitiatedAtMs < const Duration(hours: 2).inMilliseconds) {
      return true;
    }
    return false;
  }

  Future<void> markOnboardingDone() async {
    _onboardingDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    notifyListeners();
  }

  Future<void> saveAiCoachEnabled(bool value) async {
    _aiCoachEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ai_coach_enabled', value);
    notifyListeners();
  }

  Future<void> saveAiCoachMode(AiCoachMode mode) async {
    _aiCoachMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'ai_coach_mode', mode == AiCoachMode.cloud ? 'cloud' : 'local');
    notifyListeners();
  }

  /// Generates the once-a-day AI "daily brief" via the cheap cloud model, cached
  /// per calendar day so it hits the network at most once daily. Returns the
  /// cached brief (or null) without a call when cloud AI isn't configured or the
  /// coach is disabled. Safe to call on every launch.
  Future<String?> refreshDailyBriefIfDue() async {
    if (!GeminiTextService.isConfigured || !_aiCoachEnabled) return _dailyBrief;
    final prefs = await SharedPreferences.getInstance();
    final today = _todayKey;
    if (prefs.getString('ai_brief_date') == today &&
        (_dailyBrief?.isNotEmpty ?? false)) {
      return _dailyBrief;
    }
    try {
      final text = await GeminiTextService.generate(
          _dailyBriefSystemPrompt(), _dailyBriefUserPrompt());
      _dailyBrief = text.trim();
      await prefs.setString('ai_brief_date', today);
      await prefs.setString('ai_brief_text', _dailyBrief!);
      notifyListeners();
    } catch (_) {
      // Offline / quota / key issue — keep any previously cached brief.
    }
    return _dailyBrief;
  }

  /// Forces a fresh daily brief now, ignoring the once-a-day cache — backs the
  /// manual "refresh" tap on the Home brief card. No-op when cloud AI isn't
  /// configured or the coach is off.
  Future<void> forceRefreshDailyBrief() async {
    if (!GeminiTextService.isConfigured || !_aiCoachEnabled) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ai_brief_date'); // invalidate today's cache
    await refreshDailyBriefIfDue();
  }

  String _dailyBriefSystemPrompt() =>
      "You are $_userName's concise personal fitness coach (Indian context). "
      'Write a short, friendly daily brief of 2-3 sentences (max ~45 words). '
      'Focus on the ONE thing that matters most today — protein, calories, steps, '
      'or water — and give a specific, encouraging nudge. Plain text only: no '
      'markdown, no bullet lists.';

  String _dailyBriefUserPrompt() =>
      'Today so far — calories ${todayCalories.round()}/$calorieGoal kcal, '
      'protein ${todayProtein.round()}/$proteinGoal g, '
      'water $todayWaterMl/$waterGoalMl ml, steps $todaySteps/$stepGoal. '
      'Yesterday — calories ${yesterdayCal.round()} kcal, '
      'protein ${yesterdayProtein.round()} g. '
      'Calorie-deficit streak: $deficitStreak day(s). '
      'Latest weight ${latestWeightKg?.toStringAsFixed(1) ?? "?"}kg, '
      'goal weight ${goalWeightKg.toStringAsFixed(0)}kg. '
      'Acknowledge yesterday or the streak if notable, then give me today\'s '
      'one nudge.';

  Future<void> saveAutoUpdateCheck(bool value) async {
    _autoUpdateCheck = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_update_check', value);
    notifyListeners();
  }

  /// Called when the user taps "Later" — suppresses update prompts for 3 days.
  Future<void> snoozeUpdate() async {
    _updateSnoozedUntilMs =
        DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('update_snoozed_until_ms', _updateSnoozedUntilMs);
  }

  /// Called when the user taps "Update" — suppresses re-prompts for 2 hours so
  /// the app doesn't immediately ask for another update right after an install.
  Future<void> markUpdateInitiated() async {
    _updateInitiatedAtMs = DateTime.now().millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('update_initiated_at_ms', _updateInitiatedAtMs);
  }

  /// One-shot flag set when a NEW milestone (streak / goal reached) is detected,
  /// so the UI can fire a celebratory confetti burst exactly once. The UI calls
  /// [consumeCelebration] after playing it.
  bool _celebratePending = false;
  bool get hasPendingCelebration => _celebratePending;
  void consumeCelebration() => _celebratePending = false;

  Future<void> saveUserName(String name) async {
    _userName = name.trim().isEmpty ? 'Friend' : name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', _userName);
    notifyListeners();
  }

  // ── State ──────────────────────────────────────────────────────────────────
  List<FoodEntry> _todayFood = [];
  int _todayWaterMl = 0;
  SupplementStatus _supplements = SupplementStatus();
  List<WorkoutLog> _workoutHistory = [];
  Map<String, double>? _oneRmCache; // invalidated on logWorkout / loadData
  List<BodyEntry> _bodyHistory = [];
  List<SmartScaleEntry> _scaleHistory = [];
  List<MeasurementEntry> _measurementHistory = [];
  bool _isLoaded = false;

  // ── Historical data (last 30 days, loaded at startup) ──────────────────────
  Map<String, List<FoodEntry>> _foodHistory = {};
  Map<String, int> _waterHistory = {};
  Map<String, SupplementStatus> _supplementHistory = {};

  // ── Pedometer ──────────────────────────────────────────────────────────────
  StreamSubscription<StepCount>? _stepSubscription;
  int _livePedometerTotal = 0;   // cumulative total from sensor
  int _pedometerDayBaseline = -1; // sensor total at start of today
  String _pedometerBaselineDate = '';
  // Cached prefs instance so the hot-path listener avoids re-fetching it.
  SharedPreferences? _cachedPrefs;
  // Throttle: avoid rebuilding all screens on every single step event.
  DateTime? _lastPedometerNotify;
  // Throttle: push live steps to the home widget at most this often (a widget
  // redraw is heavier than a notifyListeners, so it's throttled separately).
  DateTime? _lastWidgetStepPush;

  // ── Day-reset detection ────────────────────────────────────────────────────
  String _loadedForDate = '';
  Timer? _dayResetTimer;

  // ── Getters ────────────────────────────────────────────────────────────────

  /// True when the calendar date has advanced since the last full loadData().
  /// Used by the lifecycle observer to skip redundant same-day reloads.
  bool get dateChanged =>
      _loadedForDate.isNotEmpty && _loadedForDate != _todayKey;

  List<FoodEntry> get todayFood => _todayFood;
  int get todayWaterMl => _todayWaterMl;
  SupplementStatus get supplements => _supplements;
  List<WorkoutLog> get workoutHistory => _workoutHistory;

  /// Estimated 1-rep maxes for the 5 major lifts.
  /// Cached — invalidated when workout history changes.
  static const _bigLifts = ['Deadlift', 'Squats', 'Bench Press', 'Overhead Press', 'Barbell Rows'];

  Map<String, double> get topLiftsOneRm => _oneRmCache ??= _computeOneRm();

  Map<String, double> _computeOneRm() {
    final result = <String, double>{};
    for (final lift in _bigLifts) {
      double best = 0;
      for (final w in _workoutHistory) {
        for (final ex in w.exercises) {
          if (ex.name == lift) {
            for (final s in ex.sets) {
              final est = s.reps == 1 ? s.weight : s.weight * (1 + s.reps / 30.0);
              if (est > best) best = est;
            }
          }
        }
      }
      if (best > 0) result[lift] = best;
    }
    return result;
  }
  List<BodyEntry> get bodyHistory => _bodyHistory;
  List<SmartScaleEntry> get scaleHistory => _scaleHistory;
  SmartScaleEntry? get latestScaleEntry =>
      _scaleHistory.isEmpty ? null : _scaleHistory.last;
  List<MeasurementEntry> get measurementHistory => _measurementHistory;
  MeasurementEntry? get latestMeasurements =>
      _measurementHistory.isEmpty ? null : _measurementHistory.last;
  bool get isLoaded => _isLoaded;

  // Memoized merged maps (C2). These getters used to allocate a fresh map on
  // every call — hot on the AI-context / history / insight paths. The merge is
  // rebuilt only when [_dataVersion] moves (any mutation) or the day rolls over.
  // Callers treat the result read-only (verified across the codebase).
  Map<String, List<FoodEntry>>? _foodHistoryCache;
  int _foodHistoryCacheVersion = -1;
  String _foodHistoryCacheDay = '';

  /// All food entries keyed by 'YYYY-MM-DD', including today's.
  Map<String, List<FoodEntry>> get foodHistory {
    final day = _todayKey;
    if (_foodHistoryCache != null &&
        _foodHistoryCacheVersion == _dataVersion &&
        _foodHistoryCacheDay == day) {
      return _foodHistoryCache!;
    }
    final merged = {..._foodHistory, day: _todayFood};
    _foodHistoryCache = merged;
    _foodHistoryCacheVersion = _dataVersion;
    _foodHistoryCacheDay = day;
    return merged;
  }

  Map<String, int>? _waterHistoryCache;
  int _waterHistoryCacheVersion = -1;
  String _waterHistoryCacheDay = '';

  /// Water intake (mL) keyed by 'YYYY-MM-DD', including today's.
  Map<String, int> get waterHistory {
    final day = _todayKey;
    if (_waterHistoryCache != null &&
        _waterHistoryCacheVersion == _dataVersion &&
        _waterHistoryCacheDay == day) {
      return _waterHistoryCache!;
    }
    final merged = {..._waterHistory, day: _todayWaterMl};
    _waterHistoryCache = merged;
    _waterHistoryCacheVersion = _dataVersion;
    _waterHistoryCacheDay = day;
    return merged;
  }

  /// Supplement status keyed by 'YYYY-MM-DD', including today's.
  Map<String, SupplementStatus> get supplementHistory =>
      {..._supplementHistory, _todayKey: _supplements};

  /// TDEE rounded to nearest kcal.
  int get tdeeKcal => (tdee ?? 0).round();

  double get todayCalories =>
      _todayFood.fold(0.0, (sum, e) => sum + e.calories);
  double get todayProtein =>
      _todayFood.fold(0.0, (sum, e) => sum + e.protein);

  /// True when a whey/protein shake appears in [foods] — one day's food log.
  /// Shared by today's [_hasLoggedWheyFood] and the historical helpers below so
  /// the predicate lives in one place and the whey supplement toggle is never
  /// double-counted on top of a logged shake.
  bool _foodListHasWhey(List<FoodEntry>? foods) =>
      foods?.any((e) {
        final n = e.name.toLowerCase();
        return n.contains('whey') ||
            (n.contains('protein') && n.contains('shake'));
      }) ??
      false;

  /// True when a whey/protein shake has already been logged as a food entry
  /// today. Used to avoid double-counting the whey supplement toggle on top of
  /// a logged shake (both would otherwise add ~120 kcal / 25 g for one scoop).
  bool get _hasLoggedWheyFood => _foodListHasWhey(_todayFood);

  /// Whey supplement calories to count for a PAST day, suppressed when a shake
  /// is already in that day's food log (mirrors [supplementCalories] for
  /// history so today and history agree).
  double _wheySuppCalFor(List<FoodEntry>? foods, SupplementStatus? supp) =>
      ((supp?.whey ?? false) && !_foodListHasWhey(foods)) ? 120.0 : 0.0;

  /// Whey supplement protein to count for a PAST day, suppressed when a shake
  /// is already logged as food (mirrors [supplementProtein] for history).
  double _wheySuppProtFor(List<FoodEntry>? foods, SupplementStatus? supp) =>
      ((supp?.whey ?? false) && !_foodListHasWhey(foods)) ? 25.0 : 0.0;

  /// Calories from the checked whey supplement (120 kcal per scoop).
  /// Returns 0 when a whey shake is already in today's food log, so the scoop
  /// isn't counted twice.
  double get supplementCalories =>
      (_supplements.whey && !_hasLoggedWheyFood) ? 120.0 : 0.0;

  /// Protein from the checked whey supplement (25 g per scoop).
  /// Returns 0 when a whey shake is already logged as food (avoids double-count).
  double get supplementProtein =>
      (_supplements.whey && !_hasLoggedWheyFood) ? 25.0 : 0.0;

  /// Carbs (g) from the checked whey supplement — small and real (matches the
  /// "Whey Protein Shake" food item: 3 g carb). Suppressed when a shake is
  /// already logged as food, mirroring [supplementCalories].
  double get supplementCarbs =>
      (_supplements.whey && !_hasLoggedWheyFood) ? 3.0 : 0.0;

  /// Fat (g) from the checked whey supplement (1.5 g). See [supplementCarbs].
  double get supplementFat =>
      (_supplements.whey && !_hasLoggedWheyFood) ? 1.5 : 0.0;

  /// Total calories including supplements
  double get todayCaloriesTotal => todayCalories + supplementCalories;

  /// Total protein including supplements
  double get todayProteinTotal => todayProtein + supplementProtein;

  /// Real carbs (grams) summed from today's logged entries' carb data.
  /// 0 when no entry carries carb data (legacy / custom entries).
  double get todayCarbs =>
      _todayFood.fold(0.0, (sum, e) => sum + e.carbs);

  /// Real fat (grams) summed from today's logged entries' fat data.
  double get todayFat =>
      _todayFood.fold(0.0, (sum, e) => sum + e.fat);

  /// Carbs today (grams) for the macro donut — summed per-entry so each item
  /// uses its REAL value when known and the Indian-diet 65/35 split estimate
  /// only when it doesn't, plus the whey supplement's carbs. This is accurate
  /// even when the day mixes entries that carry real macros with ones that don't
  /// (the old whole-day formula under-counted that case). Equals the real sum
  /// when every entry is real, and the 65/35 estimate when none are.
  double get todayCarbsEstimate =>
      _todayFood.fold(0.0, (sum, e) => sum + e.effectiveCarbs) + supplementCarbs;

  /// Fat today (grams) for the macro donut — per-entry effective sum plus the
  /// whey supplement's fat (see [todayCarbsEstimate]).
  double get todayFatEstimate =>
      _todayFood.fold(0.0, (sum, e) => sum + e.effectiveFat) + supplementFat;

  /// True when any of today's logged carb/fat figures are estimated rather than
  /// real — i.e. at least one entry with calories carries no real macros. Lets
  /// the UI show the "estimated" macro footnote only when it's actually accurate
  /// to do so (a day of all-real-macro foods shows no footnote).
  bool get todayMacrosEstimated =>
      _todayFood.any((e) => e.calories > 0 && !e.hasRealMacros);

  /// Last 7 days of calorie data for bar chart.
  /// Returns list of [dayLabel, calories] pairs, oldest→newest.
  List<Map<String, dynamic>> get weeklyCalorieData {
    final result = <Map<String, dynamic>>[];
    final today = DateTime.now();
    for (int i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      double cal;
      if (i == 0) {
        cal = todayCaloriesTotal;
      } else {
        final foods = _foodHistory[key];
        final supp = _supplementHistory[key];
        final foodCal = foods?.fold(0.0, (s, e) => s + e.calories) ?? 0.0;
        final suppCal = _wheySuppCalFor(foods, supp);
        cal = foodCal + suppCal;
      }
      final label = i == 0
          ? 'Today'
          : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
      result.add({'label': label, 'calories': cal, 'date': key});
    }
    return result;
  }

  double get calorieProgress =>
      calorieGoal > 0 ? (todayCaloriesTotal / calorieGoal).clamp(0.0, 1.0) : 0.0;
  double get proteinProgress =>
      proteinGoal > 0 ? (todayProteinTotal / proteinGoal).clamp(0.0, 1.0) : 0.0;
  double get waterProgress =>
      waterGoalMl > 0 ? (_todayWaterMl / waterGoalMl).clamp(0.0, 1.0) : 0.0;

  // ── Net calories & deficit ─────────────────────────────────────────────────
  /// Calories eaten minus ALL calories burned today (resting + walking + workout).
  /// NOTE: this is an *instantaneous* net — resting burn is prorated to the
  /// current time of day, so it grows through the day. For a stable "will I end
  /// the day in a deficit?" verdict use [projectedInDeficit], not the sign of
  /// this value.
  int get netCalories => (todayCaloriesTotal - totalCaloriesBurned).round();

  /// Full-day burn estimate: resting BMR for the WHOLE day (not prorated to now)
  /// + today's walking + today's workout. Used for a time-of-day-stable energy
  /// balance verdict so the same day doesn't read "surplus" at 9 AM and
  /// "deficit" at 11 PM. Falls back to walking+workout when no BMR (no weight).
  double get projectedDayBurn {
    final b = bmr;
    final base = b ?? 0;
    return base + walkingCaloriesBurned + todayCaloriesBurned;
  }

  /// Whether today is *projected* to end in an energy deficit (intake < burn),
  /// using end-of-day projections so the verdict is stable through the day.
  ///
  /// Returns null when there isn't enough signal yet — no full-day burn estimate
  /// (no weight/BMR) or no reliable intake projection (too early in the day /
  /// nothing logged). The UI should show a neutral "keep logging" state for null
  /// rather than guessing.
  bool? get projectedInDeficit {
    final burn = projectedDayBurn;
    if (burn <= 0) return null;
    final intake = projectedEodCalories;
    if (intake == null || intake <= 0) return null;
    return intake < burn;
  }

  /// True if currently in a calorie deficit (instantaneous, time-of-day sensitive).
  ///
  /// Prefer [projectedInDeficit] for a stable daily verdict. Kept for backward
  /// compatibility and "right now" comparisons.
  ///
  /// Logic:
  ///  • When real burn data exists (BMR + steps + workout > 0): uses true
  ///    energy-balance — eating < burning.
  ///  • When no burn data (no weight logged) AND no food: returns false —
  ///    there is no signal to evaluate.
  ///  • When no burn data but food was logged: compares against the calorie
  ///    goal as a proxy for real deficit.
  bool get inDeficit {
    final burned = totalCaloriesBurned;
    if (burned > 0) return todayCaloriesTotal < burned;
    if (todayCaloriesTotal <= 0 && burned <= 0) return false;
    return todayCaloriesTotal < calorieGoal;
  }

  /// Remaining calories left to eat (vs goal). Can be negative if over.
  int get caloriesRemaining => calorieGoal - todayCaloriesTotal.round();

  // ── Body / weight ──────────────────────────────────────────────────────────
  BodyEntry? get latestBodyEntry =>
      _bodyHistory.isEmpty ? null : _bodyHistory.last;

  double? get latestWeightKg =>
      latestScaleEntry?.weightKg ?? latestBodyEntry?.weightKg;

  double? get bmi {
    final w = latestWeightKg;
    if (w == null || _heightCm <= 0) return null;
    final hm = _heightCm / 100.0;
    return w / (hm * hm);
  }

  String get bmiCategory {
    final b = bmi;
    if (b == null) return '—';
    if (b < 18.5) return 'Underweight';
    if (b < 25.0) return 'Normal';
    if (b < 30.0) return 'Overweight';
    return 'Obese';
  }

  Color bmiColor(BuildContext context) {
    final b = bmi;
    if (b == null) return const Color(0xFF8E8E93);
    if (b < 18.5) return const Color(0xFF40C8E0);
    if (b < 25.0) return const Color(0xFF30D158);
    if (b < 30.0) return const Color(0xFFFF9F0A);
    return const Color(0xFFFF453A);
  }

  /// BMR — prefer scale BMR if available (scale's measurement is more accurate)
  double? get bmr {
    final scaleBmr = latestScaleEntry?.bmr;
    if (scaleBmr != null && scaleBmr > 0) return scaleBmr;
    final w = latestWeightKg;
    if (w == null || w <= 0) return null;
    // Mifflin-St Jeor: male +5, female −161
    return 10 * w + 6.25 * _heightCm - 5 * _age + (_isMale ? 5.0 : -161.0);
  }

  /// TDEE = BMR × activity multiplier (standard Harris-Benedict activity factors)
  double? get tdee {
    final b = bmr;
    if (b == null) return null;
    final days = weeklyWorkoutDays;
    final multiplier = days >= 6 ? 1.725   // very active
        : days >= 4 ? 1.55                 // moderately active
        : days >= 2 ? 1.375                // lightly active
        : 1.2;                             // sedentary
    return b * multiplier;
  }

  // ── Adaptive (data-calibrated) TDEE ────────────────────────────────────────
  //
  // The BMR×activity-factor `tdee` above is only an ESTIMATE — it overstates or
  // understates real maintenance because activity level is guessed from logged
  // workout days. When we have enough real data we can do far better: back-
  // calculate the user's TRUE maintenance from how their weight actually moved
  // against what they actually ate. This is the same energy-balance method
  // MacroFactor/RP use:  TDEE = avgIntake − (weeklyWeightChangeKg × 7700 ÷ 7).
  //
  // 7700 kcal ≈ energy in 1 kg of body mass. Losing 0.5 kg/wk while eating 1500
  // ⇒ TDEE = 1500 − (−0.5 × 1100) = 2050. Gaining works the same in reverse.

  /// Real maintenance calories calibrated from the user's own weight trend and
  /// logged intake. Null until there's a trustworthy signal: a weight trend
  /// spanning ≥7 days (≥5 logs) AND logged calories over that window.
  /// 7 days is the practical minimum for an energy-balance TDEE estimate; the
  /// linear-regression slope smooths day-to-day water-weight noise, and the
  /// estimate sharpens automatically as more history accrues.
  /// Clamped to a believable human range [1200, 4500] to reject bad data.
  double? get adaptiveTdee {
    // Slope, span, and intake must all cover the SAME window for the
    // energy-balance identity to hold. Food history only loads 60 days, so the
    // weight trend is regressed over those same 60 days — NOT the 90-day
    // regression used for the chart/forecast, which would compare a longer
    // weight trend against a shorter intake average and skew the estimate.
    final entries = getRecentBodyEntries(days: 60);
    if (entries.length < 5) return null;
    final reg = _regressionOver(entries);
    if (reg == null) return null;
    final weekly = reg.slope * 7; // kg/week, negative = losing
    final spanDays = entries.last.date.difference(entries.first.date).inDays;
    if (spanDays < 7) return null;
    // Average daily intake over the SAME span the weight-trend regression
    // covered, so the energy-balance identity compares coincident periods.
    // Start at 1 (yesterday) — today is a partial day and would bias the
    // average intake low. (skips empty days within that window)
    final avgIntake = avgCaloriesForDays(1, spanDays);
    if (avgIntake <= 0) return null;
    final energyFromWeight = weekly * 7700 / 7; // kcal/day stored(+)/released(−)
    final t = avgIntake - energyFromWeight;
    return t.clamp(1200.0, 4500.0);
  }

  /// Dynamic component maintenance: resting BMR + your typical daily walking
  /// (average logged steps) + typical daily workout burn (7-day average). Floored
  /// at the sedentary BMR×1.2 so a quiet day never understates it. This is the
  /// single energy model the app surfaces — it moves with what you actually do,
  /// instead of a fixed activity multiplier, so there is no competing "maintenance"
  /// number anywhere in the UI.
  double? get componentTdee {
    final b = bmr;
    if (b == null) return null;
    final w           = latestWeightKg ?? 70.0;
    final walkBurn    = _avgDailySteps() * 0.04 * (w / 70.0);
    final workoutBurn = weeklyCaloriesBurned / 7.0;
    final active      = b + walkBurn + workoutBurn;
    final floor       = b * 1.2; // sedentary baseline (resting + minimal NEAT/TEF)
    return (active > floor ? active : floor).clamp(1000.0, 6000.0);
  }

  /// Average daily steps from logged history (days that actually have step data),
  /// falling back to today's live count. Feeds the walking term of [componentTdee].
  double _avgDailySteps() {
    final withSteps =
        getRecentBodyEntries(days: 7).where((e) => e.steps > 0).toList();
    if (withSteps.isEmpty) return todaySteps.toDouble();
    final sum = withSteps.fold<int>(0, (s, e) => s + e.steps);
    return sum / withSteps.length;
  }

  /// The TDEE we trust most: data-calibrated [adaptiveTdee] when available,
  /// otherwise the dynamic [componentTdee] estimate. Use THIS for any calorie
  /// goal math so the user gets accurate, personalised, activity-aware targets.
  double? get bestTdee => adaptiveTdee ?? componentTdee;

  /// True when [bestTdee] is the data-calibrated value (for "calibrated" UI badges).
  bool get isTdeeCalibrated => adaptiveTdee != null;

  /// Direction-aware daily calorie target from [bestTdee]:
  ///  • lose     → maintenance − 500   (clamp 1200–2800)
  ///  • maintain → maintenance          (clamp 1200–3500)
  ///  • gain     → maintenance + 350    (lean surplus; clamp 1400–4000)
  /// This is the single source of truth — [recommendedCalorieGoal] and the
  /// [fatLossCalorieTarget] alias both delegate here, so nothing else assumes a
  /// hardcoded −500. Null until weight/height/age give a TDEE estimate.
  double? get _directionCalorieTarget {
    final t = bestTdee;
    if (t == null) return null;
    switch (_goalDirection) {
      case GoalDirection.lose:
        return (t - 500).clamp(1200.0, 2800.0);
      case GoalDirection.maintain:
        return t.clamp(1200.0, 3500.0);
      case GoalDirection.gain:
        return (t + 350).clamp(1400.0, 4000.0);
    }
  }

  /// Suggested daily calorie target. Named for its original fat-loss use; now a
  /// direction-aware alias of [recommendedCalorieGoal] (kept so existing call
  /// sites keep compiling). Uses [bestTdee] so it reflects real maintenance once
  /// data is available.
  double? get fatLossCalorieTarget => _directionCalorieTarget;

  // ── Smart goal recommendations ─────────────────────────────────────────────
  //
  // Auto-calculated from body data so the user has science-backed targets
  // instead of fixed defaults. Shown in Settings as suggestions the user can
  // apply with one tap.

  /// Recommended daily calorie intake for the user's [goalDirection] — a deficit
  /// for lose, maintenance for maintain, a lean surplus for gain (see
  /// [_directionCalorieTarget] for the exact bands). Prefers the data-calibrated
  /// [adaptiveTdee] so it won't over-recommend when the activity-factor estimate
  /// is too high. Returns null when weight/height/age haven't been logged yet.
  double? get recommendedCalorieGoal => _directionCalorieTarget;

  /// Recommended daily protein for fat loss + muscle retention.
  /// Uses 2.0 g/kg lean body mass when scale data is available,
  /// otherwise 1.8 g/kg total body weight.
  /// Science: at least 1.6 g/kg lean mass protects muscle in a deficit.
  int get recommendedProteinGoal {
    final lean = leanMassKg;
    if (lean != null && lean > 10) {
      return (lean * 2.0).round().clamp(60, 300);
    }
    final w = latestWeightKg;
    if (w != null) {
      return (w * 1.8).round().clamp(60, 300);
    }
    return kDefaultProteinGoal;
  }

  /// Recommended daily fat for fat loss — ~25% of the recommended calorie target
  /// (÷9 kcal/g), a hormonal-health floor that isn't excessive. Null when there's
  /// no TDEE estimate yet (same gate as [recommendedCalorieGoal]).
  int? get recommendedFatGoal {
    final cals = recommendedCalorieGoal;
    if (cals == null) return null;
    return (cals * 0.25 / 9.0).round().clamp(30, 130);
  }

  /// Recommended daily carbs — the energy left after protein + fat (÷4 kcal/g):
  /// "protein first, fat next, carbs fill the rest." Null when no TDEE yet.
  int? get recommendedCarbGoal {
    final cals = recommendedCalorieGoal;
    if (cals == null) return null;
    final remaining =
        cals - recommendedProteinGoal * 4 - (recommendedFatGoal ?? 0) * 9;
    return (remaining / 4.0).round().clamp(50, 500);
  }

  /// Recommended daily water intake: 35 ml per kg body weight.
  /// 35 ml/kg is widely recommended for active adults aiming for fat loss.
  int get recommendedWaterGoal {
    final w = latestWeightKg;
    if (w == null) return kDefaultWaterGoalMl;
    return ((w * 35).round()).clamp(1500, 4500);
  }

  /// True when the user's manually-set goals differ meaningfully from
  /// what the body data recommends (triggers a nudge in Settings).
  bool get hasGoalRecommendations {
    final rCal  = recommendedCalorieGoal;
    final rProt = recommendedProteinGoal;
    final rWat  = recommendedWaterGoal;
    if (rCal == null) return false;
    final calDiff  = (rCal.round() - _calorieGoal).abs() > 50;
    final protDiff = (rProt        - _proteinGoal).abs() > 5;
    final watDiff  = (rWat         - _waterGoalMl).abs() > 150;
    final rCarb = recommendedCarbGoal;
    final rFat  = recommendedFatGoal;
    final carbDiff = rCarb != null && (rCarb - _carbGoal).abs() > 15;
    final fatDiff  = rFat  != null && (rFat  - _fatGoal).abs() > 8;
    return calDiff || protDiff || watDiff || carbDiff || fatDiff;
  }

  /// kg remaining to reach goal weight (negative = already below goal)
  double? get kgToGoal {
    final w = latestWeightKg;
    if (w == null) return null;
    return w - _goalWeightKg;
  }

  /// Estimated weeks to reach goal, based on your ACTUAL measured rate of change.
  ///
  /// Direction-aware: a **lose** goal counts down the kg still to shed, a **gain**
  /// goal counts up the kg still to put on, and **maintain** has no destination
  /// (returns null). Each prefers the 7-day regression trend (`weeklyWeightChange`)
  /// — this avoids the old bug where today's instantaneous deficit (huge early in
  /// the day) produced absurd ETAs — and returns null when the measured trend
  /// moves the WRONG way (losing while bulking, or gaining while cutting), since
  /// projecting an ETA the data contradicts would be dishonest. Falls back to a
  /// sustainable rate from the recommended deficit/surplus only when there isn't
  /// enough weight history yet.
  double? get weeksToGoal {
    final kg = kgToGoal; // +ve = above goal (must lose), −ve = below goal (must gain)
    if (kg == null) return null;

    switch (_goalDirection) {
      case GoalDirection.maintain:
        return null; // no destination to count down to

      case GoalDirection.lose:
        if (kg <= 0) return null; // already at/under goal
        final trend = weeklyWeightChange; // kg/week, negative = losing
        if (trend != null && trend < -0.05) {
          return (kg / trend.abs()).clamp(1, 999);
        }
        if (trend != null && trend > 0.05) return null; // gaining while cutting
        // Sustainable projection from the recommended deficit.
        final target = recommendedCalorieGoal;
        final t = bestTdee;
        if (target != null && t != null && t > target) {
          final dailyDeficit = (t - target).clamp(0, 1000);
          final kgPerWeek = dailyDeficit * 7 / 7700;
          if (kgPerWeek <= 0) return null;
          return (kg / kgPerWeek).clamp(1, 999);
        }
        return null;

      case GoalDirection.gain:
        final toGain = -kg; // +ve = how much still to put on
        if (toGain <= 0) return null; // already at/over goal
        final trend = weeklyWeightChange; // kg/week, positive = gaining
        if (trend != null && trend > 0.05) {
          return (toGain / trend).clamp(1, 999);
        }
        if (trend != null && trend < -0.05) return null; // losing while bulking
        // Sustainable projection from the recommended surplus.
        final target = recommendedCalorieGoal; // maintenance + 350
        final t = bestTdee;
        if (target != null && t != null && target > t) {
          final dailySurplus = (target - t).clamp(0, 1000);
          final kgPerWeek = dailySurplus * 7 / 7700;
          if (kgPerWeek <= 0) return null;
          return (toGain / kgPerWeek).clamp(1, 999);
        }
        return null;
    }
  }

  // ── Body-composition analytics (uses ALL scale + measurement data) ──────────
  static const _bcGreen = Color(0xFF30D158);
  static const _bcOrange = Color(0xFFFF9F0A);
  static const _bcRed = Color(0xFFFF453A);
  static const _bcBlue = Color(0xFF40C8E0);
  static const _bcMuted = Color(0xFF8E8E93);

  /// Earliest logged weight across body + scale history — the baseline for goal progress.
  double? get startWeightKg {
    DateTime? earliest;
    double? weight;
    void consider(DateTime d, double w) {
      if (w <= 0) return;
      if (earliest == null || d.isBefore(earliest!)) {
        earliest = d;
        weight = w;
      }
    }
    // Scan ALL entries for the earliest with a real (>0) weight — not just the
    // first, which can be a zero-weight or backdated entry.
    for (final e in _bodyHistory) consider(e.date, e.weightKg);
    for (final e in _scaleHistory) consider(e.date, e.weightKg);
    return weight;
  }

  /// Fraction (0–1) of the start→goal journey completed. Handles loss and gain goals.
  double get goalProgress {
    final start = startWeightKg;
    final current = latestWeightKg;
    if (start == null || current == null) return 0;
    final span = start - _goalWeightKg;
    if (span.abs() < 0.05) return 1; // already at goal / no meaningful span
    return ((start - current) / span).clamp(0.0, 1.0);
  }

  /// Waist-to-hip ratio (fat-distribution / health-risk indicator).
  double? get waistToHipRatio {
    final m = latestMeasurements;
    final waist = m?.waistCm;
    final hips = m?.hipsCm;
    if (waist == null || hips == null || hips <= 0) return null;
    return waist / hips;
  }

  ({String label, Color color})? get whrRisk {
    final r = waistToHipRatio;
    if (r == null) return null;
    if (r < 0.90) return (label: 'Low risk', color: _bcGreen);
    if (r < 1.00) return (label: 'Moderate risk', color: _bcOrange);
    return (label: 'High risk', color: _bcRed);
  }

  /// Waist-to-height ratio — a stronger central-obesity signal than BMI.
  double? get waistToHeightRatio {
    final waist = latestMeasurements?.waistCm;
    if (waist == null || _heightCm <= 0) return null;
    return waist / _heightCm;
  }

  ({String label, Color color}) get whtrStatus {
    final r = waistToHeightRatio;
    if (r == null) return (label: '—', color: _bcMuted);
    if (r < 0.5) return (label: 'Healthy', color: _bcGreen);
    if (r < 0.6) return (label: 'Raised', color: _bcOrange);
    return (label: 'High', color: _bcRed);
  }

  /// Normalized Fat-Free Mass Index — your actual muscle-development score.
  double? get ffmi {
    final lean = latestScaleEntry?.leanBodyMassKg;
    if (lean == null || lean <= 0 || _heightCm <= 0) return null;
    final h = _heightCm / 100.0;
    return lean / (h * h) + 6.1 * (1.8 - h);
  }

  ({String label, Color color}) get ffmiStatus {
    final f = ffmi;
    if (f == null) return (label: '—', color: _bcMuted);
    // FFMI norms are sex-specific — women run ~3 points lower than men, so a
    // fixed male scale wrongly grades every woman "below average".
    final belowAvg  = _isMale ? 18.0 : 15.0;
    final average   = _isMale ? 20.0 : 17.0;
    final athletic  = _isMale ? 22.0 : 19.0;
    final excellent = _isMale ? 25.0 : 22.0;
    if (f < belowAvg)  return (label: 'Below average', color: _bcOrange);
    if (f < average)   return (label: 'Average', color: _bcBlue);
    if (f < athletic)  return (label: 'Athletic', color: _bcGreen);
    if (f < excellent) return (label: 'Excellent', color: _bcGreen);
    return (label: 'Very high', color: _bcBlue);
  }

  double? get fatMassKg {
    final v = latestScaleEntry?.bodyFatKg;
    return (v != null && v > 0) ? v : null;
  }

  double? get leanMassKg {
    final v = latestScaleEntry?.leanBodyMassKg;
    return (v != null && v > 0) ? v : null;
  }

  /// Fat / lean change from the earliest to latest scale reading — the real recomp story.
  ({double fatChange, double leanChange, String verdict, Color color})? get bodyCompTrajectory {
    if (_scaleHistory.length < 2) return null;
    final first = _scaleHistory.first;
    final last = _scaleHistory.last;
    if (first.bodyFatKg <= 0 || last.bodyFatKg <= 0) return null;
    final fatChange = last.bodyFatKg - first.bodyFatKg;
    final leanChange = last.leanBodyMassKg - first.leanBodyMassKg;
    String verdict;
    Color color;
    if (fatChange < -0.3 && leanChange > 0.3) {
      verdict = 'Recomp — fat down, muscle up';
      color = _bcGreen;
    } else if (fatChange < -0.3 && leanChange >= -0.3) {
      verdict = 'Losing fat, holding muscle';
      color = _bcGreen;
    } else if (fatChange < -0.3 && leanChange < -0.3) {
      verdict = 'Losing fat and some muscle';
      color = _bcOrange;
    } else if (fatChange > 0.3 && leanChange > 0.3) {
      verdict = 'Gaining both fat and muscle';
      color = _bcOrange;
    } else if (fatChange > 0.3) {
      verdict = 'Fat trending up';
      color = _bcRed;
    } else {
      verdict = 'Holding steady';
      color = _bcMuted;
    }
    return (fatChange: fatChange, leanChange: leanChange, verdict: verdict, color: color);
  }

  /// Smart-scale biological age minus real age (negative = younger than your years).
  int? get bioAgeDelta {
    final b = latestScaleEntry?.biologicalAge;
    if (b == null || b <= 0) return null;
    return b - _age;
  }

  ({String label, Color color})? get hydrationStatus {
    final w = latestScaleEntry?.bodyWaterPercent;
    if (w == null || w <= 0) return null;
    if (w < 50) return (label: 'Low', color: _bcOrange);
    if (w <= 65) return (label: 'Healthy', color: _bcGreen);
    return (label: 'High', color: _bcBlue);
  }

  /// Headline body-composition classification from BMI + body-fat% + FFMI.
  ({String label, Color color, String detail}) get bodyCompositionStatus {
    final bf = latestScaleEntry?.bodyFatPercent;
    final f = ffmi;
    final b = bmi;
    if (bf == null && b == null) {
      return (label: 'Log data', color: _bcMuted, detail: 'Log weight (and scale) to assess.');
    }
    if (bf != null && bf > 0) {
      // Healthy body-fat ranges are sex-specific: women carry ~10 percentage
      // points more essential fat, so a male scale wrongly labels a lean woman
      // "Overfat". FFMI gates are likewise shifted ~3 points lower for women.
      final overfatBf  = _isMale ? 25.0 : 32.0;
      final athleticBf = _isMale ? 15.0 : 22.0;
      final leanBf     = _isMale ? 20.0 : 27.0;
      final ffmiAthletic = _isMale ? 20.0 : 17.0;
      final ffmiLean     = _isMale ? 19.0 : 16.0;
      final ffmiLow      = _isMale ? 18.0 : 15.0;
      if (bf >= overfatBf) {
        return (label: 'Overfat', color: _bcRed,
            detail: 'Body fat ${bf.toStringAsFixed(0)}% is high — prioritise the deficit + protein.');
      }
      if (bf < athleticBf && (f == null || f >= ffmiAthletic)) {
        return (label: 'Athletic', color: _bcGreen,
            detail: 'Lean and muscular — maintain protein and training.');
      }
      if (bf < leanBf && (f == null || f >= ffmiLean)) {
        return (label: 'Lean', color: _bcGreen,
            detail: 'Good composition — keep protein high to hold muscle.');
      }
      if (f != null && f < ffmiLow) {
        return (label: 'Recomp needed', color: _bcOrange,
            detail: 'Lowish muscle (FFMI ${f.toStringAsFixed(1)}) — lift heavy while holding the deficit.');
      }
      return (label: 'Average', color: _bcBlue,
          detail: 'Solid base — small deficit + strength work moves you toward lean.');
    }
    // Fall back to BMI category when no body-fat reading.
    return (label: bmiCategory, color: _bcBlue, detail: 'Log smart-scale data for a full composition read.');
  }

  /// True when pedometer is actively delivering data
  bool get hasPedometerData =>
      _pedometerDayBaseline >= 0 && _livePedometerTotal >= _pedometerDayBaseline;

  /// Live steps if pedometer available, otherwise last manually-logged steps.
  int get todaySteps {
    if (hasPedometerData) {
      return math.max(0, _livePedometerTotal - _pedometerDayBaseline);
    }
    return latestBodyEntry?.steps ?? 0;
  }

  double get stepProgress => stepGoal > 0 ? (todaySteps / stepGoal).clamp(0.0, 1.0) : 0.0;

  List<BodyEntry> getRecentBodyEntries({int days = 30}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return _bodyHistory
        .where((e) => e.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  List<MeasurementEntry> getRecentMeasurements({int days = 90}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return _measurementHistory
        .where((e) => e.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  double? get weightChangeKg {
    final recent = getRecentBodyEntries(days: 30);
    if (recent.length < 2) return null;
    return recent.last.weightKg - recent.first.weightKg;
  }

  // ── Food grouped ──────────────────────────────────────────────────────────
  List<FoodEntry> get breakfastEntries =>
      _todayFood.where((e) => e.mealType == MealType.breakfast).toList();
  List<FoodEntry> get lunchEntries =>
      _todayFood.where((e) => e.mealType == MealType.lunch).toList();
  List<FoodEntry> get dinnerEntries =>
      _todayFood.where((e) => e.mealType == MealType.dinner).toList();
  List<FoodEntry> get snackEntries =>
      _todayFood.where((e) => e.mealType == MealType.snack).toList();

  // ── Workout ────────────────────────────────────────────────────────────────
  /// All WorkoutLog entries saved today (may be multiple if user saved in batches).
  List<WorkoutLog> get todayWorkouts {
    final now = DateTime.now();
    return _workoutHistory.where((w) =>
        w.date.year == now.year &&
        w.date.month == now.month &&
        w.date.day == now.day).toList();
  }

  /// Last workout logged today — kept for backward compatibility with home screen.
  WorkoutLog? get todayWorkout {
    final list = todayWorkouts;
    return list.isEmpty ? null : list.last;
  }

  List<WorkoutLog> getRecentWorkouts({int days = 14}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return _workoutHistory
        .where((w) => w.date.isAfter(cutoff))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  // ── Progressive overload ───────────────────────────────────────────────────
  /// A short next-target suggestion from a lift's last logged set, e.g.
  /// "try 42.5kg" or "try 9 reps". Returns null when there's no prior set.
  /// Rule: a loaded lift with ≥8 reps → +2.5 kg; fewer reps → +1 rep at the same
  /// load; a bodyweight move (weight 0/none) → +1 rep. Pure & static so it's
  /// trivially unit-testable and stays consistent with the values the set-entry
  /// dialog already shows.
  static String? overloadSuggestion(double? lastWeight, int? lastReps) {
    if (lastReps == null && lastWeight == null) return null;
    final reps = lastReps ?? 0;
    final w = lastWeight ?? 0;
    if (w <= 0) {
      if (reps <= 0) return null;
      return 'try ${reps + 1} reps';
    }
    if (reps >= 8) {
      final next = w + 2.5;
      final nStr = next == next.roundToDouble()
          ? next.toInt().toString()
          : next.toStringAsFixed(1);
      return 'try ${nStr}kg';
    }
    return 'try ${reps + 1} reps';
  }

  int get workoutStreak {
    // Build a Set of date strings first (O(n)) then check each day (O(1)) — was O(n²)
    final doneKeys = <String>{};
    for (final w in _workoutHistory) {
      doneKeys.add('${w.date.year}-${w.date.month.toString().padLeft(2,'0')}-${w.date.day.toString().padLeft(2,'0')}');
    }
    int streak = 0;
    DateTime check = DateTime.now();
    for (int i = 0; i < 60; i++) {
      final key = '${check.year}-${check.month.toString().padLeft(2,'0')}-${check.day.toString().padLeft(2,'0')}';
      if (doneKeys.contains(key)) {
        streak++;
        check = check.subtract(const Duration(days: 1));
      } else if (i == 0) {
        // today has no workout yet — still counting, try yesterday
        check = check.subtract(const Duration(days: 1));
      } else {
        break;
      }
    }
    return streak;
  }

  /// Consecutive days (including today) where ≥500 kcal was logged.
  /// Simple threshold — rewards logging, not perfection.
  int get calorieStreak {
    int streak = 0;
    final today = DateTime.now();

    // Check today first (include supplement calories in threshold)
    final todayCals = _todayFood.fold(0.0, (s, e) => s + e.calories) + supplementCalories;
    if (todayCals >= 500) streak++;

    // Walk backwards through history (include supplement calories for past days too)
    for (int i = 1; i <= 60; i++) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final foods = _foodHistory[key];
      final supp = _supplementHistory[key];
      final dayFoodCals = foods?.fold(0.0, (s, e) => s + e.calories) ?? 0.0;
      final daySuppCals = _wheySuppCalFor(foods, supp);
      final dayCals = dayFoodCals + daySuppCals;
      if (dayCals >= 500) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  /// Consecutive days where all 3 supplements were taken.
  int get supplementStreak {
    int streak = 0;
    final today = DateTime.now();
    // Check today
    final s = supplements;
    if (s.whey && s.creatine && s.multivitamin) streak++;
    // Walk backwards through history
    for (int i = 1; i <= 60; i++) {
      final d = today.subtract(Duration(days: i));
      final key = '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
      final hist = _supplementHistory[key];
      if (hist != null && hist.whey && hist.creatine && hist.multivitamin) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  /// MET values per exercise (metabolic equivalent of task).
  /// Compound/cardio values are research-backed; strength defaults to 5.0.
  static const Map<String, double> _exerciseMet = {
    // Cardio
    'Running': 9.8, 'Cycling': 8.0, 'Jump Rope': 12.3, 'Swimming': 8.0,
    'HIIT': 10.0, 'Burpees': 8.0, 'Walking': 3.5, 'Jumping Jacks': 8.0,
    'Sprinting': 13.5, 'Sprints': 13.5, 'Stair Climbing': 8.0, 'Elliptical': 5.5,
    'Rowing': 7.0, 'Rowing Machine': 7.0, 'Boxing': 9.8, 'Kickboxing': 9.0,
    'Yoga': 3.0, 'Pilates': 3.5, 'Stretching': 2.5,
    'Rock Climbing': 8.0, 'Hiking': 6.0, 'Dancing': 5.0,
    // Compound lifts
    'Deadlift': 6.0, 'Romanian Deadlift': 6.0, 'Sumo Deadlift': 6.0,
    'Squats': 6.5, 'Front Squat': 6.5, 'Goblet Squat': 6.0,
    'Bench Press': 5.5, 'Incline Bench Press': 5.5, 'Decline Bench Press': 5.5,
    'Overhead Press': 5.5, 'Shoulder Press': 5.5, 'Military Press': 5.5,
    'Barbell Rows': 6.0, 'Dumbbell Rows': 5.5, 'Cable Rows': 5.5,
    'Pull-ups': 8.0, 'Chin-ups': 8.0, 'Lat Pulldown': 5.5,
    'Dips': 6.5, 'Push-ups': 5.0,
    'Lunges': 5.5, 'Leg Press': 5.5, 'Leg Curl': 4.5, 'Leg Extension': 4.5,
    'Hip Thrust': 5.5, 'Glute Bridge': 4.5, 'Calf Raises': 4.0,
    // Isolation
    'Bicep Curls': 4.5, 'Hammer Curls': 4.5, 'Preacher Curls': 4.5,
    'Tricep Extensions': 4.5, 'Tricep Pushdown': 4.5, 'Skull Crushers': 4.5,
    'Lateral Raises': 4.0, 'Front Raises': 4.0, 'Face Pulls': 4.0,
    'Chest Flyes': 4.5, 'Cable Flyes': 4.5,
    'Plank': 4.0, 'Abs': 4.0, 'Crunches': 4.0, 'Sit-ups': 4.5,
    'Default': 5.0, // generic strength training
  };

  /// Calculates calories burned for a workout using MET × user weight × duration.
  /// Duration is rep-weighted: heavy low-rep sets are shorter per set than high-rep sets.
  /// Formula: sets × (avgReps × 0.05 + 1.5) minutes per exercise.
  int calculateWorkoutCalories(WorkoutLog w) {
    final weight = latestWeightKg ?? 70.0;
    int total = 0;
    for (final ex in w.exercises) {
      final met  = _exerciseMet[ex.name] ?? _exerciseMet['Default']!;
      final sets = ex.sets.length;
      if (sets == 0) continue;
      double durationMin;
      if (ExerciseDatabase.isCardio(ex.name)) {
        // Cardio is logged by duration: minutes are stored in SetData.reps.
        // Burn = MET × bodyweight × minutes (a sets/reps model is meaningless
        // for running/cycling — this was previously under-counted to near zero).
        durationMin = ex.sets.fold(0, (s, e) => s + e.reps).toDouble();
        if (durationMin <= 0) continue;
      } else {
        // Rep-weighted duration: low-rep heavy sets (5 reps → 1.75 min/set),
        // high-rep light sets (15 reps → 2.25 min/set), bodyweight (20 reps → 2.5 min/set)
        final avgReps   = ex.sets.fold(0, (s, e) => s + e.reps) / sets;
        final minPerSet = (avgReps * 0.05 + 1.5).clamp(1.5, 4.0);
        durationMin     = sets * minPerSet;
      }
      total += (met * weight * durationMin / 60).round();
    }
    return total;
  }

  /// Sum of calories burned across ALL workouts logged today.
  int get todayCaloriesBurned {
    return todayWorkouts.fold(0, (sum, w) => sum + calculateWorkoutCalories(w));
  }

  /// Calories burned from resting (BMR prorated to time of day)
  double get restingCaloriesBurned {
    final b = bmr;
    if (b == null) return 0;
    final now = DateTime.now();
    final minutesElapsed = now.hour * 60 + now.minute;
    return b * (minutesElapsed / 1440.0);
  }

  /// Calories burned from steps (walking).
  /// Returns 0 when no valid weight is logged (weight=0 is treated as "no data",
  /// consistent with the BMR guard — we never estimate calories from an invalid weight).
  double get walkingCaloriesBurned {
    final w = latestWeightKg;
    if (w == null || w <= 0) return 0;
    return todaySteps * 0.04 * (w / 70.0);
  }

  /// Total calories burned today = resting + walking + workout
  double get totalCaloriesBurned =>
      restingCaloriesBurned + walkingCaloriesBurned + todayCaloriesBurned;

  int get weeklyCaloriesBurned {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    return _workoutHistory
        .where((w) => w.date.isAfter(cutoff))
        .fold(0, (sum, w) => sum + calculateWorkoutCalories(w));
  }

  /// Average daily calories (incl. supplements) over the last 7 days
  double get weeklyAvgCalories {
    final data = weeklyCalorieData; // already computed, 7 entries
    if (data.isEmpty) return 0;
    final total = data.fold(0.0, (sum, d) => sum + (d['calories'] as double));
    return total / data.length;
  }

  /// Average daily protein (incl. whey) over the last 7 days
  double get weeklyAvgProtein {
    double total = 0;
    final today = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      if (i == 0) {
        total += todayProteinTotal;
      } else {
        final foods = _foodHistory[key];
        final supp = _supplementHistory[key];
        final foodProt = foods?.fold(0.0, (s, e) => s + e.protein) ?? 0.0;
        final suppProt = _wheySuppProtFor(foods, supp);
        total += foodProt + suppProt;
      }
    }
    return total / 7;
  }

  /// Days in the last 7 where water intake met the daily goal
  int get weeklyWaterGoalHitDays {
    int count = 0;
    final today = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final ml = i == 0 ? _todayWaterMl : (_waterHistory[key] ?? 0);
      if (ml >= _waterGoalMl) count++;
    }
    return count;
  }

  /// Days in the last 7 where protein met the daily goal
  int get weeklyProteinGoalHitDays {
    int count = 0;
    final today = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      double prot;
      if (i == 0) {
        prot = todayProteinTotal;
      } else {
        final foods = _foodHistory[key];
        final supp = _supplementHistory[key];
        final foodProt = foods?.fold(0.0, (s, e) => s + e.protein) ?? 0.0;
        final suppProt = _wheySuppProtFor(foods, supp);
        prot = foodProt + suppProt;
      }
      if (prot >= _proteinGoal) count++;
    }
    return count;
  }

  // ── Historical aggregates (for the smart insight engine) ────────────────────
  /// Returns a 'YYYY-MM-DD' key for [d].
  String _keyFor(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Total calories logged on [d] (incl. whey). Uses live data for today.
  double caloriesForDate(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return todayCaloriesTotal;
    }
    final key = _keyFor(d);
    final foods = _foodHistory[key];
    final supp = _supplementHistory[key];
    final foodCal = foods?.fold(0.0, (s, e) => s + e.calories) ?? 0.0;
    final suppCal = _wheySuppCalFor(foods, supp);
    return foodCal + suppCal;
  }

  /// Total protein logged on [d] (incl. whey). Uses live data for today.
  double proteinForDate(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return todayProteinTotal;
    }
    final key = _keyFor(d);
    final foods = _foodHistory[key];
    final supp = _supplementHistory[key];
    final foodProt = foods?.fold(0.0, (s, e) => s + e.protein) ?? 0.0;
    final suppProt = _wheySuppProtFor(foods, supp);
    return foodProt + suppProt;
  }

  /// Water (mL) logged on [d]. Uses live data for today.
  int waterForDate(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return _todayWaterMl;
    }
    return _waterHistory[_keyFor(d)] ?? 0;
  }

  /// Mean daily calories over days [startAgo..endAgo] inclusive (0 = today).
  /// Only counts days that have any logged data, so a partial history isn't diluted by zeros.
  double avgCaloriesForDays(int startAgo, int endAgo) =>
      _avgForDays(startAgo, endAgo, caloriesForDate);
  double avgProteinForDays(int startAgo, int endAgo) =>
      _avgForDays(startAgo, endAgo, (d) => proteinForDate(d));
  double avgWaterForDays(int startAgo, int endAgo) =>
      _avgForDays(startAgo, endAgo, (d) => waterForDate(d).toDouble());

  double _avgForDays(int startAgo, int endAgo, double Function(DateTime) value) {
    final now = DateTime.now();
    double total = 0;
    int counted = 0;
    for (int i = startAgo; i <= endAgo; i++) {
      final v = value(now.subtract(Duration(days: i)));
      if (v > 0) {
        total += v;
        counted++;
      }
    }
    return counted == 0 ? 0 : total / counted;
  }

  /// Mean protein for a given [weekday] (1=Mon..7=Sun) across loaded history (60d).
  /// Returns null if no data for that weekday.
  double? proteinAvgForWeekday(int weekday) => _avgForWeekday(weekday, proteinForDate);
  double? waterAvgForWeekday(int weekday) =>
      _avgForWeekday(weekday, (d) => waterForDate(d).toDouble());
  double? caloriesAvgForWeekday(int weekday) => _avgForWeekday(weekday, caloriesForDate);

  /// Fraction of the day's eating window (≈6 AM–9 PM) elapsed — used to project
  /// where today is heading from the current pace.
  double get _eatingFraction {
    final now = DateTime.now();
    final mins = now.hour * 60 + now.minute;
    const start = 6 * 60, end = 21 * 60;
    return ((mins - start) / (end - start)).clamp(0.05, 1.0);
  }

  /// Predicted end-of-day calories, blending today's pace with the user's own
  /// historical average for this weekday. Null before ~11 AM or with no intake
  /// (too early/insufficient signal). Adaptive: improves as history grows.
  double? get projectedEodCalories {
    final now = DateTime.now();
    if (now.hour < 11 || todayCaloriesTotal <= 0) return null;
    final pace = todayCaloriesTotal / _eatingFraction;
    final wd = caloriesAvgForWeekday(now.weekday);
    if (wd != null && wd > 0) return 0.5 * pace + 0.5 * wd;
    return pace;
  }

  /// Predicted end-of-day protein, same model as calories.
  double? get projectedEodProtein {
    final now = DateTime.now();
    if (now.hour < 11 || todayProteinTotal <= 0) return null;
    final pace = todayProteinTotal / _eatingFraction;
    final wd = proteinAvgForWeekday(now.weekday);
    if (wd != null && wd > 0) return 0.5 * pace + 0.5 * wd;
    return pace;
  }

  /// True when the user historically eats meaningfully more on weekends than weekdays.
  bool get overeatsOnWeekends {
    final wkndDays = [DateTime.saturday, DateTime.sunday];
    final wkdayDays = [1, 2, 3, 4, 5];
    final wknd = wkndDays.map(caloriesAvgForWeekday).whereType<double>().toList();
    final wkday = wkdayDays.map(caloriesAvgForWeekday).whereType<double>().toList();
    if (wknd.isEmpty || wkday.isEmpty) return false;
    final wkndAvg = wknd.reduce((a, b) => a + b) / wknd.length;
    final wkdayAvg = wkday.reduce((a, b) => a + b) / wkday.length;
    return wkndAvg > wkdayAvg + 250;
  }

  double? _avgForWeekday(int weekday, double Function(DateTime) value) {
    final now = DateTime.now();
    double total = 0;
    int counted = 0;
    // Start at 1: today is a PARTIAL day, and projectedEodCalories blends
    // today's pace with this average — including today's incomplete total
    // would let the projection reference itself and bias it low.
    for (int i = 1; i <= 60; i++) {
      final d = now.subtract(Duration(days: i));
      if (d.weekday != weekday) continue;
      final v = value(d);
      if (v > 0) {
        total += v;
        counted++;
      }
    }
    return counted == 0 ? null : total / counted;
  }

  /// True once the user has logged at least one workout. Guards the "N days
  /// since your last workout" copy so a never-trained user never sees the
  /// nonsensical "999 days since..." message.
  bool get hasEverLoggedWorkout => _workoutHistory.isNotEmpty;

  /// Days since the most recent workout (0 = today). Returns 999 if none ever —
  /// callers MUST gate on [hasEverLoggedWorkout] before rendering this so the
  /// sentinel never reaches the UI.
  int get daysSinceLastWorkout {
    if (_workoutHistory.isEmpty) return 999;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime latest = _workoutHistory.first.date;
    for (final w in _workoutHistory) {
      if (w.date.isAfter(latest)) latest = w.date;
    }
    final latestDay = DateTime(latest.year, latest.month, latest.day);
    return today.difference(latestDay).inDays;
  }

  /// Number of distinct days with a workout in the last 7 days
  int get weeklyWorkoutDays {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final days = _workoutHistory
        .where((w) => w.date.isAfter(cutoff))
        .map((w) =>
            '${w.date.year}-${w.date.month}-${w.date.day}')
        .toSet();
    return days.length;
  }

  /// Get the last logged weight (kg) for a given exercise name.
  double? getLastExerciseWeight(String exerciseName) {
    for (final workout in _workoutHistory.reversed) {
      for (final ex in workout.exercises) {
        if (ex.name == exerciseName) {
          final nonZero = ex.sets.where((s) => s.weight > 0).toList();
          if (nonZero.isNotEmpty) return nonZero.last.weight;
        }
      }
    }
    return null;
  }

  /// Get the last logged reps for a given exercise name.
  int? getLastExerciseReps(String exerciseName) {
    for (final workout in _workoutHistory.reversed) {
      for (final ex in workout.exercises) {
        if (ex.name == exerciseName && ex.sets.isNotEmpty) {
          return ex.sets.last.reps;
        }
      }
    }
    return null;
  }

  /// Max weight ever lifted for an exercise (personal record)
  double? getPersonalRecord(String exerciseName) {
    double? max;
    for (final workout in _workoutHistory) {
      for (final ex in workout.exercises) {
        if (ex.name == exerciseName) {
          for (final s in ex.sets) {
            if (s.weight > 0 && (max == null || s.weight > max)) {
              max = s.weight;
            }
          }
        }
      }
    }
    return max;
  }

  /// Days of the current week (Mon-Sun) with workout done
  List<bool> get weeklyWorkoutMap {
    final now = DateTime.now();
    final weekday = now.weekday;
    final result = List<bool>.filled(7, false);
    for (int i = 0; i < 7; i++) {
      final day = now.subtract(Duration(days: weekday - 1 - i));
      result[i] = _workoutHistory.any((w) =>
          w.date.year == day.year &&
          w.date.month == day.month &&
          w.date.day == day.day);
    }
    return result;
  }

  /// Rolling last 7 days (oldest first, today last) — each entry is the
  /// single-letter weekday label + whether a workout was logged that day.
  /// Matches [weeklyWorkoutDays] so the "LAST 7 DAYS" grid and the "X/7"
  /// stat always agree (the calendar-week [weeklyWorkoutMap] did not).
  List<({String label, bool done})> get rolling7DayWorkouts {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S']; // weekday 1..7
    final now = DateTime.now();
    return List.generate(7, (i) {
      final day = now.subtract(Duration(days: 6 - i));
      final done = _workoutHistory.any((w) =>
          w.date.year == day.year &&
          w.date.month == day.month &&
          w.date.day == day.day);
      return (label: letters[day.weekday - 1], done: done);
    });
  }

  // ── Habit pattern analysis ─────────────────────────────────────────────────

  /// % of past 30 logged days where calories were within ±15% of goal.
  double get calorieAdherenceRate {
    int count = 0, met = 0;
    final now = DateTime.now();
    for (int i = 1; i <= 30; i++) {
      final d = now.subtract(Duration(days: i));
      final cal = caloriesForDate(d);
      if (cal == 0) continue;
      count++;
      if (cal >= calorieGoal * 0.85 && cal <= calorieGoal * 1.15) met++;
    }
    return count > 0 ? met / count : 0.0;
  }

  /// % of past 30 logged days where protein met ≥ 90% of goal.
  double get proteinAdherenceRate {
    int count = 0, met = 0;
    final now = DateTime.now();
    for (int i = 1; i <= 30; i++) {
      final d = now.subtract(Duration(days: i));
      final prot = proteinForDate(d);
      if (prot == 0) continue;
      count++;
      if (prot >= proteinGoal * 0.9) met++;
    }
    return count > 0 ? met / count : 0.0;
  }

  /// % of past 30 logged days where water reached ≥ 90% of goal.
  double get waterAdherenceRate {
    int count = 0, met = 0;
    final now = DateTime.now();
    for (int i = 1; i <= 30; i++) {
      final d = now.subtract(Duration(days: i));
      final water = waterForDate(d);
      if (water == 0) continue;
      count++;
      if (water >= waterGoalMl * 0.9) met++;
    }
    return count > 0 ? met / count : 0.0;
  }

  /// Consecutive days (before today) that ended in a calorie deficit.
  int get deficitStreak {
    int streak = 0;
    final now = DateTime.now();
    for (int i = 1; i <= 30; i++) {
      final d = now.subtract(Duration(days: i));
      final cal = caloriesForDate(d);
      if (cal == 0) continue; // skip unlogged days (logged-days-only convention)
      if (cal < calorieGoal * 0.99) streak++;
      else break;
    }
    return streak;
  }

  /// True when > 25% of logged meals in the past 14 days were after 9 PM.
  bool get hasLateNightEatingPattern {
    int late = 0, total = 0;
    final now = DateTime.now();
    for (int i = 1; i <= 14; i++) {
      final key = _keyFor(now.subtract(Duration(days: i)));
      final entries = _foodHistory[key];
      if (entries == null) continue;
      for (final e in entries) {
        if (e.calories > 50) {
          total++;
          if (e.timestamp.hour >= 21) late++;
        }
      }
    }
    return total >= 6 && late / total > 0.25;
  }

  /// Weighted habit score 0–100 based on adherence + workout + eating patterns.
  int get habitScore {
    if (_foodHistory.isEmpty) return 0;
    double score = 0;
    double maxScore = 0;
    final calAdh = calorieAdherenceRate;
    final protAdh = proteinAdherenceRate;
    final watAdh = waterAdherenceRate;
    if (calAdh > 0) { score += calAdh * 30; maxScore += 30; }
    if (protAdh > 0) { score += protAdh * 25; maxScore += 25; }
    if (watAdh > 0) { score += watAdh * 15; maxScore += 15; }
    score += (weeklyWorkoutDays / 4.0).clamp(0.0, 1.0) * 20; maxScore += 20;
    if (!hasLateNightEatingPattern) score += 10; maxScore += 10;
    return maxScore > 0 ? (score / maxScore * 100).round().clamp(0, 100) : 0;
  }

  /// Yesterday's calories (0 if no data).
  double get yesterdayCal =>
      caloriesForDate(DateTime.now().subtract(const Duration(days: 1)));

  /// Yesterday's protein (0 if no data).
  double get yesterdayProtein =>
      proteinForDate(DateTime.now().subtract(const Duration(days: 1)));

  /// Yesterday's water in mL (0 if no data).
  int get yesterdayWater =>
      waterForDate(DateTime.now().subtract(const Duration(days: 1)));

  /// True if any workout was logged yesterday.
  bool get workedOutYesterday {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return _workoutHistory.any((w) =>
        w.date.year == yesterday.year &&
        w.date.month == yesterday.month &&
        w.date.day == yesterday.day);
  }

  // ── Persistence ────────────────────────────────────────────────────────────
  String get _todayKey {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> loadData() async {
    _oneRmCache = null; // invalidate on every reload (import, app start, etc.)
    // Drop memoized derived caches so a reload (import, midnight, resume) never
    // serves a value computed against the previous dataset.
    _foodHistoryCache = null;
    _waterHistoryCache = null;
    _insightSnapshot = null;
    final prefs = await SharedPreferences.getInstance();

    // User profile
    _heightCm = prefs.getDouble('height_cm') ?? 170.0;
    _age = prefs.getInt('age') ?? 24;
    _isMale = prefs.getBool('is_male') ?? true;
    _goalWeightKg = prefs.getDouble('goal_weight_kg') ?? 70.0;
    _userName = prefs.getString('user_name') ?? 'Friend';
    // Haptic feedback preference — sync the global flag so every widget sees it.
    _hapticsEnabled = prefs.getBool('haptics_enabled') ?? true;
    Haptics.enabled = _hapticsEnabled;
    // Goal direction is resolved (with one-time migration) after body/scale
    // history loads below, since inference needs the current weight.
    final storedGoalDir = prefs.getString('goal_direction');
    _onboardingDone = prefs.getBool('onboarding_done') ?? false;
    _aiCoachEnabled = prefs.getBool('ai_coach_enabled') ?? true;
    _aiCoachMode = prefs.getString('ai_coach_mode') == 'cloud'
        ? AiCoachMode.cloud
        : AiCoachMode.local;
    // Restore today's cached daily brief (if generated earlier today).
    if (prefs.getString('ai_brief_date') == _todayKey) {
      _dailyBrief = prefs.getString('ai_brief_text');
    }
    _autoUpdateCheck = prefs.getBool('auto_update_check') ?? true;
    _updateSnoozedUntilMs = prefs.getInt('update_snoozed_until_ms') ?? 0;
    _updateInitiatedAtMs = prefs.getInt('update_initiated_at_ms') ?? 0;

    // User-defined goals
    _calorieGoal = prefs.getInt('calorie_goal') ?? kDefaultCalorieGoal;
    _proteinGoal = prefs.getInt('protein_goal') ?? kDefaultProteinGoal;
    _waterGoalMl = prefs.getInt('water_goal_ml') ?? kDefaultWaterGoalMl;
    _stepGoal = prefs.getInt('step_goal') ?? kDefaultStepGoal;
    _carbGoal = prefs.getInt('carb_goal') ?? kDefaultCarbGoal;
    _fatGoal = prefs.getInt('fat_goal') ?? kDefaultFatGoal;

    // Per-food portion memory + favorites + backup timestamp
    _lastBackupMs = prefs.getInt('last_backup_ms') ?? 0;
    _favoriteFoods = (prefs.getStringList('favorite_foods') ?? const [])
        .map(normalizeFood)
        .where((s) => s.isNotEmpty)
        .toSet();
    try {
      final pj = prefs.getString('food_portions');
      _foodPortions = pj != null
          ? (jsonDecode(pj) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toDouble()))
          : {};
    } catch (_) {
      _foodPortions = {};
    }

    // Ensure profile + goals are always persisted so they appear in backups
    // even when the user has never opened Settings to change them from defaults.
    if (!prefs.containsKey('user_name'))    await prefs.setString('user_name',    _userName);
    if (!prefs.containsKey('height_cm'))    await prefs.setDouble('height_cm',    _heightCm);
    if (!prefs.containsKey('age'))          await prefs.setInt('age',             _age);
    if (!prefs.containsKey('is_male'))      await prefs.setBool('is_male',        _isMale);
    if (!prefs.containsKey('goal_weight_kg')) await prefs.setDouble('goal_weight_kg', _goalWeightKg);
    if (!prefs.containsKey('calorie_goal')) await prefs.setInt('calorie_goal',    _calorieGoal);
    if (!prefs.containsKey('protein_goal')) await prefs.setInt('protein_goal',    _proteinGoal);
    if (!prefs.containsKey('water_goal_ml')) await prefs.setInt('water_goal_ml', _waterGoalMl);
    if (!prefs.containsKey('step_goal'))    await prefs.setInt('step_goal',       _stepGoal);
    if (!prefs.containsKey('ai_coach_enabled')) await prefs.setBool('ai_coach_enabled', _aiCoachEnabled);
    if (!prefs.containsKey('auto_update_check')) await prefs.setBool('auto_update_check', _autoUpdateCheck);

    // Always reset today's data first (handles midnight day-change case)
    _todayFood = [];
    _todayWaterMl = 0;
    _supplements = SupplementStatus();

    // Food — wrapped in try/catch: corrupt JSON must not crash loadData()
    try {
      final foodJson = prefs.getString('food_$_todayKey');
      if (foodJson != null) {
        final list = jsonDecode(foodJson) as List;
        _todayFood = list.map((e) => FoodEntry.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) { _todayFood = []; }

    // Water
    _todayWaterMl = prefs.getInt('water_$_todayKey') ?? 0;

    // Supplements
    try {
      final suppJson = prefs.getString('supp_$_todayKey');
      if (suppJson != null) {
        _supplements = SupplementStatus.fromJson(jsonDecode(suppJson) as Map<String, dynamic>);
      }
    } catch (_) { _supplements = SupplementStatus(); }

    // Workouts
    try {
      final workoutJson = prefs.getString('workouts');
      if (workoutJson != null) {
        final list = jsonDecode(workoutJson) as List;
        _workoutHistory = list.map((e) => WorkoutLog.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) { _workoutHistory = []; }

    // Body history
    try {
      final bodyJson = prefs.getString('body_history');
      if (bodyJson != null) {
        final list = jsonDecode(bodyJson) as List;
        _bodyHistory = list.map((e) => BodyEntry.fromJson(e as Map<String, dynamic>)).toList();
        _bodyHistory.sort((a, b) => a.date.compareTo(b.date));
      }
    } catch (_) { _bodyHistory = []; }

    // Smart scale history
    try {
      final scaleJson = prefs.getString('scale_history');
      if (scaleJson != null) {
        final list = jsonDecode(scaleJson) as List;
        _scaleHistory = list.map((e) => SmartScaleEntry.fromJson(e as Map<String, dynamic>)).toList();
        _scaleHistory.sort((a, b) => a.date.compareTo(b.date));
      }
    } catch (_) { _scaleHistory = []; }

    // Body measurements history
    try {
      final measureJson = prefs.getString('measurements_history');
      if (measureJson != null) {
        final list = jsonDecode(measureJson) as List;
        _measurementHistory = list.map((e) => MeasurementEntry.fromJson(e as Map<String, dynamic>)).toList();
        _measurementHistory.sort((a, b) => a.date.compareTo(b.date));
      }
    } catch (_) { _measurementHistory = []; }

    // Goal direction: honour the stored value; migrate existing users ONCE by
    // inferring from goal weight vs current weight (body/scale history is now
    // loaded, so latestWeightKg is available), then persist so it's stable.
    if (storedGoalDir != null) {
      _goalDirection = goalDirectionFromName(storedGoalDir);
    } else {
      _goalDirection = inferGoalDirection(
        goalWeightKg: _goalWeightKg,
        currentWeightKg: latestWeightKg,
      );
      await prefs.setString('goal_direction', _goalDirection.name);
    }

    // Historical food, water, supplement — ALL stored days (no cap). Nothing is
    // ever pruned, so scan EVERY persisted daily key instead of a fixed 60-day
    // window. Today's own data lives in _todayFood/_todayWater/_supplements, so
    // today's key is skipped here to avoid a stale duplicate.
    _foodHistory = {};
    _waterHistory = {};
    _supplementHistory = {};
    final today = _todayKey;
    for (final k in prefs.getKeys()) {
      if (k.startsWith('food_')) {
        final key = k.substring('food_'.length);
        if (key == today || key.length != 10) continue;
        final fJson = prefs.getString(k);
        if (fJson != null) {
          try {
            final list = jsonDecode(fJson) as List;
            _foodHistory[key] =
                list.map((e) => FoodEntry.fromJson(e)).toList();
          } catch (_) {}
        }
      } else if (k.startsWith('water_')) {
        final key = k.substring('water_'.length);
        if (key == today || key.length != 10) continue;
        final w = prefs.getInt(k);
        if (w != null) _waterHistory[key] = w;
      } else if (k.startsWith('supp_')) {
        final key = k.substring('supp_'.length);
        if (key == today || key.length != 10) continue;
        final sJson = prefs.getString(k);
        if (sJson != null) {
          try {
            _supplementHistory[key] =
                SupplementStatus.fromJson(jsonDecode(sJson));
          } catch (_) {}
        }
      }
    }

    // Resolved before _isLoaded flips true — main.dart's startup gate checks
    // isTampered on the same frame isLoaded first becomes true, so a
    // tampered build never gets a chance to show a real screen.
    _isTampered = await IntegrityCheckService.isTampered();
    _isLoaded = true;
    _loadedForDate = _todayKey;

    if (_isTampered) {
      // Nothing past this point (pedometer, notifications, network calls,
      // widget updates) should run on a build that shouldn't be running at
      // all — main.dart shows the block screen and nothing else happens.
      notifyListeners();
      return;
    }

    // NOTE: daily food/water/supp keys are intentionally NEVER purged — the user
    // keeps their full history forever. (Chat sessions are still capped below.)

    // Issue #14: Prune chat sessions older than 30 days on app startup
    await ChatSessionService.pruneOldSessions();

    notifyListeners();
    _updateWidget();

    // Populate the in-app notification center (insights snapshot + milestones).
    _populateNotifications();

    // Start pedometer after data is loaded (non-blocking)
    startPedometer();

    // Start day-reset watcher (detects midnight crossover while app is open)
    _startDayResetTimer();

    // Refresh the once-a-day cloud AI brief (non-blocking; no-op if not due /
    // cloud AI not configured / coach disabled).
    refreshDailyBriefIfDue();
  }

  // ── In-app notification center ──────────────────────────────────────────────
  // The feed is two parts:
  //  • LIVE insights — recomputed from current state, so an item like "steps not
  //    yet hit" auto-disappears the moment the target is met (never persisted).
  //  • MILESTONES — achievements that persist (streaks, goal reached, recomp wins).
  List<AppNotification> _milestones = [];
  Set<String> _seenInsightTitles = {};

  // Memoized insight snapshot (C1). `unreadNotifications` → `liveInsightFeed` →
  // `topInsights(...)` runs the whole insight engine, and the badge reads it on
  // many rebuilds. Cache the computed insight list keyed on [_dataVersion] (any
  // mutation) + the calendar day (time-of-day thresholds change at midnight), so
  // rebuilds that carry no data change reuse the last result instead of
  // re-deriving. `_populateNotifications`, the badge, and the panel all share it.
  List<Insight>? _insightSnapshot;
  int _insightSnapshotVersion = -1;
  String _insightSnapshotDay = '';

  List<Insight> get _liveInsights {
    final day = _todayKey;
    if (_insightSnapshot != null &&
        _insightSnapshotVersion == _dataVersion &&
        _insightSnapshotDay == day) {
      return _insightSnapshot!;
    }
    final snap = topInsights(this, DateTime.now(), count: 6);
    _insightSnapshot = snap;
    _insightSnapshotVersion = _dataVersion;
    _insightSnapshotDay = day;
    return snap;
  }

  /// Live AI Coach insights as feed items (deduped by category, top 6).
  List<AppNotification> get liveInsightFeed {
    final insights = _liveInsights;
    return insights
        .map((ins) => AppNotification(
              id: 'insight_${ins.category.name}',
              emoji: ins.emoji,
              title: ins.title,
              body: ins.body,
              accent: ins.accent.value,
              category: 'insight',
              timestamp: DateTime.now(),
              read: _seenInsightTitles.contains(ins.title),
              insightCategory: ins.category.name,
            ))
        .toList();
  }

  /// Persisted milestone achievements (newest first).
  List<AppNotification> get milestoneFeed => _milestones;

  /// Badge count: unseen live insights + unread milestones.
  int get unreadNotifications {
    final unseenInsights =
        liveInsightFeed.where((n) => !n.read).length;
    final unreadMilestones = _milestones.where((n) => !n.read).length;
    return unseenInsights + unreadMilestones;
  }

  Future<void> _refreshNotifications() async {
    _milestones = await NotificationCenter.all();
    notifyListeners();
  }

  Future<void> markNotificationsRead() async {
    // Mark milestones read and remember the insight titles currently shown so
    // they stop contributing to the badge until a NEW scenario appears.
    await NotificationCenter.markAllRead();
    final titles = liveInsightFeed.map((n) => n.title).toSet();
    _seenInsightTitles = {..._seenInsightTitles, ...titles};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('seen_insight_titles', _seenInsightTitles.toList());
    await _refreshNotifications();
  }

  Future<void> clearNotifications() async {
    await NotificationCenter.clear();
    await _refreshNotifications();
  }

  Future<void> _populateNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _seenInsightTitles =
          (prefs.getStringList('seen_insight_titles') ?? const []).toSet();
      // Prune seen titles that are no longer active insights (so a recurring
      // scenario re-badges next time it appears).
      final active = liveInsightFeed.map((n) => n.title).toSet();
      _seenInsightTitles = _seenInsightTitles.intersection(active);
      await prefs.setStringList('seen_insight_titles', _seenInsightTitles.toList());

      await _detectMilestones();
      await _refreshNotifications();
    } catch (_) {}
  }

  Future<void> _detectMilestones() async {
    final prefs = await SharedPreferences.getInstance();

    // Workout-streak milestones (fire once per threshold crossing).
    final ws = workoutStreak;
    final lastWs = prefs.getInt('ms_workout_streak') ?? 0;
    for (final m in [7, 14, 30, 60, 100]) {
      if (ws >= m && lastWs < m) {
        await NotificationCenter.add(AppNotification(
          id: const Uuid().v4(), emoji: '🏋️',
          title: '$m-day workout streak!',
          body: '$m days in a row — elite consistency. Keep the chain unbroken.',
          accent: 0xFFFF9F0A, category: 'milestone', timestamp: DateTime.now(),
        ));
        _celebratePending = true;
      }
    }
    await prefs.setInt('ms_workout_streak', ws);

    // Diet-streak milestones.
    final cs = calorieStreak;
    final lastCs = prefs.getInt('ms_calorie_streak') ?? 0;
    for (final m in [7, 30]) {
      if (cs >= m && lastCs < m) {
        await NotificationCenter.add(AppNotification(
          id: const Uuid().v4(), emoji: '🥗',
          title: '$m-day diet logging streak!',
          body: 'Logged your food $m days straight. Awareness is half the battle.',
          accent: 0xFF40C8E0, category: 'milestone', timestamp: DateTime.now(),
        ));
        _celebratePending = true;
      }
    }
    await prefs.setInt('ms_calorie_streak', cs);

    // Goal reached.
    final reached = startWeightKg != null && goalProgress >= 1.0;
    final wasReached = prefs.getBool('ms_goal_reached') ?? false;
    if (reached && !wasReached) {
      await NotificationCenter.add(AppNotification(
        id: const Uuid().v4(), emoji: '🎯',
        title: 'Goal weight reached! 🎉',
        body: 'You hit ${_goalWeightKg.toStringAsFixed(1)} kg. Time to set a new '
            'target or shift to maintenance.',
        accent: 0xFF30D158, category: 'milestone', timestamp: DateTime.now(),
      ));
      _celebratePending = true;
    }
    await prefs.setBool('ms_goal_reached', reached);
  }

  /// Adds a notification to the in-app center (used by reminders/foreground service).
  Future<void> pushNotification(AppNotification n) async {
    await NotificationCenter.add(n);
    await _refreshNotifications();
  }

  /// True when [d] falls on the current calendar day.
  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  // ── Food actions ───────────────────────────────────────────────────────────
  /// Adds [entry] to [date] (defaults to today). Backdating writes to that day's
  /// stored list and updates the in-memory history so trends/averages refresh
  /// immediately.
  Future<void> addFoodEntry(FoodEntry entry, {DateTime? date}) async {
    final d = date ?? DateTime.now();
    if (_isToday(d)) {
      _todayFood.add(entry);
      await _saveFoodEntries();
    } else {
      final key = _keyFor(d);
      final list = [...?_foodHistory[key], entry];
      _foodHistory[key] = list;
      await _saveFoodForKey(key, list);
    }
    notifyListeners();
    _updateWidget();
  }

  /// Removes the entry with [id] from [date] (defaults to today).
  Future<void> removeFoodEntry(String id, {DateTime? date}) async {
    final d = date ?? DateTime.now();
    if (_isToday(d)) {
      _todayFood.removeWhere((e) => e.id == id);
      await _saveFoodEntries();
    } else {
      final key = _keyFor(d);
      final list = (_foodHistory[key] ?? []).where((e) => e.id != id).toList();
      _foodHistory[key] = list;
      await _saveFoodForKey(key, list);
    }
    notifyListeners();
    _updateWidget();
  }

  /// Replaces the entry with [id] on [date] with [updated] — used when editing a
  /// logged item's quantity. No-op if the id isn't found on that day.
  Future<void> updateFoodEntry(String id, FoodEntry updated, {DateTime? date}) async {
    final d = date ?? DateTime.now();
    if (_isToday(d)) {
      final i = _todayFood.indexWhere((e) => e.id == id);
      if (i >= 0) _todayFood[i] = updated;
      await _saveFoodEntries();
    } else {
      final key = _keyFor(d);
      final list = [...?_foodHistory[key]];
      final i = list.indexWhere((e) => e.id == id);
      if (i < 0) return;
      list[i] = updated;
      _foodHistory[key] = list;
      await _saveFoodForKey(key, list);
    }
    notifyListeners();
    _updateWidget();
  }

  Future<void> _saveFoodEntries() => _saveFoodForKey(_todayKey, _todayFood);

  Future<void> _saveFoodForKey(String key, List<FoodEntry> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'food_$key', jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ── Water actions ──────────────────────────────────────────────────────────
  /// Adds [ml] of water to [date] (defaults to today). Negative [ml] subtracts.
  Future<void> addWater(int ml, {DateTime? date}) async {
    final d = date ?? DateTime.now();
    if (_isToday(d)) {
      _todayWaterMl = (_todayWaterMl + ml).clamp(0, 99999);
      await _saveWater();
    } else {
      final key = _keyFor(d);
      final v = ((_waterHistory[key] ?? 0) + ml).clamp(0, 99999);
      _waterHistory[key] = v;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('water_$key', v);
    }
    notifyListeners();
    _updateWidget();
  }

  Future<void> removeWater(int ml, {DateTime? date}) => addWater(-ml, date: date);

  Future<void> _saveWater() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('water_$_todayKey', _todayWaterMl);
  }

  // ── Supplement actions ─────────────────────────────────────────────────────
  Future<void> updateSupplement(String key, bool value) async {
    switch (key) {
      case 'whey':
        _supplements.whey = value;
        break;
      case 'creatine':
        _supplements.creatine = value;
        break;
      case 'multivitamin':
        _supplements.multivitamin = value;
        break;
      default:
        assert(false, 'updateSupplement: unknown key "$key"');
        return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'supp_$_todayKey', jsonEncode(_supplements.toJson()));
    notifyListeners();
    _updateWidget();
  }

  // ── Workout actions ────────────────────────────────────────────────────────
  Future<void> logWorkout(WorkoutLog workout) async {
    _workoutHistory.add(workout);
    // Retained forever — no history trim (user keeps all their data).
    _oneRmCache = null; // invalidate cached 1RM estimates

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'workouts',
      jsonEncode(_workoutHistory.map((w) => w.toJson()).toList()),
    );
    notifyListeners();
  }

  // ── Body / weight actions ──────────────────────────────────────────────────
  /// Logs a weigh-in for [date] (defaults to today). One entry per day — logging
  /// again for the same date replaces it. Backdating fills gaps in the weight
  /// trend that powers the regression/forecast and adaptive TDEE.
  Future<void> logBodyEntry(
      {required double weightKg, int steps = 0, DateTime? date}) async {
    final now = DateTime.now();
    final d = date ?? now;
    _bodyHistory.removeWhere((e) =>
        e.date.year == d.year &&
        e.date.month == d.month &&
        e.date.day == d.day);

    _bodyHistory.add(BodyEntry(
      id: const Uuid().v4(),
      date: d,
      weightKg: weightKg,
      steps: steps,
    ));
    _bodyHistory.sort((a, b) => a.date.compareTo(b.date));
    // Retained forever — no 180-day trim (user keeps all their data).
    await _saveBodyHistory();
    notifyListeners();
  }

  Future<void> _saveBodyHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'body_history',
      jsonEncode(_bodyHistory.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveHeight(double cm) async {
    _heightCm = cm;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('height_cm', cm);
    notifyListeners();
  }

  // ── Smart Scale actions ────────────────────────────────────────────────────
  /// Logs a smart-scale reading. The reading's day comes from [entry].date, so
  /// passing an entry dated in the past backdates it (one reading per day).
  Future<void> logScaleEntry(SmartScaleEntry entry) async {
    final d = entry.date;
    _scaleHistory.removeWhere((e) =>
        e.date.year == d.year &&
        e.date.month == d.month &&
        e.date.day == d.day);
    _scaleHistory.add(entry);
    _scaleHistory.sort((a, b) => a.date.compareTo(b.date));
    // Retained forever — no 365-day trim (user keeps all their data).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'scale_history',
      jsonEncode(_scaleHistory.map((e) => e.toJson()).toList()),
    );
    // Preserve that day's manually-logged steps — logBodyEntry defaults steps to
    // 0 which would wipe any steps already entered for the reading's date.
    final dayBody = _bodyHistory.where((e) =>
        e.date.year == d.year &&
        e.date.month == d.month &&
        e.date.day == d.day).toList();
    final existingSteps = dayBody.isNotEmpty ? dayBody.first.steps : 0;
    await logBodyEntry(weightKg: entry.weightKg, steps: existingSteps, date: d);
    notifyListeners();
  }

  // ── Measurement actions ────────────────────────────────────────────────────
  Future<void> logMeasurement(MeasurementEntry entry) async {
    if (entry.isEmpty) return;
    final d = entry.date; // honour the entry's date so measurements can backdate
    _measurementHistory.removeWhere((e) =>
        e.date.year == d.year &&
        e.date.month == d.month &&
        e.date.day == d.day);
    _measurementHistory.add(entry);
    _measurementHistory.sort((a, b) => a.date.compareTo(b.date));
    // Retained forever — no 180-day trim (user keeps all their data).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'measurements_history',
      jsonEncode(_measurementHistory.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  // ── Export / Import ────────────────────────────────────────────────────────
  // Keys that are device-specific and must not be exported/imported.
  // Keys excluded from export: device-specific state that must not be restored
  // on a different device or fresh install.
  // ai_installed_model_id: model file lives in device storage — restoring this flag
  // on a fresh install makes the app think the model is installed when it isn't,
  // causing "Active model is no longer installed" errors.
  static const _exportExcludeKeys = {
    'pedometer_baseline',
    'pedometer_date',
    'ai_installed_model_id',
    'hf_token_ai_chat',   // device-specific HuggingFace token — never exported
    'chat_sessions_v1',   // health conversation history — too sensitive for backup files
  };

  /// Serializes all backup-eligible SharedPreferences into a JSON string. Shared
  /// by the local file export and the GitHub cloud backup so both produce the
  /// exact same payload.
  /// Keys that must never travel in a backup — the static device-specific set
  /// plus any `cloud_*` sync state (git sha, last-backup time, account). Carrying
  /// those to another device would plant a stale sha / wrong account.
  static bool _isExcludedFromBackup(String key) =>
      _exportExcludeKeys.contains(key) || key.startsWith('cloud_');

  Future<String> buildBackupJson() async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> data = {};
    for (final key in prefs.getKeys()) {
      if (_isExcludedFromBackup(key)) continue;
      data[key] = prefs.get(key);
    }
    return jsonEncode(data);
  }

  /// Restores backup-eligible keys from a backup JSON string (used by both file
  /// import and cloud restore). Returns false on malformed input.
  Future<bool> importFromJsonString(String content) async {
    try {
      final Map<String, dynamic> data = jsonDecode(content);
      final prefs = await SharedPreferences.getInstance();
      for (final entry in data.entries) {
        // Never restore device-specific or sensitive keys from a backup
        if (_isExcludedFromBackup(entry.key)) continue;
        final val = entry.value;
        if (val is String) {
          await prefs.setString(entry.key, val);
        } else if (val is bool) {
          await prefs.setBool(entry.key, val);
        } else if (val is int) {
          await prefs.setInt(entry.key, val);
        } else if (val is double) {
          await prefs.setDouble(entry.key, val);
        } else if (val is List) {
          // StringList keys (favorites, recent scans, etc.)
          await prefs.setStringList(
              entry.key, val.map((e) => e.toString()).toList());
        }
      }
      await loadData(); // reload everything
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> exportAllData() async {
    final json = await buildBackupJson();
    // Write to app documents directory
    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().toIso8601String()
        .replaceAll(':', '-').replaceAll('.', '-').substring(0, 19);
    final fileName = 'kfitness_backup_$timestamp.json';
    final file = File('${dir.path}/$fileName');
    try {
      await file.writeAsString(json);
    } on FileSystemException catch (e) {
      throw Exception('Export failed — check storage space. (${e.message})');
    } catch (e) {
      throw Exception('Export failed: $e');
    }
    await markBackedUp(); // reset the backup-reminder clock
    return file.path;
  }

  Future<bool> importAllData(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      return await importFromJsonString(await file.readAsString());
    } catch (_) {
      return false;
    }
  }

  // ── Weight Prediction (Linear Regression) ─────────────────────────────────
  ({double slope, double intercept})? get _weightRegression {
    final entries = getRecentBodyEntries(days: 90);
    return _regressionOver(entries);
  }

  /// Least-squares weight regression over [entries] (x = days since first
  /// entry). Shared by the 90-day chart/forecast regression and the 60-day
  /// adaptive-TDEE trend so each can match its window to its purpose.
  static ({double slope, double intercept})? _regressionOver(
      List<BodyEntry> entries) {
    if (entries.length < 5) return null;

    final first = entries.first.date.millisecondsSinceEpoch.toDouble();
    final xs = entries
        .map((e) => (e.date.millisecondsSinceEpoch - first) / 86400000.0)
        .toList();
    final ys = entries.map((e) => e.weightKg).toList();
    final n = xs.length;
    final xMean = xs.reduce((a, b) => a + b) / n;
    final yMean = ys.reduce((a, b) => a + b) / n;
    final num = xs.asMap().entries
        .map((e) => (e.value - xMean) * (ys[e.key] - yMean))
        .reduce((a, b) => a + b);
    final den = xs.map((x) => (x - xMean) * (x - xMean)).reduce((a, b) => a + b);
    if (den == 0) return null;
    final slope = num / den;
    final intercept = yMean - slope * xMean;
    return (slope: slope, intercept: intercept);
  }

  double? predictedWeightInDays(int days) {
    final reg = _weightRegression;
    if (reg == null) return null;
    final entries = getRecentBodyEntries(days: 90);
    if (entries.isEmpty) return null;
    final first = entries.first.date.millisecondsSinceEpoch.toDouble();
    final today = DateTime.now().millisecondsSinceEpoch.toDouble();
    final x = (today - first) / 86400000.0 + days;
    return reg.intercept + reg.slope * x;
  }

  double? get weeklyWeightChange {
    final reg = _weightRegression;
    if (reg == null) return null;
    return reg.slope * 7;
  }

  List<(DateTime, double)> weightForecast({int days = 30}) {
    final reg = _weightRegression;
    if (reg == null) return [];
    final entries = getRecentBodyEntries(days: 90);
    if (entries.isEmpty) return [];
    final first = entries.first.date.millisecondsSinceEpoch.toDouble();
    final today = DateTime.now();
    return List.generate(days, (i) {
      final d = today.add(Duration(days: i + 1));
      final x = (d.millisecondsSinceEpoch - first) / 86400000.0;
      return (d, reg.intercept + reg.slope * x);
    });
  }

  DateTime? get estimatedGoalDate {
    final reg = _weightRegression;
    final w = latestWeightKg;
    if (reg == null || w == null) return null;
    if (reg.slope >= 0 && w > _goalWeightKg) return null;
    final entries = getRecentBodyEntries(days: 90);
    if (entries.isEmpty) return null;
    final first = entries.first.date.millisecondsSinceEpoch.toDouble();
    final today = DateTime.now().millisecondsSinceEpoch.toDouble();
    final x0 = (today - first) / 86400000.0;
    if (reg.slope == 0) return null;
    final xGoal = (_goalWeightKg - reg.intercept) / reg.slope;
    final daysToGoal = xGoal - x0;
    if (daysToGoal < 0 || daysToGoal > 730) return null;
    return DateTime.now().add(Duration(days: daysToGoal.round()));
  }

  Future<void> saveAge(int years) async {
    _age = years.clamp(10, 100);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('age', _age);
    notifyListeners();
  }

  Future<void> saveGoalWeight(double kg) async {
    _goalWeightKg = kg.clamp(30, 300);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('goal_weight_kg', _goalWeightKg);
    notifyListeners();
  }

  Future<void> saveSex(bool isMale) async {
    _isMale = isMale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_male', _isMale);
    notifyListeners();
  }

  // ── Day-reset timer ────────────────────────────────────────────────────────
  /// Fires every minute. If the calendar date has changed since last load,
  /// saves the current live step count as the new day's baseline (so steps
  /// walked before midnight are preserved), then calls loadData().
  void _startDayResetTimer() {
    _dayResetTimer?.cancel();
    // Issue #13: Change from 1-minute to 1-hour polling to reduce battery drain
    _dayResetTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      if (_loadedForDate.isNotEmpty && _loadedForDate != _todayKey) {
        // Before reloading, anchor the step baseline at the midnight crossover.
        // This ensures steps walked before first app-open of the new day are kept.
        if (_livePedometerTotal > 0) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('pedometer_baseline', _livePedometerTotal);
          await prefs.setString('pedometer_date', _todayKey);
          _pedometerDayBaseline = _livePedometerTotal;
          _pedometerBaselineDate = _todayKey;
        }
        await loadData(); // new day detected
      }
    });
  }

  // ── Pedometer ──────────────────────────────────────────────────────────────
  Future<void> startPedometer() async {
    final prefs = await SharedPreferences.getInstance();
    _pedometerBaselineDate = prefs.getString('pedometer_date') ?? '';
    _pedometerDayBaseline  = prefs.getInt('pedometer_baseline') ?? -1;

    if (_pedometerBaselineDate != _todayKey) {
      _pedometerDayBaseline = -1;
      _pedometerBaselineDate = '';
    }

    _stepSubscription?.cancel();
    // Pre-warm the prefs cache so the per-step callback never blocks on a
    // getInstance() call — the singleton is always ready after the first await.
    _cachedPrefs ??= await SharedPreferences.getInstance();

    try {
      _stepSubscription = Pedometer.stepCountStream.listen(
        (StepCount event) async {
          // Use the cached instance; fall back to a fresh fetch only if somehow null.
          final prefs = _cachedPrefs ?? await SharedPreferences.getInstance();

          if (_livePedometerTotal > 0) {
            if (event.steps < _livePedometerTotal) {
              // Sensor reset to a lower value (device reboot, counter rollover).
              // Start a fresh baseline at this new value so today's count
              // continues from the steps already walked since the reset.
              _pedometerDayBaseline = event.steps;
              _pedometerBaselineDate = _todayKey;
              await prefs.setInt('pedometer_baseline', _pedometerDayBaseline);
              await prefs.setString('pedometer_date', _pedometerBaselineDate);
            } else if (event.steps > _livePedometerTotal + 50000) {
              // Huge forward jump — adjust baseline to preserve today's count.
              _pedometerDayBaseline = event.steps - (_livePedometerTotal - _pedometerDayBaseline);
              await prefs.setInt('pedometer_baseline', _pedometerDayBaseline);
            }
          }

          _livePedometerTotal = event.steps;

          if (_pedometerDayBaseline < 0) {
            _pedometerDayBaseline = event.steps;
            _pedometerBaselineDate = _todayKey;
            await prefs.setInt('pedometer_baseline', _pedometerDayBaseline);
            await prefs.setString('pedometer_date', _pedometerBaselineDate);
          }

          // Throttle UI rebuilds: the step sensor can fire several times/second
          // while walking. Notifying every event rebuilds all 5 mounted screens.
          // 2-second cadence is imperceptible for a step counter and removes jank.
          final now = DateTime.now();
          if (_lastPedometerNotify == null ||
              now.difference(_lastPedometerNotify!) >=
                  const Duration(seconds: 2)) {
            _lastPedometerNotify = now;
            notifyListeners();
          }
          // Keep the home-screen widget's step count live while the app runs.
          // Throttled to 15 s — a widget redraw is heavier than a rebuild, and
          // a step counter doesn't need finer granularity than that.
          if (_lastWidgetStepPush == null ||
              now.difference(_lastWidgetStepPush!) >=
                  const Duration(seconds: 15)) {
            _lastWidgetStepPush = now;
            _updateWidget();
          }
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _dayResetTimer?.cancel();
    _stepSubscription?.cancel();
    super.dispose();
  }

  // ── Home widget ────────────────────────────────────────────────────────────
  // The Android side (KFitnessWidgetProvider.kt) draws the widget natively from
  // these values — no Flutter engine / renderFlutterWidget (that crashed at cold
  // start) and no file URIs.

  /// Top [n] notifications for the home-screen widget — persisted milestones
  /// first (newest), then live AI insights — deduped by title.
  List<AppNotification> widgetNotifications({int n = 3}) =>
      mergeWidgetNotifications(milestoneFeed, liveInsightFeed, n: n);

  /// Pure merge/dedup for [widgetNotifications]: concatenates [milestones] then
  /// [insights], skips blank titles, dedupes by title, and takes the first [n].
  /// Pure (no provider state) so it's deterministically unit-testable.
  static List<AppNotification> mergeWidgetNotifications(
    List<AppNotification> milestones,
    List<AppNotification> insights, {
    int n = 3,
  }) {
    final seen = <String>{};
    final out = <AppNotification>[];
    for (final f in [...milestones, ...insights]) {
      if (f.title.trim().isEmpty) continue;
      if (seen.add(f.title)) out.add(f);
      if (out.length >= n) break;
    }
    return out;
  }

  Future<void> _updateWidget() async {
    try {
      final notifs = widgetNotifications(n: 3);
      String nEmoji(int i) => i < notifs.length ? notifs[i].emoji : '';
      String nTitle(int i) => i < notifs.length ? notifs[i].title : '';

      // Batch all saveWidgetData calls in parallel, then trigger a single redraw.
      await Future.wait([
        HomeWidget.saveWidgetData<int>('calories', todayCaloriesTotal.round()),
        HomeWidget.saveWidgetData<int>('protein', todayProteinTotal.round()),
        HomeWidget.saveWidgetData<int>('water', todayWaterMl),
        HomeWidget.saveWidgetData<int>('steps', todaySteps),
        HomeWidget.saveWidgetData<int>('stepGoal', stepGoal),
        // Raw unclamped percentages (>100 allowed) so the widget can draw overflow.
        HomeWidget.saveWidgetData<int>('calPct',
            calorieGoal > 0 ? (todayCaloriesTotal / calorieGoal * 100).round() : 0),
        HomeWidget.saveWidgetData<int>('protPct',
            proteinGoal > 0 ? (todayProteinTotal / proteinGoal * 100).round() : 0),
        HomeWidget.saveWidgetData<int>('waterPct',
            waterGoalMl > 0 ? (todayWaterMl / waterGoalMl * 100).round() : 0),
        HomeWidget.saveWidgetData<int>('stepPct',
            stepGoal > 0 ? (todaySteps / stepGoal * 100).round() : 0),
        // Top-3 notifications (emoji + title).
        HomeWidget.saveWidgetData<String>('notif1Emoji', nEmoji(0)),
        HomeWidget.saveWidgetData<String>('notif1Title', nTitle(0)),
        HomeWidget.saveWidgetData<String>('notif2Emoji', nEmoji(1)),
        HomeWidget.saveWidgetData<String>('notif2Title', nTitle(1)),
        HomeWidget.saveWidgetData<String>('notif3Emoji', nEmoji(2)),
        HomeWidget.saveWidgetData<String>('notif3Title', nTitle(2)),
      ]);

      await HomeWidget.updateWidget(
        name: 'KFitnessWidgetProvider',
        androidName: 'KFitnessWidgetProvider',
        qualifiedAndroidName: 'com.example.karthik_fitness.KFitnessWidgetProvider',
      );
    } catch (_) {}
  }

  // Helper
  String newId() => const Uuid().v4();
}
