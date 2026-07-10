import 'package:flutter/material.dart';
import '../models/models.dart' show walkCaloriesForMinutes, GoalDirection;
import '../providers/fitness_provider.dart';
import '../theme/app_tokens.dart';

// ─── Palette ─────────────────────────────────────────────────────────────────
// Sourced from the design tokens (no raw hex redeclared here) — kept as short
// local aliases only because they're referenced dozens of times below.
const _kGreen = AppColors.green;
const _kBlue = AppColors.blue;
const _kRed = AppColors.red;
const _kOrange = AppColors.orange;

/// Category — used to keep the top-N insights varied (max one per category).
enum InsightCategory {
  weight,
  prediction,
  nutrition,
  hydration,
  activity,
  workout,
  bodyComp,
  measurements,
  motivation,
}

/// A single ranked, personalized insight.
class Insight {
  final String emoji;
  final String title;
  final String body;
  final Color accent;
  final InsightCategory category;
  final double score; // 0–100, higher = more relevant/urgent

  const Insight({
    required this.emoji,
    required this.title,
    required this.body,
    required this.accent,
    required this.category,
    required this.score,
  });

  IconData get icon {
    switch (category) {
      case InsightCategory.weight:
        return Icons.monitor_weight_rounded;
      case InsightCategory.prediction:
        return Icons.trending_down_rounded;
      case InsightCategory.nutrition:
        return Icons.restaurant_rounded;
      case InsightCategory.hydration:
        return Icons.water_drop_rounded;
      case InsightCategory.activity:
        return Icons.directions_walk_rounded;
      case InsightCategory.workout:
        return Icons.fitness_center_rounded;
      case InsightCategory.bodyComp:
        return Icons.accessibility_new_rounded;
      case InsightCategory.measurements:
        return Icons.straighten_rounded;
      case InsightCategory.motivation:
        return Icons.local_fire_department_rounded;
    }
  }
}

const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
String _fmtDate(DateTime d) => '${d.day} ${_monthNames[d.month - 1]} ${d.year}';

