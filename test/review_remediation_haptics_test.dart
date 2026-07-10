import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kfit/models/models.dart';
import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/services/food_repository.dart';
import 'package:kfit/services/gemini_vision_service.dart';
import 'package:kfit/services/haptics.dart';
import 'package:kfit/services/meal_scan.dart';
import 'package:kfit/services/scan_quota.dart';
import 'package:kfit/services/smart_insight_engine.dart';

/// Seeds body_history with (date, weightKg) so past-dated trends work.
Map<String, Object> _seedBody(List<(DateTime, double)> entries) => {
      'body_history': _jsonBody(entries),
    };

String _jsonBody(List<(DateTime, double)> entries) {
  final buf = StringBuffer('[');
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    buf.write(
        '{"id":"b$i","date":"${e.$1.toIso8601String()}","weightKg":${e.$2},"steps":0}');
    if (i < entries.length - 1) buf.write(',');
  }
  buf.write(']');
  return buf.toString();
}

FoodEntry _food(FitnessProvider p, double kcal) => FoodEntry(
      id: p.newId(),
      name: 'Test meal',
      calories: kcal,
      protein: 10,
      carbs: 20,
      fat: 5,
      macrosKnown: true,
      mealType: MealType.lunch,
      timestamp: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─── A3 — portion rescale (pure math) ─────────────────────────────────────
  group('A3 rescaleScannedFood', () {
    const base = ScannedFood(
        name: 'Rice',
        grams: 100,
        kcal: 130,
        protein: 2.7,
        carbs: 28,
        fat: 0.3,
        confidence: 0.8);

    test('doubling grams doubles every macro', () {
      final d = rescaleScannedFood(base, 200);
      expect(d.grams, 200);
      expect(d.kcal, closeTo(260, 0.001));
      expect(d.protein, closeTo(5.4, 0.001));
      expect(d.carbs, closeTo(56, 0.001));
      expect(d.fat, closeTo(0.6, 0.001));
    });

    test('halving grams halves every macro', () {
      final d = rescaleScannedFood(base, 50);
      expect(d.kcal, closeTo(65, 0.001));
      expect(d.protein, closeTo(1.35, 0.001));
    });

    test('guards unknown original portion (grams 0) — macros unchanged', () {
      const noPortion = ScannedFood(
          name: 'X',
          grams: 0,
          kcal: 130,
          protein: 5,
          carbs: 10,
          fat: 2,
          confidence: 0.5);
      final d = rescaleScannedFood(noPortion, 200);
      expect(d.grams, 200); // label updates
      expect(d.kcal, 130); // but no rate → macros held
      expect(d.protein, 5);
    });

    test('non-positive new grams leaves the food unchanged', () {
      expect(rescaleScannedFood(base, 0), same(base));
      expect(rescaleScannedFood(base, -10), same(base));
    });
  });

  // ─── A2 — DB picker searches curated + IFCT ───────────────────────────────
  group('A2 FoodRepository.searchLocal reaches IFCT-only foods', () {
    test('an IFCT-only food is returned by searchLocal', () {
      FoodRepository.instance.loadFromJsonString(
          '[{"name":"Zzq Ifct Only Dish","kcal":140,"protein":6,"carb":22,"fat":3,"group":"Cereals"}]');
      final res = FoodRepository.instance.searchLocal('zzq ifct only');
      expect(res.any((f) => f.name == 'Zzq Ifct Only Dish' && f.source == 'IFCT'),
          isTrue);
    });
  });

  // ─── A4 — remaining-scans caption tracks remaining() ──────────────────────
  group('A4 ScanQuotaCaption', () {
    Widget host() => const MaterialApp(
          home: Scaffold(body: Center(child: ScanQuotaCaption())),
        );

    testWidgets('caption shows the full daily limit on a fresh day',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      // runAsync lets the real SharedPreferences.getInstance() future resolve
      // (it hops the real event loop, which fake-async pump won't advance).
      await tester.runAsync(() async {
        await tester.pumpWidget(host());
        await SharedPreferences.getInstance();
      });
      await tester.pump();
      expect(find.textContaining('${ScanQuota.dailyLimit} scans left today'),
          findsOneWidget);
    });

    testWidgets('caption tracks remaining() after scans are recorded',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await ScanQuota.record(prefs);
      await ScanQuota.record(prefs);
      await ScanQuota.record(prefs); // 3 used → 7 left
      await tester.runAsync(() async {
        await tester.pumpWidget(host());
        await SharedPreferences.getInstance();
      });
      await tester.pump();
      expect(find.textContaining('${ScanQuota.dailyLimit - 3} scans left today'),
          findsOneWidget);
    });
  });

  // ─── D1 — no owner exemption; everyone shares the same daily cap ───────────
  group('D1 quota applies uniformly (no unlimited owner)', () {
    test('the cap blocks further scans once dailyLimit is reached', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      for (var i = 0; i < ScanQuota.dailyLimit; i++) {
        expect(ScanQuota.canScan(prefs), isTrue);
        await ScanQuota.record(prefs);
      }
      expect(ScanQuota.canScan(prefs), isFalse);
      expect(ScanQuota.remaining(prefs), 0);
    });
  });

  // ─── F — no "999 days since your last workout" for zero-workout users ─────
  group('F never-trained users get no "days since" message', () {
    test('hasEverLoggedWorkout flips with history', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      expect(p.hasEverLoggedWorkout, isFalse);
      expect(p.daysSinceLastWorkout, 999); // sentinel, must never render

      await p.logWorkout(WorkoutLog(
        id: 'w1',
        date: DateTime.now(),
        name: 'A',
        exercises: const [],
      ));
      expect(p.hasEverLoggedWorkout, isTrue);
      expect(p.daysSinceLastWorkout, 0);
    });

    test('insight engine emits no "days since"/"999" for empty history',
        () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      final all = generateInsights(p, DateTime(2026, 5, 31, 10));
      expect(
          all.every((i) =>
              !i.title.contains('days since') && !i.title.contains('999')),
          isTrue);
    });
  });

  // ─── G — goal direction: recommendations, inference, ETA, framing ─────────
  group('G goal direction', () {
    test('inferGoalDirection maps goal vs current weight', () {
      expect(
          FitnessProvider.inferGoalDirection(
              goalWeightKg: 65, currentWeightKg: 75),
          GoalDirection.lose);
      expect(
          FitnessProvider.inferGoalDirection(
              goalWeightKg: 80, currentWeightKg: 70),
          GoalDirection.gain);
      expect(
          FitnessProvider.inferGoalDirection(
              goalWeightKg: 70, currentWeightKg: 70.5),
          GoalDirection.maintain);
      expect(
          FitnessProvider.inferGoalDirection(
              goalWeightKg: 70, currentWeightKg: null),
          GoalDirection.lose);
    });

    test('recommendedCalorieGoal = deficit / maintenance / surplus', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      await p.saveHeight(170);
      await p.saveAge(24);
      await p.logBodyEntry(weightKg: 78.0); // fixes bestTdee at BMR*1.2 = 2073
      final t = p.bestTdee!;

      await p.saveGoalDirection(GoalDirection.lose);
      expect(p.recommendedCalorieGoal!,
          closeTo((t - 500).clamp(1200.0, 2800.0), 0.5));

      await p.saveGoalDirection(GoalDirection.maintain);
      expect(p.recommendedCalorieGoal!, closeTo(t.clamp(1200.0, 3500.0), 0.5));

      await p.saveGoalDirection(GoalDirection.gain);
      expect(p.recommendedCalorieGoal!,
          closeTo((t + 350).clamp(1400.0, 4000.0), 0.5));

      // fatLossCalorieTarget is now just an alias — must agree.
      expect(p.fatLossCalorieTarget, p.recommendedCalorieGoal);
    });

    test('goal_direction persists and reloads', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      await p.saveGoalDirection(GoalDirection.gain);
      final p2 = FitnessProvider();
      await p2.loadData();
      expect(p2.goalDirection, GoalDirection.gain);
      expect(p2.wantsSurplus, isTrue);
    });

    test('weeksToGoal: gain goal with upward trend → ETA, downward → null',
        () async {
      final now = DateTime.now();
      // Upward trend ending ~75, goal 80 → needs +5 kg.
      final up = <(DateTime, double)>[
        for (int ago = 20; ago >= 0; ago -= 4)
          (now.subtract(Duration(days: ago)), 73 + (20 - ago) * 0.1)
      ];
      SharedPreferences.setMockInitialValues(_seedBody(up));
      final pUp = FitnessProvider();
      await pUp.loadData();
      await pUp.saveHeight(170);
      await pUp.saveAge(24);
      await pUp.saveGoalWeight(80);
      await pUp.saveGoalDirection(GoalDirection.gain);
      expect(pUp.kgToGoal, lessThan(0)); // below goal (must gain)
      expect(pUp.weeklyWeightChange!, greaterThan(0.05));
      expect(pUp.weeksToGoal, isNotNull);
      expect(pUp.weeksToGoal!, greaterThan(0));

      // Downward trend while trying to gain → dishonest to project → null.
      final down = <(DateTime, double)>[
        for (int ago = 20; ago >= 0; ago -= 4)
          (now.subtract(Duration(days: ago)), 77 - (20 - ago) * 0.1)
      ];
      SharedPreferences.setMockInitialValues(_seedBody(down));
      final pDown = FitnessProvider();
      await pDown.loadData();
      await pDown.saveHeight(170);
      await pDown.saveAge(24);
      await pDown.saveGoalWeight(80);
      await pDown.saveGoalDirection(GoalDirection.gain);
      expect(pDown.weeklyWeightChange!, lessThan(-0.05));
      expect(pDown.weeksToGoal, isNull);
    });

    test('gain mode never says "over goal — skip the snack"', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      await p.saveHeight(170);
      await p.saveAge(24);
      await p.logBodyEntry(weightKg: 78.0);
      await p.addFoodEntry(_food(p, 2600)); // well over the 1700 default goal

      await p.saveGoalDirection(GoalDirection.gain);
      final gain = generateInsights(p, DateTime(2026, 5, 31, 14));
      expect(gain.any((i) => i.title.contains('over goal')), isFalse);
      expect(
          gain.any((i) => i.body.contains('Skip evening snacks')), isFalse);

      // Sanity: the SAME state DOES warn when cutting.
      await p.saveGoalDirection(GoalDirection.lose);
      final lose = generateInsights(p, DateTime(2026, 5, 31, 14));
      expect(lose.any((i) => i.title.contains('over goal')), isTrue);
    });
  });

  // ─── C — hot-path memoization (correctness) ───────────────────────────────
  group('C memoized merged maps', () {
    test('foodHistory is cached until a mutation, then rebuilt + correct',
        () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      final a = p.foodHistory;
      expect(identical(a, p.foodHistory), isTrue); // same instance, no work

      await p.addFoodEntry(_food(p, 300));
      final b = p.foodHistory;
      expect(identical(a, b), isFalse); // invalidated on mutation
      expect(b.values.expand((e) => e).any((f) => f.calories == 300), isTrue);
    });

    test('waterHistory is cached until a mutation', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      final a = p.waterHistory;
      expect(identical(a, p.waterHistory), isTrue);
      await p.addWater(250);
      expect(identical(a, p.waterHistory), isFalse);
    });
  });

  // ─── Haptics — gated by the enabled flag + provider sync ──────────────────
  group('Haptics', () {
    tearDown(() => Haptics.enabled = true); // never leak a disabled flag

    testWidgets('fires when enabled, silent when disabled', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') calls.add(call);
        return null;
      });

      Haptics.enabled = true;
      Haptics.tap();
      Haptics.selection();
      Haptics.impact();
      await tester.pump();
      expect(calls, hasLength(3));

      calls.clear();
      Haptics.enabled = false;
      Haptics.tap();
      Haptics.selection();
      Haptics.impact();
      Haptics.heavy();
      Haptics.warning();
      Haptics.edge();
      Haptics.success();
      await tester.pump();
      expect(calls, isEmpty);

      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('provider setting toggles the global flag and persists', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      expect(p.hapticsEnabled, isTrue);
      expect(Haptics.enabled, isTrue); // synced on load (default on)

      await p.saveHapticsEnabled(false);
      expect(p.hapticsEnabled, isFalse);
      expect(Haptics.enabled, isFalse);

      // A fresh provider load restores the persisted preference.
      final p2 = FitnessProvider();
      await p2.loadData();
      expect(p2.hapticsEnabled, isFalse);
      expect(Haptics.enabled, isFalse);
    });
  });
}
