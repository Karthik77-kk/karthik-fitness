// Coverage for the v3.x polish batch:
//   • MeasurementEntry.neckCm serialization + back-compat
//   • navyBodyFatPercent / navyBodyFatStatus (U.S. Navy circumference method)
//   • hasFreshWeightForecast (hide stale/insufficient forecasts)
//   • estimatedGoalDate anchored on the latest weight → consistent with weeksToGoal
//   • ExerciseDatabase.cardioMinutes + isCardio (walking logs as "N min")
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kfit/models/models.dart';
import 'package:kfit/providers/fitness_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Seeds 'body_history' with [(daysAgo, weightKg)] entries so regression-based
/// getters have real dated history (logBodyEntry always stamps DateTime.now()).
Map<String, Object> _seedBody(List<(int, double)> entries) {
  final now = DateTime.now();
  final list = entries.map((e) {
    final d = now.subtract(Duration(days: e.$1));
    return {
      'id': 'b${d.millisecondsSinceEpoch}',
      'date': d.toIso8601String(),
      'weightKg': e.$2,
      'steps': 0,
    };
  }).toList();
  return {'body_history': jsonEncode(list)};
}

Future<FitnessProvider> _provider([Map<String, Object>? extra]) async {
  SharedPreferences.setMockInitialValues({
    'onboarding_done': true,
    'user_name': 'Test',
    ...?extra,
  });
  final p = FitnessProvider();
  await p.loadData();
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── MeasurementEntry.neckCm ────────────────────────────────────────────────
  group('MeasurementEntry neck field', () {
    test('round-trips neckCm through JSON', () {
      final m = MeasurementEntry(
          id: 'x', date: DateTime(2026, 1, 1), neckCm: 38.5, waistCm: 85);
      final j = m.toJson();
      expect(j['neckCm'], 38.5);
      final back = MeasurementEntry.fromJson(j);
      expect(back.neckCm, 38.5);
      expect(back.waistCm, 85);
    });

    test('back-compat: legacy JSON without neckCm decodes to null', () {
      final old = MeasurementEntry.fromJson({
        'id': 'y',
        'date': '2026-01-01T00:00:00.000',
        'waistCm': 80,
      });
      expect(old.neckCm, isNull);
      expect(old.waistCm, 80);
    });

    test('omits neckCm from JSON when null (no "0" pollution)', () {
      final m = MeasurementEntry(id: 'z', date: DateTime(2026, 1, 1), waistCm: 80);
      expect(m.toJson().containsKey('neckCm'), isFalse);
    });

    test('isEmpty accounts for neckCm', () {
      expect(
          MeasurementEntry(id: 'a', date: DateTime(2026, 1, 1), neckCm: 38)
              .isEmpty,
          isFalse);
      expect(
          MeasurementEntry(id: 'b', date: DateTime(2026, 1, 1)).isEmpty, isTrue);
    });
  });

  // ── Navy body-fat % ────────────────────────────────────────────────────────
  group('navyBodyFatPercent', () {
    test('male estimate from neck + waist + height', () async {
      final p = await _provider();
      await p.saveHeight(180);
      await p.saveSex(true);
      await p.logMeasurement(MeasurementEntry(
          id: 'm', date: DateTime.now(), neckCm: 38, waistCm: 85));
      expect(p.navyBodyFatPercent, isNotNull);
      expect(p.navyBodyFatPercent!, closeTo(16.2, 0.8));
      expect(p.navyBodyFatStatus.label, 'Fit');
    });

    test('female estimate needs hips as well', () async {
      final p = await _provider();
      await p.saveHeight(165);
      await p.saveSex(false);
      await p.logMeasurement(MeasurementEntry(
          id: 'm', date: DateTime.now(), neckCm: 34, waistCm: 80, hipsCm: 95));
      expect(p.navyBodyFatPercent!, closeTo(29.0, 0.9));
    });

    test('female returns null without hips', () async {
      final p = await _provider();
      await p.saveHeight(165);
      await p.saveSex(false);
      await p.logMeasurement(MeasurementEntry(
          id: 'm', date: DateTime.now(), neckCm: 34, waistCm: 80));
      expect(p.navyBodyFatPercent, isNull);
    });

    test('null until neck logged', () async {
      final p = await _provider();
      await p.saveHeight(180);
      await p.saveSex(true);
      await p.logMeasurement(
          MeasurementEntry(id: 'm', date: DateTime.now(), waistCm: 85));
      expect(p.navyBodyFatPercent, isNull);
    });

    test('null when neck >= waist (physically impossible)', () async {
      final p = await _provider();
      await p.saveHeight(180);
      await p.saveSex(true);
      await p.logMeasurement(MeasurementEntry(
          id: 'm', date: DateTime.now(), neckCm: 45, waistCm: 40));
      expect(p.navyBodyFatPercent, isNull);
    });

    test('high body fat lands in the High band and stays clamped ≤ 60', () async {
      final p = await _provider();
      await p.saveHeight(175);
      await p.saveSex(true);
      await p.logMeasurement(MeasurementEntry(
          id: 'm', date: DateTime.now(), neckCm: 38, waistCm: 110));
      final bf = p.navyBodyFatPercent!;
      expect(bf, lessThanOrEqualTo(60));
      expect(bf, greaterThan(25));
      expect(p.navyBodyFatStatus.label, 'High');
    });
  });

  // ── Fresh-forecast gate ────────────────────────────────────────────────────
  group('hasFreshWeightForecast', () {
    test('true with 5+ logs and a recent one', () async {
      final p = await _provider(
          _seedBody([(28, 78), (21, 77), (14, 76), (7, 75), (0, 74)]));
      expect(p.hasFreshWeightForecast, isTrue);
    });

    test('false when the newest log is over a month old', () async {
      final p = await _provider(
          _seedBody([(88, 78), (74, 77), (60, 76), (52, 75), (45, 74)]));
      expect(p.hasFreshWeightForecast, isFalse);
    });

    test('false with fewer than 5 logs', () async {
      final p =
          await _provider(_seedBody([(21, 78), (14, 77), (7, 76), (0, 75)]));
      expect(p.hasFreshWeightForecast, isFalse);
    });
  });

  // ── ETA consistency ────────────────────────────────────────────────────────
  group('estimatedGoalDate anchors on latest weight', () {
    test('home ETA agrees with body-screen weeks-to-goal', () async {
      final p = await _provider(
          _seedBody([(56, 78), (42, 77), (28, 76), (14, 75), (0, 74)]));
      await p.saveGoalWeight(70.0);
      await p.saveGoalDirection(GoalDirection.lose);

      expect(p.weeksToGoal, isNotNull);
      expect(p.estimatedGoalDate, isNotNull);
      // -0.5 kg/wk trend, 4 kg to shed ⇒ ~8 weeks ⇒ ~56 days out.
      expect(p.weeksToGoal!, closeTo(8, 0.5));
      final daysOut = p.estimatedGoalDate!.difference(DateTime.now()).inDays;
      expect(daysOut, closeTo(p.weeksToGoal! * 7, 3));
    });

    test('null when the trend moves away from the goal', () async {
      // Gaining weight while trying to lose ⇒ no honest ETA.
      final p = await _provider(
          _seedBody([(56, 72), (42, 73), (28, 74), (14, 75), (0, 76)]));
      await p.saveGoalWeight(70.0);
      await p.saveGoalDirection(GoalDirection.lose);
      expect(p.estimatedGoalDate, isNull);
    });
  });

  // ── Cardio summary ─────────────────────────────────────────────────────────
  group('ExerciseDatabase cardio helpers', () {
    test('cardioMinutes sums the minutes stored in reps', () {
      expect(ExerciseDatabase.cardioMinutes([SetData(reps: 10, weight: 0)]), 10);
      expect(
          ExerciseDatabase.cardioMinutes(
              [SetData(reps: 10, weight: 0), SetData(reps: 5, weight: 0)]),
          15);
      expect(ExerciseDatabase.cardioMinutes(const []), 0);
    });

    test('isCardio classifies by category, not substring', () {
      expect(ExerciseDatabase.isCardio('Walking'), isTrue);
      expect(ExerciseDatabase.isCardio('Running'), isTrue);
      // "Walking Lunges" contains "Walking" but is a leg exercise, not cardio.
      expect(ExerciseDatabase.isCardio('Walking Lunges'), isFalse);
    });
  });
}