/// Generates every applicable insight, each scored. Pure & deterministic given
/// [p] and [now] — [now] is injectable so time-dependent rules are testable.
List<Insight> generateInsights(FitnessProvider p, DateTime now) {
  final out = <Insight>[];
  final hour = now.hour;
  final weight = p.latestWeightKg;
  final weekly = p.weeklyWeightChange; // kg/week, from linear regression
  final goal = p.calorieGoal;
  final proteinGoal = p.proteinGoal;
  final todayCal = p.todayCaloriesTotal.round();
  final todayProt = p.todayProteinTotal.round();

  // ── Weight: losing too fast (safety — highest priority) ───────────────────
  if (weekly != null && weekly < -0.9) {
    out.add(Insight(
      emoji: '⚠️',
      title: 'Losing too fast (${weekly.abs().toStringAsFixed(2)} kg/wk)',
      body: 'Above the safe ~0.9 kg/week ceiling — faster than this risks muscle '
          'loss. Add 200–300 kcal: 2 extra rotis or a banana + whey shake.',
      accent: _kRed,
      category: InsightCategory.weight,
      score: 96,
    ));
  }

  // ── Predictive: plateau correlated with rising intake ─────────────────────
  if (weekly != null && weekly.abs() < 0.15) {
    final recent = p.avgCaloriesForDays(0, 6);
    final prior = p.avgCaloriesForDays(7, 13);
    if (recent > 0 && prior > 0 && recent > prior + 150) {
      out.add(Insight(
        emoji: '🔎',
        title: 'Fat loss stalled — intake crept up',
        body: 'Your weight is flat and your daily average rose '
            '~${(recent - prior).round()} kcal vs last week. Trim one roti or '
            'rice serving at dinner to restart the deficit.',
        accent: _kOrange,
        category: InsightCategory.prediction,
        score: 86,
      ));
    } else {
      out.add(Insight(
        emoji: '➡️',
        title: 'Weight plateau this week',
        body: 'Within ±0.15 kg/week. Add one more workout day or cut '
            '~150 kcal from dinner to break through.',
        accent: _kOrange,
        category: InsightCategory.weight,
        score: 52,
      ));
    }
  }

  // ── Weight: gaining ───────────────────────────────────────────────────────
  if (weekly != null && weekly > 0.25) {
    out.add(Insight(
      emoji: '📈',
      title: 'Trending up ${weekly.toStringAsFixed(2)} kg/wk',
      body: 'Review dinner portions — palm-sized protein, fist-sized carbs, '
          'unlimited sabji. A daily 30-min walk burns ~${_walkBurn(weight)} kcal.',
      accent: _kRed,
      category: InsightCategory.weight,
      score: 83,
    ));
  }

  // ── Weight: healthy loss + projected goal date ────────────────────────────
  if (weekly != null && weekly <= -0.2 && weekly >= -0.9) {
    final eta = p.estimatedGoalDate;
    out.add(Insight(
      emoji: '📉',
      title: 'Healthy loss ${weekly.abs().toStringAsFixed(2)} kg/wk',
      body: eta != null
          ? 'Perfect pace. At this rate you\'ll hit '
              '${p.goalWeightKg.toStringAsFixed(1)} kg by ${_fmtDate(eta)}. '
              'Keep protein above ${proteinGoal}g to protect muscle.'
          : 'Perfect pace — keep protein above ${proteinGoal}g to retain muscle '
              'while the fat comes off.',
      accent: _kGreen,
      category: InsightCategory.prediction,
      score: 58,
    ));
  }

  // ── Measurements: waist down even if scale is flat ────────────────────────
  final measures = p.getRecentMeasurements(days: 60);
  if (measures.length >= 2) {
    final firstWaist = measures.first.waistCm;
    final lastWaist = measures.last.waistCm;
    if (firstWaist != null && lastWaist != null) {
      final delta = lastWaist - firstWaist;
      if (delta <= -1.5) {
        out.add(Insight(
          emoji: '📏',
          title: 'Waist down ${delta.abs().toStringAsFixed(1)} cm',
          body: 'Real fat loss — even if the scale moves slowly, your waist '
              'shrinking means you\'re losing fat and keeping muscle. Stay the course.',
          accent: _kGreen,
          category: InsightCategory.measurements,
          score: 72,
        ));
      }
    }
  }

  // ── Body composition trend from smart scale ───────────────────────────────
  final scales = p.scaleHistory;
  if (scales.length >= 2) {
    final latest = scales.last;
    final prev = scales[scales.length - 2];
    if (latest.visceralFatIndex > 0 && latest.visceralFatIndex >= 13) {
      out.add(Insight(
        emoji: '🫀',
        title: 'Visceral fat is high (${latest.visceralFatIndex})',
        body: 'Index ≥13 raises health risk. Prioritise the deficit and daily '
            'steps — visceral fat responds fast to consistent fat loss.',
        accent: _kRed,
        category: InsightCategory.bodyComp,
        score: 79,
      ));
    }
    if (latest.muscleMassKg > 0 && prev.muscleMassKg > 0 &&
        latest.muscleMassKg < prev.muscleMassKg - 0.4 &&
        weekly != null && weekly < 0) {
      out.add(Insight(
        emoji: '💪',
        title: 'Muscle dipped ${(prev.muscleMassKg - latest.muscleMassKg).toStringAsFixed(1)} kg',
        body: 'You\'re losing some muscle with the fat. Push protein to '
            '${proteinGoal}g+ and keep lifting heavy to hold onto it.',
        accent: _kOrange,
        category: InsightCategory.bodyComp,
        score: 80,
      ));
    }
    if (latest.bodyFatPercent > 0 && prev.bodyFatPercent > 0 &&
        latest.bodyFatPercent < prev.bodyFatPercent - 0.3) {
      out.add(Insight(
        emoji: '🔥',
        title: 'Body fat down ${(prev.bodyFatPercent - latest.bodyFatPercent).toStringAsFixed(1)}%',
        body: 'Your scale shows real fat loss since last reading. Whatever you '
            'did this week — repeat it.',
        accent: _kGreen,
        category: InsightCategory.bodyComp,
        score: 56,
      ));
    }
  }

  // ── Nutrition: over goal today ────────────────────────────────────────────
  // Only a problem when the user is cutting or maintaining — for a gain goal,
  // being over the calorie target is on-plan, so this "skip the snack" nudge is
  // suppressed (see the direction-aware EOD projection below for gain framing).
  if (!p.wantsSurplus && todayCal > goal + 400) {
    out.add(Insight(
      emoji: '🚨',
      title: '${todayCal - goal} kcal over goal',
      body: 'You\'re well above your ${goal} kcal target. Skip evening snacks '
          'and take a 30-min walk (~${_walkBurn(weight)} kcal).',
      accent: _kRed,
      category: InsightCategory.nutrition,
      score: 77,
    ));
  }

  // ── Nutrition: weekday protein habit pattern ──────────────────────────────
  final wdProtein = p.proteinAvgForWeekday(now.weekday);
  if (wdProtein != null && wdProtein < proteinGoal * 0.7 && hour < 17) {
    out.add(Insight(
      emoji: '🍳',
      title: 'You under-eat protein on ${_weekdayNames[now.weekday - 1]}s',
      body: 'Your ${_weekdayNames[now.weekday - 1]} average is only '
          '${wdProtein.round()}g vs your ${proteinGoal}g goal. Plan a whey shake '
          'or paneer/eggs early today to break the pattern.',
      accent: _kBlue,
      category: InsightCategory.nutrition,
      score: 69,
    ));
  }

  // ── Nutrition: protein behind personal pace today ─────────────────────────
  if (hour >= 13 && hour <= 21) {
    final expectedFraction = ((hour - 6) / 16).clamp(0.0, 1.0);
    final expected = proteinGoal * expectedFraction;
    if (todayProt < expected * 0.6) {
      out.add(Insight(
        emoji: '🥩',
        title: 'Protein behind pace today',
        body: 'At $todayProt g, you\'re below the expected ~${expected.round()}g by now. '
            'You need ${(proteinGoal - todayProt).clamp(0, proteinGoal)}g more — '
            'grilled chicken (31g/100g), 3 eggs (18g), or a whey shake (25g).',
        accent: _kBlue,
        category: InsightCategory.nutrition,
        score: 62,
      ));
    }
  }

  // ── Hydration: weekday water habit pattern ────────────────────────────────
  final wdWater = p.waterAvgForWeekday(now.weekday);
  if (wdWater != null && wdWater < p.waterGoalMl * 0.6 && hour >= 10) {
    out.add(Insight(
      emoji: '💧',
      title: 'Hydration dips on ${_weekdayNames[now.weekday - 1]}s',
      body: 'You average only ${wdWater.round()} ml on '
          '${_weekdayNames[now.weekday - 1]}s. Keep a bottle on your desk — '
          'aim for 500 ml before each meal today.',
      accent: _kBlue,
      category: InsightCategory.hydration,
      score: 54,
    ));
  } else if (p.todayWaterMl < p.waterGoalMl * 0.4 && hour >= 14) {
    out.add(Insight(
      emoji: '💧',
      title: 'Water only at ${p.todayWaterMl} ml',
      body: 'Less than halfway to your ${p.waterGoalMl} ml goal. Dehydration '
          'reads as hunger — a 500 ml bottle now curbs evening snacking.',
      accent: _kBlue,
      category: InsightCategory.hydration,
      score: 50,
    ));
  }

  // ── Activity: steps vs personal average ───────────────────────────────────
  final steps = p.todaySteps;
  if (hour >= 12) {
    if (steps > p.stepGoal) {
      out.add(Insight(
        emoji: '🏃',
        title: 'Step goal smashed (${_fmtK(steps)})',
        body: 'Your walking alone burns ~${p.walkingCaloriesBurned.round()} kcal '
            'today. This daily movement is what drives a steady weekly drop.',
        accent: _kGreen,
        category: InsightCategory.activity,
        score: 34,
      ));
    } else if (steps < p.stepGoal * 0.3) {
      final pct = p.stepGoal > 0 ? (steps / p.stepGoal * 100).round() : 0;
      out.add(Insight(
        emoji: '🚶',
        title: '${_fmtK(steps)} steps — only $pct% of your ${_fmtK(p.stepGoal)} goal',
        body: 'A 20-min walk after lunch adds ~2,000 steps and '
            '~${_walkBurn(weight, minutes: 20)} kcal — and lowers blood sugar.',
        accent: _kBlue,
        category: InsightCategory.activity,
        score: 53,
      ));
    }
  }

  // ── Workout: days since last session ──────────────────────────────────────
  // Gate on hasEverLoggedWorkout so a user who has never trained never sees the
  // nonsensical "999 days since your last workout" (daysSinceLastWorkout returns
  // the 999 sentinel when there's no history). Replaces the old magic `< 900`
  // guard. The friendly first-time nudge lives in the notification panel.
  if (p.hasEverLoggedWorkout) {
    final dslw = p.daysSinceLastWorkout;
    if (dslw >= 3) {
      out.add(Insight(
        emoji: '🏋️',
        title: '$dslw days since your last workout',
        body: 'Momentum fades after 3 days off. Even a 20-min session today '
            '(push-ups, squats, plank) keeps the habit and the muscle.',
        accent: _kOrange,
        category: InsightCategory.workout,
        score: 73,
      ));
    } else if (p.workoutStreak >= 7) {
      out.add(Insight(
        emoji: '🔥',
        title: '${p.workoutStreak}-day workout streak!',
        body: 'Top-tier consistency. Past 21 days this becomes identity, not '
            'discipline. Keep the chain unbroken.',
        accent: _kOrange,
        category: InsightCategory.workout,
        score: 42,
      ));
    }
  }

  // ── Workout: weekly frequency low late in week ────────────────────────────
  if (now.weekday >= 5 && p.weeklyWorkoutDays < 3) {
    out.add(Insight(
      emoji: '📅',
      title: 'Only ${p.weeklyWorkoutDays} workouts this week',
      body: 'Aim for 3–4 sessions weekly to retain muscle in a deficit. '
          'You\'ve got the weekend — fit one or two in.',
      accent: _kBlue,
      category: InsightCategory.workout,
      score: 57,
    ));
  }

  // ── Body composition: recomposition trajectory (high-value, predictive) ───
  final traj = p.bodyCompTrajectory;
  if (traj != null) {
    if (traj.fatChange < -0.3 && traj.leanChange > 0.3) {
      out.add(Insight(
        emoji: '🧬',
        title: 'Recomp in progress — textbook',
        body: 'Since your first scan you\'ve dropped '
            '${traj.fatChange.abs().toStringAsFixed(1)} kg fat and gained '
            '${traj.leanChange.toStringAsFixed(1)} kg muscle. This is the ideal '
            'outcome — keep protein high and lifting heavy.',
        accent: _kGreen,
        category: InsightCategory.bodyComp,
        score: 75,
      ));
    } else if (traj.fatChange < -0.3 && traj.leanChange < -0.5) {
      out.add(Insight(
        emoji: '⚠️',
        title: 'Losing muscle with the fat',
        body: 'Down ${traj.fatChange.abs().toStringAsFixed(1)} kg fat but also '
            '${traj.leanChange.abs().toStringAsFixed(1)} kg muscle since your first '
            'scan. Push protein to ${proteinGoal}g+ and add resistance training.',
        accent: _kOrange,
        category: InsightCategory.bodyComp,
        score: 81,
      ));
    }
  }

  // ── Body composition: waist-to-hip / waist-to-height risk ─────────────────
  final whr = p.waistToHipRatio;
  if (whr != null && whr >= 0.95) {
    out.add(Insight(
      emoji: '📐',
      title: 'Waist-to-hip ratio is high (${whr.toStringAsFixed(2)})',
      body: 'Above 0.95 signals central fat and raised health risk. The good '
          'news: belly fat responds fastest to a steady deficit + daily steps.',
      accent: _kRed,
      category: InsightCategory.bodyComp,
      score: 74,
    ));
  } else {
    final whtr = p.waistToHeightRatio;
    if (whtr != null && whtr >= 0.6) {
      out.add(Insight(
        emoji: '📏',
        title: 'Waist is over half your height',
        body: 'Waist-to-height ${whtr.toStringAsFixed(2)} (healthy <0.5). This '
            'predicts metabolic risk better than BMI — keep the deficit going.',
        accent: _kOrange,
        category: InsightCategory.bodyComp,
        score: 66,
      ));
    }
  }

  // ── Body composition: FFMI muscle milestone ───────────────────────────────
  final ffmi = p.ffmi;
  if (ffmi != null && ffmi >= 22 && ffmi < 25) {
    out.add(Insight(
      emoji: '💪',
      title: 'Strong muscle base (FFMI ${ffmi.toStringAsFixed(1)})',
      body: 'Your fat-free mass index is in the athletic range. Hold this muscle '
          'through the cut — it keeps your metabolism high.',
      accent: _kGreen,
      category: InsightCategory.bodyComp,
      score: 38,
    ));
  }

  // ── Body age younger/older than real age ──────────────────────────────────
  final bioDelta = p.bioAgeDelta;
  if (bioDelta != null && bioDelta <= -3) {
    out.add(Insight(
      emoji: '⏳',
      title: 'Body age ${bioDelta.abs()} years younger',
      body: 'Your smart-scale metabolic age is well below your real age — a sign '
          'your training and composition are paying off. Keep it up.',
      accent: _kGreen,
      category: InsightCategory.bodyComp,
      score: 30,
    ));
  } else if (bioDelta != null && bioDelta >= 4) {
    out.add(Insight(
      emoji: '⏳',
      title: 'Body age $bioDelta years older',
      body: 'Your metabolic age reads above your real age. Lowering body fat and '
          'building muscle is the fastest way to bring it down.',
      accent: _kOrange,
      category: InsightCategory.bodyComp,
      score: 60,
    ));
  }

  // ── Hydration from smart scale body-water % ───────────────────────────────
  final hyd = p.hydrationStatus;
  if (hyd != null && hyd.label == 'Low' && hour >= 10) {
    out.add(Insight(
      emoji: '💧',
      title: 'Body water is low',
      body: 'Your last scan showed below-healthy body water. Front-load fluids '
          'today — aim for 500 ml before each meal.',
      accent: _kBlue,
      category: InsightCategory.hydration,
      score: 51,
    ));
  }

  // ── Predictive: end-of-day calorie projection ─────────────────────────────
  // Direction-aware: for a LOSE goal, finishing over the target is the problem;
  // for a GAIN goal it's the reverse (finishing under means too little to grow);
  // for MAINTAIN, drifting far off the target either way is the nudge.
  final eodCal = p.projectedEodCalories;
  if (eodCal != null) {
    final over = eodCal - goal; // +ve = projected over the goal
    switch (p.goalDirection) {
      case GoalDirection.gain:
        if (over < -200 && now.hour >= 15) {
          out.add(Insight(
            emoji: '🔮',
            title: 'On track to finish ~${eodCal.round()} kcal',
            body: 'At your usual ${_weekdayNames[now.weekday - 1]} pace you\'ll '
                'end ~${(-over).round()} kcal under your ${goal} goal — too '
                'light to build. Add a calorie-dense snack (nuts, peanut butter, '
                'a shake) to reach your surplus.',
            accent: _kOrange,
            category: InsightCategory.prediction,
            score: 64,
          ));
        }
      case GoalDirection.maintain:
        if (over.abs() > 300) {
          out.add(Insight(
            emoji: '🔮',
            title: 'On track to finish ~${eodCal.round()} kcal',
            body: over > 0
                ? 'That\'s ~${over.round()} kcal over your ${goal} maintenance '
                    'goal. Ease off at dinner or add a short walk to stay level.'
                : 'That\'s ~${(-over).round()} kcal under your ${goal} '
                    'maintenance goal. A balanced dinner keeps your energy steady.',
            accent: _kBlue,
            category: InsightCategory.prediction,
            score: 60,
          ));
        }
      case GoalDirection.lose:
        if (over > 200) {
          out.add(Insight(
            emoji: '🔮',
            title: 'On track to finish ~${eodCal.round()} kcal',
            body: 'At your usual ${_weekdayNames[now.weekday - 1]} pace you\'ll '
                'end ~${over.round()} kcal over your ${goal} goal. Skip the '
                'evening snack or take a 30-min walk to land on target.',
            accent: _kOrange,
            category: InsightCategory.prediction,
            score: 64,
          ));
        } else if (eodCal < goal - 350 && now.hour >= 18) {
          out.add(Insight(
            emoji: '🔮',
            title: 'Heading for only ~${eodCal.round()} kcal',
            body: 'You\'re projected to finish well under your ${goal} goal — '
                'under-eating stalls fat loss and costs muscle. A balanced dinner '
                'with protein keeps the deficit sustainable.',
            accent: _kBlue,
            category: InsightCategory.prediction,
            score: 60,
          ));
        }
    }
  }

  // ── Predictive: end-of-day protein projection ─────────────────────────────
  final eodProt = p.projectedEodProtein;
  if (eodProt != null && eodProt < proteinGoal * 0.8 && hour >= 13) {
    out.add(Insight(
      emoji: '🎯',
      title: 'Projected to miss protein (~${eodProt.round()}g)',
      body: 'At today\'s pace you\'ll finish around ${eodProt.round()}g vs your '
          '${proteinGoal}g goal. A whey shake (25g) or paneer/eggs now closes the gap.',
      accent: _kBlue,
      category: InsightCategory.nutrition,
      score: 63,
    ));
  }

  // ── Behaviour pattern: weekend overeating ─────────────────────────────────
  if (p.overeatsOnWeekends && (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday)) {
    out.add(Insight(
      emoji: '📊',
      title: 'Weekends are your weak spot',
      body: 'Your data shows you eat noticeably more on weekends. Plan today\'s '
          'meals ahead and keep one high-protein, high-volume option ready to '
          'stay in control.',
      accent: _kBlue,
      category: InsightCategory.nutrition,
      score: 59,
    ));
  }

  // ── Habit pattern: late-night eating ──────────────────────────────────────
  if (p.hasLateNightEatingPattern) {
    out.add(Insight(
      emoji: '🌙',
      title: 'Late-night eating is a pattern',
      body: 'Your logs show >25% of your meals happening after 9 PM. Late meals '
          'spike insulin before sleep and hurt fat burn. Front-load calories — '
          'bigger breakfast, smaller dinner.',
      accent: _kBlue,
      category: InsightCategory.nutrition,
      score: 74,
    ));
  }

  // ── Habit pattern: deficit streak ─────────────────────────────────────────
  // Only a win when the user is actually trying to lose — a bulking or
  // maintaining user shouldn't be congratulated for a calorie deficit.
  final defStreak = p.wantsDeficit ? p.deficitStreak : 0;
  if (defStreak >= 7) {
    out.add(Insight(
      emoji: '🏆',
      title: '$defStreak-day deficit streak — elite',
      body: 'You have been under your calorie goal for $defStreak days straight. '
          'This sustained consistency is exactly what drives real fat loss results. '
          'Protect your protein to keep the muscle.',
      accent: _kGreen,
      category: InsightCategory.prediction,
      score: 67,
    ));
  } else if (defStreak >= 3) {
    out.add(Insight(
      emoji: '🎯',
      title: '$defStreak-day deficit — keep it going',
      body: 'You have been in a deficit for $defStreak days. One more consistent '
          'day moves the needle. Tonight: hit protein, skip late snacks.',
      accent: _kGreen,
      category: InsightCategory.prediction,
      score: 44,
    ));
  }

  // ── Habit score card ───────────────────────────────────────────────────────
  final hs = p.habitScore;
  if (hs >= 80) {
    out.add(Insight(
      emoji: '⭐',
      title: 'Habit score $hs/100 — excellent',
      body: 'Calorie control, protein, hydration, and training consistency are '
          'all strong this month. You are building the foundation for lasting change.',
      accent: _kGreen,
      category: InsightCategory.motivation,
      score: 35,
    ));
  } else if (hs >= 50 && hs < 80) {
    out.add(Insight(
      emoji: '📈',
      title: 'Habit score $hs/100 — room to grow',
      body: 'Your overall consistency is moderate. The fastest gains come from '
          'picking the one weakest category and fixing it this week.',
      accent: _kOrange,
      category: InsightCategory.motivation,
      score: 28,
    ));
  }

  // ── Calorie adherence is low ───────────────────────────────────────────────
  final calAdh = p.calorieAdherenceRate;
  // Guard: only fire if there is recent calorie history (avgCalories > 0 = logged data exists).
  if (p.avgCaloriesForDays(1, 30) > 0 && calAdh < 0.45) {
    out.add(Insight(
      emoji: '📋',
      title: 'Calorie goal missed ${((1 - calAdh) * 100).round()}% of days',
      body: 'You are only hitting your ${p.calorieGoal} kcal target about '
          '${(calAdh * 100).round()}% of days. Log every meal — even estimating '
          'keeps you 30% more consistent than not logging.',
      accent: _kOrange,
      category: InsightCategory.nutrition,
      score: 72,
    ));
  }

  // ── Protein adherence is low ───────────────────────────────────────────────
  final protAdh = p.proteinAdherenceRate;
  if (p.avgProteinForDays(1, 30) > 0 && protAdh < 0.4) {
    out.add(Insight(
      emoji: '🥩',
      title: 'Protein goal missed most days',
      body: 'You hit ${p.proteinGoal}g+ on only ${(protAdh * 100).round()}% of '
          'logged days. Low protein while in a deficit accelerates muscle loss. '
          'Add whey or eggs to breakfast — it is the easiest protein win.',
      accent: _kOrange,
      category: InsightCategory.nutrition,
      score: 76,
    ));
  }

  // ── Goal-pace coaching (uses the trend-based ETA) ─────────────────────────
  final eta = p.estimatedGoalDate;
  final wk = p.weeksToGoal;
  if (eta != null && wk != null && weekly != null && weekly < -0.1) {
    out.add(Insight(
      emoji: '🧭',
      title: 'On pace — goal in ~${wk.round()} weeks',
      body: 'At your real measured trend you\'ll reach '
          '${p.goalWeightKg.toStringAsFixed(1)} kg by ${_fmtDate(eta)}. '
          'Hold protein and consistency and this stays on track.',
      accent: _kGreen,
      category: InsightCategory.prediction,
      score: 48,
    ));
  }

  // ── Motivation / positive default ─────────────────────────────────────────
  if (p.calorieStreak >= 3 && p.workoutStreak >= 3) {
    out.add(Insight(
      emoji: '✅',
      title: 'You\'re dialled in today',
      body: '${p.calorieStreak}-day diet + ${p.workoutStreak}-day workout streak. '
          'Fat loss is 90% showing up — and you are.',
      accent: _kGreen,
      category: InsightCategory.motivation,
      score: 26,
    ));
  }

  // Always-present fallback so topInsight never fails.
  out.add(Insight(
    emoji: '💡',
    title: 'Stay consistent',
    body: 'Hit ${goal} kcal, ${proteinGoal}g protein and '
        '${p.waterGoalMl} ml water daily. Results compound over 90 days.',
    accent: _kGreen,
    category: InsightCategory.motivation,
    score: 5,
  ));

  return out;
}

