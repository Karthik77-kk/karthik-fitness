import '../providers/fitness_provider.dart';

/// Routes a chat message BEFORE it reaches the on-device LLM.
///
/// The 1B on-device model is weak at reciting numbers and tends to dump the
/// injected context even for a plain "hi". So we intercept two cases and answer
/// them deterministically (no model, instant, always-correct):
///   • greetings / thanks / small-talk  -> a short friendly reply
///   • factual lookups ("today's protein", "my TDEE", "weight trend")
///       -> exact numbers straight from the provider getters
/// Anything open-ended ("why am I plateauing", "suggest a plan") returns null
/// from [factualAnswer] and falls through to the LLM for real coaching.
class ChatIntent {
  ChatIntent._();

  static const _mo = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];
  static String _date(DateTime d) => '${d.day} ${_mo[d.month - 1]} ${d.year}';

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9%\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _has(String q, List<String> keys) => keys.any(q.contains);

  // Words that signal the user wants advice/opinion, not a number lookup.
  // When present, we always defer to the LLM (never a canned factual answer).
  static const _coachingWords = [
    'why','should','suggest','recommend','advice','advise','plan','tips','tip',
    'help','motivate','idea','improve','better','how do','how can','how should',
    'what do i','what should','is it ok','do you think','meal','what to eat',
    'what can i eat','workout for','routine',
  ];
  static bool _isCoaching(String q) => _has(q, _coachingWords);

  // ── Greetings ───────────────────────────────────────────────────────────────
  static const _greetingExact = {
    'hi','hii','hiii','hello','helloo','hey','heyy','yo','sup','hola','namaste',
    'namaskara','vanakkam','gm','good morning','good afternoon','good evening',
    'good night','gn','thanks','thank you','thankyou','thx','ty','ok','okay','okk',
    'k','cool','nice','great','awesome','bye','goodbye','good','fine','yo bro',
    'hey there','hi there','hello there','wassup','whatsup',
  };
  static const _greetingFirstWords = {
    'hi','hii','hiii','hello','helloo','hey','heyy','yo','namaste','hola','thanks',
    'thank','thankyou','thx','bye','gm','sup','wassup','whatsup',
  };

  static bool isGreeting(String message) {
    final s = _norm(message);
    if (s.isEmpty) return false;
    if (_greetingExact.contains(s)) return true;
    final words = s.split(' ');
    return words.length <= 3 &&
        _greetingFirstWords.contains(words.first) &&
        !_isCoaching(s) &&
        !_hasAnyFactualTopic(s);
  }

  /// A short, warm reply that invites real questions — and one tiny live stat if
  /// the user has logged anything today (feels alive without a data dump).
  static String greetingReply(FitnessProvider p) {
    final name = p.userName.trim().isEmpty ? 'there' : p.userName.trim();
    final buf = StringBuffer('Hey $name! I\'m your fitness coach. ');
    final cal = p.todayCaloriesTotal.round();
    final prot = p.todayProteinTotal.round();
    if (cal > 0 || prot > 0) {
      buf.write('Today so far: $cal kcal · ${prot}g protein. ');
    }
    buf.write('Ask me things like "what\'s my weight trend", "how much protein '
        'today", or "my TDEE" — or for advice like "why am I plateauing?"');
    return buf.toString();
  }

  // ── Factual topics ───────────────────────────────────────────────────────────
  static bool _hasAnyFactualTopic(String q) =>
      _topicWeight(q) || _topicToday(q) || _topicTdee(q) || _topicTarget(q) ||
      _topicBmi(q) || _topicBodyComp(q) || _topicOneRm(q) || _topicStreak(q) ||
      _topicHabit(q) || _topicMeasure(q) || _topicEta(q);

  static bool _topicWeight(String q) =>
      _has(q, ['weight','how much do i weigh','weigh','kg','heavier','lighter','losing','gaining']);
  static bool _topicToday(String q) =>
      _has(q, ['today','so far','right now']) &&
      _has(q, ['calorie','kcal','protein','water','step','ate','eaten','eat','drink','drank','walk']);
  static bool _topicTdee(String q) => _has(q, ['tdee','maintenance','metabolism','bmr','how many calories do i burn','calories i burn']);
  static bool _topicTarget(String q) => _has(q, ['calorie target','target calorie','deficit','cut target','goal calorie','how many calories should']);
  static bool _topicBmi(String q) => q.contains('bmi');
  static bool _topicBodyComp(String q) => _has(q, ['body fat','bodyfat','fat percent','fat %','muscle','lean','composition','visceral']);
  static bool _topicOneRm(String q) => _has(q, ['1rm','one rep','rep max','my max','strongest','best lift','best lifts','pr ']);
  static bool _topicStreak(String q) => q.contains('streak');
  static bool _topicHabit(String q) => _has(q, ['habit score','consistency score']);
  static bool _topicMeasure(String q) => _has(q, ['waist','chest','arm','thigh','hips','measurement']);
  static bool _topicEta(String q) => _has(q, ['when will i','how long','eta','reach my goal','reach goal','goal date','weeks to','hit my goal']);

  /// Returns an exact, deterministic answer for a factual lookup, or null when
  /// the message is open-ended (coaching) and should go to the LLM.
  static String? factualAnswer(String message, FitnessProvider p) {
    final q = _norm(message);
    if (q.isEmpty || _isCoaching(q)) return null;

    // Order matters: more specific topics first.
    if (_topicEta(q))      return _answerEta(p);
    if (_topicTdee(q))     return _answerTdee(p);
    if (_topicTarget(q))   return _answerTarget(p);
    if (_topicBmi(q))      return _answerBmi(p);
    if (_topicBodyComp(q)) return _answerBodyComp(p);
    if (_topicOneRm(q))    return _answerOneRm(p);
    if (_topicStreak(q))   return _answerStreak(p);
    if (_topicHabit(q))    return _answerHabit(p);
    if (_topicMeasure(q))  return _answerMeasure(p);
    if (_topicToday(q))    return _answerToday(q, p);
    if (_topicWeight(q))   return _answerWeight(p);
    return null;
  }

  static String _answerWeight(FitnessProvider p) {
    final w = p.latestWeightKg;
    if (w == null) {
      return 'You haven\'t logged your weight yet. Add it on the Stats screen and '
          'I\'ll track your trend toward ${p.goalWeightKg.toStringAsFixed(1)}kg.';
    }
    final buf = StringBuffer('You\'re at ${w.toStringAsFixed(1)}kg');
    final kg = p.kgToGoal;
    if (kg != null) {
      if (kg > 0.1) {
        buf.write(', ${kg.toStringAsFixed(1)}kg above your '
            '${p.goalWeightKg.toStringAsFixed(1)}kg goal');
      } else if (kg < -0.1) {
        buf.write(', ${kg.abs().toStringAsFixed(1)}kg below your '
            '${p.goalWeightKg.toStringAsFixed(1)}kg goal');
      } else {
        buf.write(' — right at your goal');
      }
    }
    buf.write('. ');
    final wk = p.weeklyWeightChange;
    if (wk == null) {
      buf.write('Log a few more days and I can show your weekly trend.');
    } else if (wk < -0.05) {
      buf.write('Trend: losing ${wk.abs().toStringAsFixed(2)}kg/week');
      final eta = p.estimatedGoalDate;
      buf.write(eta != null ? ' — on pace for ${_date(eta)}.' : '.');
    } else if (wk > 0.05) {
      buf.write('Trend: gaining ${wk.toStringAsFixed(2)}kg/week.');
    } else {
      buf.write('Trend: holding steady this week.');
    }
    return buf.toString();
  }

  static String _answerToday(String q, FitnessProvider p) {
    final wantCal  = _has(q, ['calorie','kcal','ate','eaten','eat']);
    final wantProt = q.contains('protein');
    final wantWat  = _has(q, ['water','drink','drank']);
    final wantStep = _has(q, ['step','walk']);
    final none = !(wantCal || wantProt || wantWat || wantStep);
    final parts = <String>[];
    if (wantCal  || none) parts.add('${p.todayCaloriesTotal.round()}/${p.calorieGoal} kcal');
    if (wantProt || none) parts.add('${p.todayProteinTotal.round()}/${p.proteinGoal}g protein');
    if (wantWat  || none) parts.add('${p.todayWaterMl}/${p.waterGoalMl} ml water');
    if (wantStep || none) parts.add('${p.todaySteps}/${p.stepGoal} steps');
    return 'Today so far: ${parts.join(' · ')}.';
  }

  static String _answerTdee(FitnessProvider p) {
    final t = p.bestTdee;
    if (t == null) {
      return 'I need your weight, height and age logged first to estimate your '
          'TDEE. Add them on the Stats screen.';
    }
    final cut = p.fatLossCalorieTarget;
    final cal = p.isTdeeCalibrated ? ' (calibrated from your actual data)' : '';
    final tail = cut != null
        ? ' For fat loss, aim for about ${cut.round()} kcal/day.'
        : '';
    return 'Your maintenance (TDEE) is roughly ${t.round()} kcal/day$cal.$tail';
  }

  static String _answerTarget(FitnessProvider p) {
    final cut = p.fatLossCalorieTarget;
    if (cut == null) {
      return 'Log your weight, height and age and I\'ll set a personalised fat-loss '
          'calorie target.';
    }
    return 'Your fat-loss calorie target is about ${cut.round()} kcal/day '
        '(roughly 500 below your maintenance). Your current goal is set to '
        '${p.calorieGoal} kcal.';
  }

  static String _answerBmi(FitnessProvider p) {
    final b = p.bmi;
    if (b == null) {
      return 'Log your weight and height on the Stats screen and I\'ll calculate '
          'your BMI.';
    }
    return 'Your BMI is ${b.toStringAsFixed(1)} (${p.bmiCategory}).';
  }

  static String _answerBodyComp(FitnessProvider p) {
    final sc = p.latestScaleEntry;
    if (sc == null) {
      return 'No smart-scale reading logged yet. Add one and I can show your body '
          'fat, muscle and lean mass.';
    }
    return 'Last scan: ${sc.bodyFatPercent.toStringAsFixed(1)}% body fat · '
        '${sc.muscleMassKg.toStringAsFixed(1)}kg muscle · '
        '${sc.leanBodyMassKg.toStringAsFixed(1)}kg lean mass.';
  }

  static String _answerOneRm(FitnessProvider p) {
    final lifts = p.topLiftsOneRm;
    if (lifts.isEmpty) {
      return 'Log some weighted sets and I\'ll estimate your 1-rep maxes.';
    }
    final top = lifts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final shown = top.take(4)
        .map((e) => '${e.key} ~${e.value.toStringAsFixed(0)}kg')
        .join(' · ');
    return 'Your estimated 1-rep maxes: $shown.';
  }

  static String _answerStreak(FitnessProvider p) {
    return 'Streaks — workout: ${p.workoutStreak}d · calorie goal: '
        '${p.calorieStreak}d · deficit: ${p.deficitStreak}d.';
  }

  static String _answerHabit(FitnessProvider p) {
    return 'Your habit score is ${p.habitScore}/100 — a blend of your calorie, '
        'protein, hydration and training consistency this month.';
  }

  static String _answerMeasure(FitnessProvider p) {
    final m = p.latestMeasurements;
    if (m == null || m.isEmpty) {
      return 'No body measurements logged yet. Add them on the Stats screen.';
    }
    final ps = <String>[];
    if (m.chestCm     != null) ps.add('chest ${m.chestCm!.toStringAsFixed(0)}cm');
    if (m.waistCm     != null) ps.add('waist ${m.waistCm!.toStringAsFixed(0)}cm');
    if (m.hipsCm      != null) ps.add('hips ${m.hipsCm!.toStringAsFixed(0)}cm');
    if (m.neckCm      != null) ps.add('neck ${m.neckCm!.toStringAsFixed(0)}cm');
    if (m.leftArmCm   != null) ps.add('arm ${m.leftArmCm!.toStringAsFixed(0)}cm');
    if (m.leftThighCm != null) ps.add('thigh ${m.leftThighCm!.toStringAsFixed(0)}cm');
    return 'Latest measurements: ${ps.join(' · ')}.';
  }

  static String _answerEta(FitnessProvider p) {
    final eta = p.estimatedGoalDate;
    final wk  = p.weeksToGoal;
    if (eta == null || wk == null) {
      final kg = p.kgToGoal;
      if (kg != null && kg <= 0.1) {
        return 'You\'re already at (or below) your '
            '${p.goalWeightKg.toStringAsFixed(1)}kg goal — nice work.';
      }
      return 'I need a bit more weight history (and a downward trend) to project '
          'your goal date. Keep logging your weight.';
    }
    return 'At your current measured pace you\'ll reach '
        '${p.goalWeightKg.toStringAsFixed(1)}kg in about ${wk.round()} weeks '
        '(around ${_date(eta)}).';
  }
}