/// Top [count] insights, sorted by score and de-duplicated by category so the
/// surfaced set is varied. If fewer distinct categories apply, fills the rest
/// with the next-highest-scored regardless of category.
List<Insight> topInsights(FitnessProvider p, DateTime now, {int count = 3}) {
  final all = generateInsights(p, now)
    ..sort((a, b) => b.score.compareTo(a.score));
  final picked = <Insight>[];
  final usedCategories = <InsightCategory>{};
  for (final ins in all) {
    if (picked.length >= count) break;
    if (usedCategories.add(ins.category)) picked.add(ins);
  }
  if (picked.length < count) {
    for (final ins in all) {
      if (picked.length >= count) break;
      if (!picked.contains(ins)) picked.add(ins);
    }
  }
  return picked;
}

/// Single highest-priority insight (used by the home-screen widget).
Insight topInsight(FitnessProvider p, DateTime now) =>
    topInsights(p, now, count: 1).first;

// ── helpers ──────────────────────────────────────────────────────────────────
// Delegates to the shared walk-burn helper so the AI-coach copy and the
// notification center always agree (single source of truth in models.dart).
int _walkBurn(double? weightKg, {int minutes = 30}) =>
    walkCaloriesForMinutes(weightKg, minutes: minutes);

String _fmtK(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k' : '$n';
