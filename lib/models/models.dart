enum MealType { breakfast, lunch, dinner, snack }

enum WorkoutType { a, b, custom }

/// The user's overall body-weight objective. Drives the calorie recommendation
/// (deficit / maintenance / surplus) and flips the coaching copy in the insight
/// engine + notifications, which historically assumed fat loss everywhere.
enum GoalDirection { lose, maintain, gain }

/// Parse a persisted [GoalDirection] name back to the enum, tolerating unknown /
/// missing values by falling back to [fallback].
GoalDirection goalDirectionFromName(String? name,
    {GoalDirection fallback = GoalDirection.lose}) {
  for (final d in GoalDirection.values) {
    if (d.name == name) return d;
  }
  return fallback;
}

/// Preset exercises for Workout A (Push) and Workout B (Pull + Legs).
/// WorkoutType.custom is NOT included — it uses a user-selected list.
const Map<WorkoutType, List<String>> kWorkoutExercises = {
  WorkoutType.a: [
    'Push-ups',
    'Bench Press',
    'Incline Press',
    'Shoulder Press',
    'Tricep Dips',
    'Squats',
  ],
  WorkoutType.b: [
    'Pull-ups',
    'Bent-over Rows',
    'Lat Pulldown',
    'Bicep Curls',
    'Romanian Deadlift',
    'Lunges',
  ],
};

/// Estimates calories burned from a resistance-training session.
/// Uses MET ≈ 5 for weight training (moderate effort).
int estimateCaloriesBurned(double weightKg, int durationMinutes) {
  const met = 5.0;
  return (met * weightKg * durationMinutes / 60).round();
}

/// MET for normal walking. SINGLE SOURCE OF TRUTH for the "an X-min walk burns
/// ~Y kcal" copy shown by both the AI-coach insight engine and the in-app
/// notification center, so the two can never disagree (they previously used
/// 3.5 vs 5.0 and contradicted each other). Matches the provider's exercise
/// MET table ('Walking': 3.5).
const double kWalkingMet = 3.5;

/// Calories burned walking for [minutes] at body weight [weightKg]
/// (MET × kg × hours). Falls back to a 70 kg reference when weight is unknown.
int walkCaloriesForMinutes(double? weightKg, {int minutes = 30}) =>
    (kWalkingMet * (weightKg ?? 70.0) * minutes / 60.0).round();

// ─── Food Entry ───────────────────────────────────────────────────────────────

class FoodEntry {
  final String id;
  final String name;
  final double calories;
  final double protein;
  final double carbs; // grams (0 = unknown / legacy entry)
  final double fat;   // grams (0 = unknown / legacy entry)
  final MealType mealType;
  final DateTime timestamp;
  final String servingNote; // e.g. "2× 1 roti (~40g)" or "custom entry"
  /// True when [carbs]/[fat] are REAL data from the entry's source — even when
  /// both are genuinely zero (black coffee, egg whites). False = unknown, so
  /// display falls back to the 65/35 estimate. Legacy entries without the flag
  /// infer it from the old "0 = unknown" convention.
  final bool macrosKnown;

  FoodEntry({
    required this.id,
    required this.name,
    required this.calories,
    required this.protein,
    this.carbs = 0,
    this.fat = 0,
    required this.mealType,
    required this.timestamp,
    this.servingNote = '',
    bool? macrosKnown,
  }) : macrosKnown = macrosKnown ?? (carbs > 0 || fat > 0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'calories': calories,
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
        'mealType': mealType.index,
        'timestamp': timestamp.toIso8601String(),
        'servingNote': servingNote,
        'macrosKnown': macrosKnown,
      };

  /// Whether this entry carries real (non-estimated) carb/fat macros.
  bool get hasRealMacros => macrosKnown;

  /// Carbs grams for this entry — the real value when known, else the
  /// Indian-diet 65/35 split estimate of this entry's non-protein calories.
  double get effectiveCarbs {
    if (hasRealMacros) return carbs;
    final remaining = (calories - protein * 4.0).clamp(0.0, double.infinity);
    return (remaining * 0.65) / 4.0;
  }

  /// Fat grams for this entry — the real value when known, else the
  /// Indian-diet 65/35 split estimate of this entry's non-protein calories.
  double get effectiveFat {
    if (hasRealMacros) return fat;
    final remaining = (calories - protein * 4.0).clamp(0.0, double.infinity);
    return (remaining * 0.35) / 9.0;
  }

  factory FoodEntry.fromJson(Map<String, dynamic> j) {
    final mealIdx = (j['mealType'] as int? ?? 0)
        .clamp(0, MealType.values.length - 1);
    DateTime ts;
    try {
      ts = DateTime.parse(j['timestamp'] as String? ?? '');
    } catch (_) {
      ts = DateTime.now();
    }
    return FoodEntry(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'Unknown',
      calories: ((j['calories'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      protein: ((j['protein'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      carbs: ((j['carbs'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      fat: ((j['fat'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      mealType: MealType.values[mealIdx],
      timestamp: ts,
      servingNote: (j['servingNote'] as String?) ?? '',
      macrosKnown: j['macrosKnown'] as bool?,
    );
  }
}

// ─── Workout ──────────────────────────────────────────────────────────────────

class SetData {
  final int reps;
  final double weight;

  SetData({required this.reps, required this.weight});

  Map<String, dynamic> toJson() => {'reps': reps, 'weight': weight};

  factory SetData.fromJson(Map<String, dynamic> j) => SetData(
        reps: ((j['reps'] as num?) ?? 0).toInt().clamp(0, 9999),
        weight: ((j['weight'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      );
}

class ExerciseLog {
  final String name;
  final List<SetData> sets;

  ExerciseLog({required this.name, required this.sets});

  Map<String, dynamic> toJson() => {
        'name': name,
        'sets': sets.map((s) => s.toJson()).toList(),
      };

  factory ExerciseLog.fromJson(Map<String, dynamic> j) => ExerciseLog(
        name: (j['name'] as String?) ?? '',
        sets: ((j['sets'] as List?) ?? [])
            .map((s) => SetData.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class WorkoutLog {
  final String id;
  final DateTime date;
  final WorkoutType workoutType;
  final String name; // human-readable workout name
  final List<ExerciseLog> exercises;
  final int durationMinutes;
  final int caloriesBurned;

  WorkoutLog({
    required this.id,
    required this.date,
    WorkoutType? workoutType,
    String? name,
    required this.exercises,
    this.durationMinutes = 0,
    this.caloriesBurned = 0,
  })  : workoutType = workoutType ?? WorkoutType.custom,
        name = name ?? _nameForType(workoutType);

  static String _nameForType(WorkoutType? t) {
    if (t == WorkoutType.a) return 'Workout A — Push';
    if (t == WorkoutType.b) return 'Workout B — Pull';
    return 'Custom Workout';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'workoutType': workoutType.index,
        'name': name,
        'exercises': exercises.map((e) => e.toJson()).toList(),
        'durationMinutes': durationMinutes,
        'caloriesBurned': caloriesBurned,
      };

  factory WorkoutLog.fromJson(Map<String, dynamic> j) {
    final wtIdx = ((j['workoutType'] as num?) ?? 2).toInt()
        .clamp(0, WorkoutType.values.length - 1);
    DateTime dt;
    try {
      dt = DateTime.parse(j['date'] as String? ?? '');
    } catch (_) {
      dt = DateTime.now();
    }
    return WorkoutLog(
      id: (j['id'] as String?) ?? '',
      date: dt,
      workoutType: WorkoutType.values[wtIdx],
      name: j['name'] as String?,
      exercises: ((j['exercises'] as List?) ?? [])
          .map((e) => ExerciseLog.fromJson(e as Map<String, dynamic>))
          .toList(),
      durationMinutes: (j['durationMinutes'] as int?) ?? 0,
      caloriesBurned: (j['caloriesBurned'] as int?) ?? 0,
    );
  }
}

// ─── Body Entry ───────────────────────────────────────────────────────────────

class BodyEntry {
  final String id;
  final DateTime date;
  final double weightKg;
  final int steps;

  BodyEntry({
    required this.id,
    required this.date,
    required this.weightKg,
    this.steps = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'weightKg': weightKg,
        'steps': steps,
      };

  factory BodyEntry.fromJson(Map<String, dynamic> j) {
    DateTime dt;
    try {
      dt = DateTime.parse(j['date'] as String? ?? '');
    } catch (_) {
      dt = DateTime.now();
    }
    return BodyEntry(
      id: (j['id'] as String?) ?? '',
      date: dt,
      weightKg: ((j['weightKg'] as num?) ?? 0).toDouble().clamp(0, double.infinity),
      steps: (j['steps'] as int?) ?? 0,
    );
  }
}

// ─── App Notification (in-app notification center) ────────────────────────────

class AppNotification {
  final String id;
  final String emoji;
  final String title;
  final String body;
  final int accent; // ARGB color value
  final String category;
  final DateTime timestamp;
  bool read;
  /// Optional insight category name (used by notification tiles to show a
  /// Material icon instead of the emoji string). Not persisted.
  final String? insightCategory;

  AppNotification({
    required this.id,
    required this.emoji,
    required this.title,
    required this.body,
    required this.accent,
    required this.category,
    required this.timestamp,
    this.read = false,
    this.insightCategory,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'emoji': emoji,
        'title': title,
        'body': body,
        'accent': accent,
        'category': category,
        'timestamp': timestamp.toIso8601String(),
        'read': read,
      };

  factory AppNotification.fromJson(Map<String, dynamic> j) {
    DateTime ts;
    try {
      ts = DateTime.parse(j['timestamp'] as String? ?? '');
    } catch (_) {
      ts = DateTime.now();
    }
    return AppNotification(
      id: (j['id'] as String?) ?? '',
      emoji: (j['emoji'] as String?) ?? '🔔',
      title: (j['title'] as String?) ?? '',
      body: (j['body'] as String?) ?? '',
      accent: (j['accent'] as int?) ?? 0xFF30D158,
      category: (j['category'] as String?) ?? 'general',
      timestamp: ts,
      read: (j['read'] as bool?) ?? false,
    );
  }
}

// ─── Measurement Entry ────────────────────────────────────────────────────────

class MeasurementEntry {
  final String id;
  final DateTime date;
  final double? chestCm;
  final double? waistCm;
  final double? hipsCm;
  final double? neckCm;
  final double? leftArmCm;
  final double? leftThighCm;

  MeasurementEntry({
    required this.id,
    required this.date,
    this.chestCm,
    this.waistCm,
    this.hipsCm,
    this.neckCm,
    this.leftArmCm,
    this.leftThighCm,
  });

  bool get isEmpty =>
      chestCm == null && waistCm == null && hipsCm == null &&
      neckCm == null && leftArmCm == null && leftThighCm == null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    if (chestCm != null) 'chestCm': chestCm,
    if (waistCm != null) 'waistCm': waistCm,
    if (hipsCm != null) 'hipsCm': hipsCm,
    if (neckCm != null) 'neckCm': neckCm,
    if (leftArmCm != null) 'leftArmCm': leftArmCm,
    if (leftThighCm != null) 'leftThighCm': leftThighCm,
  };

  factory MeasurementEntry.fromJson(Map<String, dynamic> j) {
    DateTime dt;
    try {
      dt = DateTime.parse(j['date'] as String? ?? '');
    } catch (_) {
      dt = DateTime.now();
    }
    return MeasurementEntry(
      id: (j['id'] as String?) ?? '',
      date: dt,
      chestCm: j['chestCm'] != null ? (j['chestCm'] as num).toDouble() : null,
      waistCm: j['waistCm'] != null ? (j['waistCm'] as num).toDouble() : null,
      hipsCm: j['hipsCm'] != null ? (j['hipsCm'] as num).toDouble() : null,
      neckCm: j['neckCm'] != null ? (j['neckCm'] as num).toDouble() : null,
      leftArmCm: j['leftArmCm'] != null ? (j['leftArmCm'] as num).toDouble() : null,
      leftThighCm: j['leftThighCm'] != null ? (j['leftThighCm'] as num).toDouble() : null,
    );
  }
}

// ─── Supplements ─────────────────────────────────────────────────────────────

class SupplementStatus {
  bool whey;
  bool creatine;
  bool multivitamin;

  SupplementStatus({
    this.whey = false,
    this.creatine = false,
    this.multivitamin = false,
  });

  int get takenCount => [whey, creatine, multivitamin].where((b) => b).length;

  Map<String, dynamic> toJson() => {
        'whey': whey,
        'creatine': creatine,
        'multivitamin': multivitamin,
      };

  factory SupplementStatus.fromJson(Map<String, dynamic> j) => SupplementStatus(
        whey: j['whey'] ?? false,
        creatine: j['creatine'] ?? false,
        multivitamin: j['multivitamin'] ?? false,
      );
}

// ── Exercise Database ──────────────────────────────────────────────────────
class ExerciseDatabase {
  static const Map<String, List<String>> categories = {
    'Chest': [
      'Push-ups', 'Bench Press', 'Incline Bench Press', 'Decline Bench Press',
      'Dumbbell Flyes', 'Incline Dumbbell Flyes', 'Cable Crossover',
      'Chest Dips', 'Pec Deck', 'Close-Grip Push-ups', 'Wide Push-ups',
      'Diamond Push-ups', 'Pike Push-ups', 'Chest Press Machine',
    ],
    'Back': [
      'Pull-ups', 'Chin-ups', 'Barbell Rows', 'Dumbbell Rows',
      'Lat Pulldown', 'Seated Cable Row', 'T-Bar Row', 'Face Pulls',
      'Single-Arm Dumbbell Row', 'Chest-Supported Row', 'Pendlay Row',
      'Rack Pulls', 'Good Mornings', 'Hyperextensions',
    ],
    'Shoulders': [
      'Overhead Press', 'Dumbbell Shoulder Press', 'Arnold Press',
      'Lateral Raises', 'Front Raises', 'Rear Delt Flyes',
      'Upright Rows', 'Shrugs', 'Cable Lateral Raises',
      'Face Pulls', 'Machine Shoulder Press', 'Bradford Press',
    ],
    'Biceps': [
      'Barbell Curls', 'Dumbbell Curls', 'Hammer Curls',
      'Cable Curls', 'Preacher Curls', 'Concentration Curls',
      'Incline Dumbbell Curls', 'Cross-Body Hammer Curls',
      'Reverse Curls', 'Zottman Curls', 'Machine Curls',
    ],
    'Triceps': [
      'Tricep Pushdowns', 'Skull Crushers', 'Overhead Tricep Extension',
      'Close-Grip Bench Press', 'Tricep Dips', 'Diamond Push-ups',
      'Kickbacks', 'Cable Overhead Extension', 'Machine Tricep Press',
    ],
    'Legs': [
      'Squats', 'Front Squats', 'Goblet Squats', 'Leg Press',
      'Leg Extensions', 'Leg Curls', 'Romanian Deadlift',
      'Stiff-Leg Deadlift', 'Hack Squats', 'Bulgarian Split Squats',
      'Walking Lunges', 'Reverse Lunges', 'Step-ups',
      'Calf Raises', 'Seated Calf Raises', 'Hip Thrusts',
      'Glute Bridges', 'Sumo Squats', 'Box Squats',
      'Wall Sit', 'Sissy Squats',
    ],
    'Core': [
      'Plank', 'Side Plank', 'Crunches', 'Bicycle Crunches',
      'Russian Twists', 'Leg Raises', 'Hanging Leg Raises',
      'Cable Crunches', 'Ab Wheel Rollout', 'Mountain Climbers',
      'Flutter Kicks', 'Sit-ups', 'Dead Bug', 'Hollow Body Hold',
      'V-ups', 'Dragon Flags',
    ],
    'Full Body / Compound': [
      'Deadlift', 'Power Clean', 'Kettlebell Swings', 'Box Jumps',
      'Battle Ropes', "Farmer's Walk", 'Clean and Press',
      'Thrusters', 'Turkish Get-up', 'Sled Push', 'Bear Crawl',
    ],
    'Cardio': [
      'Running', 'Walking', 'Cycling', 'Jump Rope',
      'Swimming', 'HIIT', 'Burpees', 'Jumping Jacks',
      'Stair Climbing', 'Rowing Machine', 'Elliptical',
      'Sprints', 'High Knees', 'Jump Squats',
    ],
    'Forearms / Grip': [
      'Wrist Curls', 'Reverse Wrist Curls', "Farmer's Walk",
      'Dead Hangs', 'Plate Pinches', 'Towel Pull-ups',
    ],
  };

  static List<String> get allExercises =>
      // toSet() de-dupes exercises that live in two categories (e.g. Diamond
      // Push-ups in Chest + Triceps) so the "all" grid has no duplicates.
      categories.values.expand((e) => e).toSet().toList()..sort();

  static String? categoryOf(String exercise) {
    for (final entry in categories.entries) {
      if (entry.value.contains(exercise)) return entry.key;
    }
    return null;
  }

  /// Cardio exercises are logged by DURATION (minutes), not sets×reps×weight.
  /// Their calorie burn is MET × bodyweight × minutes — a sets/reps model is
  /// meaningless for running, cycling, etc. Minutes are stored in SetData.reps.
  static bool isCardio(String exercise) => categoryOf(exercise) == 'Cardio';

  /// Total minutes logged for a cardio exercise. Cardio stores its duration in
  /// [SetData.reps] (weight 0), so summaries read "N min" instead of a
  /// meaningless "1 set × N reps". Sums across sets when logged repeatedly.
  static int cardioMinutes(List<SetData> sets) =>
      sets.fold<int>(0, (t, s) => t + s.reps);

  static const Map<String, (String primary, String secondary, String tip)>
      _exerciseInfo = {
    // ── Chest ──────────────────────────────────────────────────────────────
    'Bench Press': (
      'Chest',
      'Triceps · Shoulders',
      'Lie flat, grip just wider than shoulders, lower to mid-chest, drive up.',
    ),
    'Incline Bench Press': (
      'Upper Chest',
      'Triceps · Shoulders',
      'Set bench to 30–45°, press the bar up and slightly back, control descent.',
    ),
    'Dumbbell Flyes': (
      'Chest',
      'Shoulders',
      'Slight bend in elbows, lower in wide arc to chest height, squeeze up.',
    ),
    'Chest Dips': (
      'Chest',
      'Triceps · Shoulders',
      'Lean forward slightly, elbows flared out, lower until chest dips below bar level.',
    ),
    // ── Back ───────────────────────────────────────────────────────────────
    'Pull-ups': (
      'Back',
      'Biceps',
      'Dead hang, pull chest to bar, control the descent.',
    ),
    'Barbell Rows': (
      'Back',
      'Biceps',
      'Hinge ~45°, flat back, pull to lower ribs, squeeze shoulder blades.',
    ),
    'Lat Pulldown': (
      'Back',
      'Biceps',
      'Pull bar to upper chest, elbows drive down and back, avoid swinging.',
    ),
    'Face Pulls': (
      'Rear Delts',
      'Traps · Rotator Cuff',
      'Cable at head height, pull to face with elbows flared high, external rotation at end.',
    ),
    // ── Shoulders ──────────────────────────────────────────────────────────
    'Overhead Press': (
      'Shoulders',
      'Triceps',
      'Brace, press straight overhead, squeeze glutes, bar finishes over ears.',
    ),
    'Dumbbell Shoulder Press': (
      'Shoulders',
      'Triceps',
      'Dumbbells at ear level, press overhead, avoid arching lower back excessively.',
    ),
    'Arnold Press': (
      'Shoulders',
      'Triceps',
      'Start palms facing you, rotate outward as you press overhead, reverse on way down.',
    ),
    'Lateral Raises': (
      'Side Delts',
      '',
      'Slight elbow bend, raise to shoulder height, lead with elbows, lower slowly.',
    ),
    // ── Biceps ─────────────────────────────────────────────────────────────
    'Barbell Curls': (
      'Biceps',
      '',
      'Elbows pinned to sides, curl up, no swinging, lower slowly.',
    ),
    'Hammer Curls': (
      'Biceps · Brachialis',
      '',
      'Neutral grip (thumbs up), curl without rotating wrist, control descent.',
    ),
    // ── Triceps ────────────────────────────────────────────────────────────
    'Tricep Pushdowns': (
      'Triceps',
      '',
      'Elbows at sides, push bar down to full extension, squeeze at bottom, control up.',
    ),
    'Skull Crushers': (
      'Triceps',
      '',
      'Lower bar to forehead by bending elbows only, elbows stay vertical, press back up.',
    ),
    'Close-Grip Bench Press': (
      'Triceps',
      'Chest · Shoulders',
      'Grip slightly narrower than shoulder width, elbows tucked, lower to lower chest.',
    ),
    // ── Legs ───────────────────────────────────────────────────────────────
    'Squats': (
      'Quads · Glutes',
      'Hamstrings · Core',
      'Bar on traps, brace core, knees track over toes, hips to ~parallel.',
    ),
    'Deadlift': (
      'Back · Glutes',
      'Hamstrings · Core',
      'Bar over mid-foot, flat back, push the floor away, lock out tall.',
    ),
    'Romanian Deadlift': (
      'Hamstrings · Glutes',
      'Back',
      'Soft knees, push hips back, feel the hamstring stretch, stand tall.',
    ),
    'Leg Press': (
      'Quads · Glutes',
      'Hamstrings',
      'Feet shoulder-width, lower until knees at 90°, press through heels, never lock out fully.',
    ),
    'Leg Extensions': (
      'Quads',
      '',
      'Sit upright, extend fully, hold 1 s at top, lower slowly — avoid swinging.',
    ),
    'Leg Curls': (
      'Hamstrings',
      '',
      'Curl heels to glutes, pause briefly at top, control the eccentric phase.',
    ),
    'Bulgarian Split Squats': (
      'Quads · Glutes',
      'Hamstrings · Core',
      'Rear foot elevated, front shin vertical, lower rear knee toward floor, drive up through heel.',
    ),
    'Walking Lunges': (
      'Quads · Glutes',
      'Hamstrings · Core',
      'Step forward, lower back knee toward floor, push off front foot, keep torso upright.',
    ),
    'Calf Raises': (
      'Calves',
      '',
      'Full range of motion — press up high on toes, lower heel below platform level.',
    ),
    'Hip Thrusts': (
      'Glutes',
      'Hamstrings',
      'Bar across hips, shoulders on bench, drive hips up to full extension, squeeze glutes at top.',
    ),
    // ── Core ───────────────────────────────────────────────────────────────
    'Plank': (
      'Core',
      'Shoulders · Glutes',
      'Neutral spine, brace abs as if bracing for a punch, breathe normally, hips level.',
    ),
    'Crunches': (
      'Abs',
      '',
      'Feet flat, curl shoulders off floor only, exhale at top — no neck pulling.',
    ),
    'Russian Twists': (
      'Obliques',
      'Abs',
      'Lean back ~45°, feet off floor, rotate from torso not arms, control the twist.',
    ),
    'Hanging Leg Raises': (
      'Lower Abs',
      'Hip Flexors',
      'Dead hang, raise straight legs to 90°, avoid swinging, lower with control.',
    ),
    // ── Cardio ─────────────────────────────────────────────────────────────
    'Running': (
      'Cardiovascular',
      'Legs · Core',
      'Land midfoot, slight forward lean, arms at 90°, breathe rhythmically.',
    ),
    'Cycling': (
      'Cardiovascular',
      'Quads · Glutes',
      'Seat height lets knee reach slight bend at bottom, smooth pedal circles.',
    ),
    'Jump Rope': (
      'Cardiovascular',
      'Calves · Shoulders',
      'Jump low (1–2 cm clearance), stay on balls of feet, elbows tucked in.',
    ),
    'Burpees': (
      'Full Body',
      'Cardiovascular',
      'Explosive jump up, soft landing, keep core tight throughout the movement.',
    ),
  };

  /// Returns (primary, secondary, tip) info if known, else null.
  static (String primary, String secondary, String tip)? infoFor(String name) =>
      _exerciseInfo[name];

  /// Suggest next session weight/reps based on completed performance.
  /// Returns a string like "+2.5 kg next session" or "Add 1 more rep"
  static String progressiveOverloadTip(
      String exercise, int setsCompleted, int repsCompleted, double weight, int targetReps) {
    if (repsCompleted >= targetReps) {
      final isBodyweight = weight == 0;
      if (isBodyweight) return 'Add 1 more rep or try weighted variant next session';
      final increment = weight >= 20 ? 2.5 : 1.0;
      return 'Great! Try ${weight + increment} kg next session 💪';
    } else if (repsCompleted >= targetReps - 2) {
      return 'Close! Stick with ${weight > 0 ? '${weight.toStringAsFixed(1)} kg' : 'same difficulty'} and aim for $targetReps reps';
    } else {
      return 'Focus on form. Same weight next session.';
    }
  }
}

// ─── Food database (Indian + common foods) ───────────────────────────────────

class FoodItem {
  final String name;
  final double calories; // per default serving
  final double protein;  // grams per default serving
  final double carbs;    // grams per default serving (0 = unknown, falls back to estimate)
  final double fat;      // grams per default serving (0 = unknown, falls back to estimate)
  final String category;
  final String emoji;
  final String serving;  // human-readable serving description
  final String source;   // 'curated' (default) | 'IFCT' — provenance for ranking
  /// True when [carbs]/[fat] are real data even if zero (e.g. IFCT lab values).
  /// Defaults to the legacy "0 = unknown" heuristic for curated items.
  final bool macrosKnown;

  const FoodItem({
    required this.name,
    required this.calories,
    required this.protein,
    this.carbs = 0,
    this.fat = 0,
    required this.category,
    required this.emoji,
    this.serving = '1 serving',
    this.source = 'curated',
    bool? macrosKnown,
  }) : macrosKnown = macrosKnown ?? (carbs > 0 || fat > 0);

  /// Whether this item carries real (non-estimated) carb/fat macros.
  bool get hasRealMacros => macrosKnown;

  /// Carbs grams for this serving — real value when known, else the
  /// Indian-diet 65/35 split estimate of the non-protein calories.
  double get effectiveCarbs {
    if (hasRealMacros) return carbs;
    final remaining = (calories - protein * 4.0).clamp(0.0, double.infinity);
    return (remaining * 0.65) / 4.0;
  }

  /// Fat grams for this serving — real value when known, else the
  /// Indian-diet 65/35 split estimate of the non-protein calories.
  double get effectiveFat {
    if (hasRealMacros) return fat;
    final remaining = (calories - protein * 4.0).clamp(0.0, double.infinity);
    return (remaining * 0.35) / 9.0;
  }
}

/// Categories in display order
const List<String> kFoodCategories = [
  'Popular',
  'South Indian',
  'Andhra & Telangana',
  'Karnataka',
  'North Indian',
  'Indo-Chinese',
  'Breakfast',
  'Salads & Light Meals',
  'Eggs',
  'Protein',
  'Fried & Grilled',
  'Rice & Biryani',
  'Roti & Bread',
  'Dal & Curry',
  'Street Food',
  'Fast Food',
  'Sweets & Desserts',
  'Snacks',
  'Fruits',
  'Dairy',
  'Nuts & Seeds',
  'Drinks',
  'Supplement',
];

const List<FoodItem> kFoodDatabase = [
  // ── Popular ───────────────────────────────────────────────────────────────
  FoodItem(name: 'Boiled Egg', calories: 78, protein: 6, carbs: 0.6, fat: 5.3, category: 'Popular', emoji: '🥚', serving: '1 egg'),
  FoodItem(name: 'Roti', calories: 104, protein: 3, carbs: 18, fat: 2.5, category: 'Popular', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Rice (cooked)', calories: 130, protein: 2.7, carbs: 28, fat: 0.3, category: 'Popular', emoji: '🍚', serving: '100g cooked'),
  FoodItem(name: 'Dal', calories: 120, protein: 8, carbs: 18, fat: 1.5, category: 'Popular', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Grilled Chicken', calories: 219, protein: 43, carbs: 0, fat: 5, category: 'Popular', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Paneer', calories: 265, protein: 18, carbs: 3.5, fat: 20, category: 'Popular', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Oats', calories: 148, protein: 5, carbs: 27, fat: 2.6, category: 'Popular', emoji: '🥣', serving: '40g dry'),
  FoodItem(name: 'Banana', calories: 89, protein: 1.1, carbs: 23, fat: 0.3, category: 'Popular', emoji: '🍌', serving: '1 medium'),
  FoodItem(name: 'Curd / Dahi', calories: 60, protein: 3.5, carbs: 4.7, fat: 3.3, category: 'Popular', emoji: '🥛', serving: '100g'),
  FoodItem(name: 'Whey Protein Shake', calories: 130, protein: 25, carbs: 3, fat: 1.5, category: 'Popular', emoji: '💪', serving: '1 scoop (33g)'),
  FoodItem(name: 'Idli', calories: 70, protein: 2, carbs: 14, fat: 0.4, category: 'Popular', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Masala Dosa', calories: 290, protein: 6, carbs: 42, fat: 10, category: 'Popular', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Chicken Biryani', calories: 490, protein: 28, carbs: 55, fat: 17, category: 'Popular', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Rajma Chawal', calories: 390, protein: 15, carbs: 68, fat: 6, category: 'Popular', emoji: '🫘', serving: '1 plate'),
  FoodItem(name: 'Pav Bhaji', calories: 400, protein: 10, carbs: 52, fat: 16, category: 'Popular', emoji: '🥖', serving: '2 pav + bhaji'),

  // ── South Indian ──────────────────────────────────────────────────────────
  FoodItem(name: 'Idli', calories: 70, protein: 2, carbs: 14, fat: 0.4, category: 'South Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Idli with Sambar', calories: 220, protein: 8, category: 'South Indian', emoji: '🫓', serving: '2 idli + sambar'),
  FoodItem(name: 'Plain Dosa', calories: 165, protein: 4, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Masala Dosa', calories: 290, protein: 6, carbs: 42, fat: 10, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Rava Dosa', calories: 200, protein: 4, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Uttapam', calories: 210, protein: 5, category: 'South Indian', emoji: '🥞', serving: '1 piece'),
  FoodItem(name: 'Pesarattu', calories: 170, protein: 8, category: 'South Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Appam', calories: 120, protein: 3, category: 'South Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Puttu', calories: 185, protein: 4, category: 'South Indian', emoji: '🌀', serving: '100g'),
  FoodItem(name: 'Idiyappam', calories: 110, protein: 2, category: 'South Indian', emoji: '🌀', serving: '2 pieces'),
  FoodItem(name: 'Kerala Parotta', calories: 280, protein: 5, category: 'South Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Ven Pongal', calories: 200, protein: 6, category: 'South Indian', emoji: '🥣', serving: '1 bowl'),
  FoodItem(name: 'Medu Vada', calories: 150, protein: 5, category: 'South Indian', emoji: '🍩', serving: '1 piece'),
  FoodItem(name: 'Rava Idli', calories: 95, protein: 3, category: 'South Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Upma', calories: 175, protein: 5, category: 'South Indian', emoji: '🥣', serving: '1 bowl (150g)'),
  FoodItem(name: 'Poha', calories: 180, protein: 4, category: 'South Indian', emoji: '🥣', serving: '1 bowl (150g)'),
  FoodItem(name: 'Sambar', calories: 85, protein: 4, category: 'South Indian', emoji: '🍲', serving: '1 bowl'),
  FoodItem(name: 'Rasam', calories: 45, protein: 2, category: 'South Indian', emoji: '🍲', serving: '1 cup'),
  FoodItem(name: 'Avial', calories: 130, protein: 3, category: 'South Indian', emoji: '🥘', serving: '1 katori'),
  FoodItem(name: 'Thoran (Cabbage)', calories: 90, protein: 2, category: 'South Indian', emoji: '🥗', serving: '1 katori'),
  FoodItem(name: 'Olan', calories: 100, protein: 3, category: 'South Indian', emoji: '🥘', serving: '1 katori'),
  FoodItem(name: 'Erissery', calories: 120, protein: 3, category: 'South Indian', emoji: '🥘', serving: '1 katori'),
  FoodItem(name: 'Kerala Fish Curry', calories: 200, protein: 24, category: 'South Indian', emoji: '🐟', serving: '150g'),
  FoodItem(name: 'Chettinad Chicken Curry', calories: 280, protein: 30, category: 'South Indian', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Curd Rice', calories: 190, protein: 5, category: 'South Indian', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Lemon Rice', calories: 200, protein: 3, category: 'South Indian', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Tamarind Rice (Puliyodharai)', calories: 210, protein: 3, category: 'South Indian', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Kozhukattai', calories: 120, protein: 2, category: 'South Indian', emoji: '🌀', serving: '2 pieces'),
  FoodItem(name: 'Murukku', calories: 150, protein: 3, category: 'South Indian', emoji: '🌀', serving: '30g'),
  FoodItem(name: 'Chakli', calories: 145, protein: 3, category: 'South Indian', emoji: '🌀', serving: '30g'),
  FoodItem(name: 'Payasam (Vermicelli)', calories: 220, protein: 4, category: 'South Indian', emoji: '🍮', serving: '1 bowl'),
  FoodItem(name: 'Payasam (Rice)', calories: 200, protein: 4, category: 'South Indian', emoji: '🍮', serving: '1 bowl'),
  FoodItem(name: 'Mysore Pak', calories: 180, protein: 3, category: 'South Indian', emoji: '🍬', serving: '1 piece (30g)'),

  // ── North Indian ──────────────────────────────────────────────────────────
  FoodItem(name: 'Roti (Wheat)', calories: 104, protein: 3, category: 'North Indian', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Aloo Paratha', calories: 260, protein: 5, category: 'North Indian', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Gobi Paratha', calories: 240, protein: 5, category: 'North Indian', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Paneer Paratha', calories: 290, protein: 10, category: 'North Indian', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Methi Paratha', calories: 220, protein: 5, category: 'North Indian', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Thepla', calories: 165, protein: 4, category: 'North Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Puri', calories: 160, protein: 2.5, carbs: 18, fat: 8, category: 'North Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Bhatura', calories: 280, protein: 6, category: 'North Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Naan', calories: 262, protein: 8, carbs: 45, fat: 5, category: 'North Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Kulcha', calories: 240, protein: 7, category: 'North Indian', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Dal Makhani', calories: 200, protein: 9, category: 'North Indian', emoji: '🫘', serving: '1 bowl'),
  FoodItem(name: 'Dal Tadka', calories: 150, protein: 8, category: 'North Indian', emoji: '🫘', serving: '1 bowl'),
  FoodItem(name: 'Dal Fry', calories: 160, protein: 8, category: 'North Indian', emoji: '🫘', serving: '1 bowl'),
  FoodItem(name: 'Toor Dal', calories: 115, protein: 7, category: 'North Indian', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Rajma', calories: 195, protein: 12, category: 'North Indian', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Chole Masala', calories: 210, protein: 11, category: 'North Indian', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Palak Paneer', calories: 220, protein: 14, category: 'North Indian', emoji: '🥬', serving: '1 katori'),
  FoodItem(name: 'Matar Paneer', calories: 230, protein: 13, category: 'North Indian', emoji: '🧀', serving: '1 katori'),
  FoodItem(name: 'Kadai Paneer', calories: 250, protein: 14, category: 'North Indian', emoji: '🧀', serving: '1 katori'),
  FoodItem(name: 'Shahi Paneer', calories: 280, protein: 13, category: 'North Indian', emoji: '🧀', serving: '1 katori'),
  FoodItem(name: 'Malai Kofta', calories: 300, protein: 10, category: 'North Indian', emoji: '🧆', serving: '1 katori'),
  FoodItem(name: 'Paneer Tikka Masala', calories: 270, protein: 16, category: 'North Indian', emoji: '🧀', serving: '1 katori'),
  FoodItem(name: 'Butter Chicken', calories: 300, protein: 25, category: 'North Indian', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Chicken Tikka Masala', calories: 290, protein: 28, category: 'North Indian', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Aloo Gobi', calories: 150, protein: 4, category: 'North Indian', emoji: '🥦', serving: '1 katori'),
  FoodItem(name: 'Aloo Matar', calories: 160, protein: 5, category: 'North Indian', emoji: '🥔', serving: '1 katori'),
  FoodItem(name: 'Baingan Bharta', calories: 130, protein: 3, category: 'North Indian', emoji: '🍆', serving: '1 katori'),
  FoodItem(name: 'Bhindi Masala', calories: 120, protein: 3, category: 'North Indian', emoji: '🌿', serving: '1 katori'),
  FoodItem(name: 'Saag (Sarson ka Saag)', calories: 140, protein: 5, category: 'North Indian', emoji: '🥬', serving: '1 katori'),
  FoodItem(name: 'Palak Dal', calories: 130, protein: 8, category: 'North Indian', emoji: '🥬', serving: '1 katori'),
  FoodItem(name: 'Chole Bhature', calories: 550, protein: 18, category: 'North Indian', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Dhokla', calories: 120, protein: 4, category: 'North Indian', emoji: '🟡', serving: '3 pieces'),
  FoodItem(name: 'Khandvi', calories: 100, protein: 4, category: 'North Indian', emoji: '🌀', serving: '3 pieces'),
  FoodItem(name: 'Khaman', calories: 130, protein: 5, category: 'North Indian', emoji: '🟡', serving: '3 pieces'),
  FoodItem(name: 'Samosa', calories: 240, protein: 4, category: 'North Indian', emoji: '🥟', serving: '1 piece'),
  FoodItem(name: 'Kachori', calories: 210, protein: 5, category: 'North Indian', emoji: '🥟', serving: '1 piece'),
  FoodItem(name: 'Misal Pav', calories: 350, protein: 12, category: 'North Indian', emoji: '🥘', serving: '1 plate'),
  FoodItem(name: 'Pani Puri (6)', calories: 200, protein: 4, category: 'North Indian', emoji: '🫙', serving: '6 pieces'),
  FoodItem(name: 'Dahi Puri (6)', calories: 210, protein: 6, category: 'North Indian', emoji: '🫙', serving: '6 pieces'),
  FoodItem(name: 'Bhel Puri', calories: 180, protein: 5, category: 'North Indian', emoji: '🥗', serving: '1 plate'),

  // ── Indo-Chinese ──────────────────────────────────────────────────────────
  FoodItem(name: 'Veg Hakka Noodles', calories: 320, protein: 8, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Chicken Chowmein', calories: 420, protein: 22, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Veg Fried Rice', calories: 280, protein: 7, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Egg Fried Rice', calories: 350, protein: 12, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Chicken Fried Rice', calories: 420, protein: 22, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Schezwan Fried Rice', calories: 380, protein: 8, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Schezwan Noodles', calories: 360, protein: 9, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Gobi Manchurian (Dry)', calories: 240, protein: 5, category: 'Indo-Chinese', emoji: '🥦', serving: '1 plate'),
  FoodItem(name: 'Gobi Manchurian (Gravy)', calories: 280, protein: 6, category: 'Indo-Chinese', emoji: '🥦', serving: '1 bowl'),
  FoodItem(name: 'Veg Manchurian', calories: 250, protein: 6, category: 'Indo-Chinese', emoji: '🧆', serving: '1 plate'),
  FoodItem(name: 'Chilli Chicken (Dry)', calories: 310, protein: 28, category: 'Indo-Chinese', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Chilli Chicken (Gravy)', calories: 290, protein: 26, category: 'Indo-Chinese', emoji: '🍗', serving: '1 bowl'),
  FoodItem(name: 'Chilli Paneer (Dry)', calories: 270, protein: 16, category: 'Indo-Chinese', emoji: '🧀', serving: '1 plate'),
  FoodItem(name: 'Chilli Paneer (Gravy)', calories: 290, protein: 15, category: 'Indo-Chinese', emoji: '🧀', serving: '1 bowl'),
  FoodItem(name: 'Veg Momos (6 pcs)', calories: 220, protein: 8, category: 'Indo-Chinese', emoji: '🥟', serving: '6 pieces'),
  FoodItem(name: 'Chicken Momos (6 pcs)', calories: 280, protein: 18, category: 'Indo-Chinese', emoji: '🥟', serving: '6 pieces'),
  FoodItem(name: 'Pan-Fried Momos (6)', calories: 320, protein: 14, category: 'Indo-Chinese', emoji: '🥟', serving: '6 pieces'),
  FoodItem(name: 'Veg Spring Roll (2)', calories: 190, protein: 4, category: 'Indo-Chinese', emoji: '🌯', serving: '2 rolls'),
  FoodItem(name: 'Crispy Corn', calories: 300, protein: 5, category: 'Indo-Chinese', emoji: '🌽', serving: '1 bowl'),
  FoodItem(name: 'Honey Chilli Potato', calories: 350, protein: 4, category: 'Indo-Chinese', emoji: '🍟', serving: '1 plate'),
  FoodItem(name: 'Chicken 65', calories: 320, protein: 28, category: 'Indo-Chinese', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Babycorn Manchurian', calories: 220, protein: 5, category: 'Indo-Chinese', emoji: '🌽', serving: '1 plate'),

  // ── Breakfast ────────────────────────────────────────────────────────────
  FoodItem(name: 'Egg Omelette (3 eggs)', calories: 210, protein: 18, category: 'Breakfast', emoji: '🍳', serving: '3 eggs'),
  FoodItem(name: 'Masala Omelette (2 eggs)', calories: 165, protein: 13, category: 'Breakfast', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Scrambled Eggs (2)', calories: 150, protein: 12, category: 'Breakfast', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Boiled Egg', calories: 78, protein: 6, carbs: 0.6, fat: 5.3, category: 'Breakfast', emoji: '🥚', serving: '1 egg'),
  FoodItem(name: 'Bread (White)', calories: 69, protein: 2.3, carbs: 13, fat: 0.9, category: 'Breakfast', emoji: '🍞', serving: '1 slice (30g)'),
  FoodItem(name: 'Bread (Brown/Multigrain)', calories: 65, protein: 3, category: 'Breakfast', emoji: '🍞', serving: '1 slice (30g)'),
  FoodItem(name: 'Bread with Peanut Butter', calories: 188, protein: 8, category: 'Breakfast', emoji: '🍞', serving: '2 slices + 1 tbsp PB'),
  FoodItem(name: 'Oats (plain)', calories: 148, protein: 5, category: 'Breakfast', emoji: '🥣', serving: '40g dry'),
  FoodItem(name: 'Oats with Milk & Banana', calories: 285, protein: 10, category: 'Breakfast', emoji: '🥣', serving: '40g oats + 200ml milk + banana'),
  FoodItem(name: 'Corn Flakes with Milk', calories: 185, protein: 6, category: 'Breakfast', emoji: '🥣', serving: '30g + 150ml milk'),
  FoodItem(name: 'Muesli with Milk', calories: 240, protein: 8, category: 'Breakfast', emoji: '🥣', serving: '45g + 150ml milk'),
  FoodItem(name: 'Besan Chilla (2)', calories: 180, protein: 10, category: 'Breakfast', emoji: '🥞', serving: '2 chilla'),
  FoodItem(name: 'Moong Chilla (2)', calories: 160, protein: 9, category: 'Breakfast', emoji: '🥞', serving: '2 chilla'),
  FoodItem(name: 'Upma', calories: 175, protein: 5, category: 'Breakfast', emoji: '🥣', serving: '1 bowl (150g)'),
  FoodItem(name: 'Poha', calories: 180, protein: 4, category: 'Breakfast', emoji: '🥣', serving: '1 bowl (150g)'),
  FoodItem(name: 'Aloo Paratha', calories: 260, protein: 5, category: 'Breakfast', emoji: '🫓', serving: '1 paratha'),

  // ── Protein sources ───────────────────────────────────────────────────────
  FoodItem(name: 'Boiled Egg White (1)', calories: 17, protein: 3.6, carbs: 0.2, fat: 0.1, category: 'Protein', emoji: '🥚', serving: '1 white only'),
  FoodItem(name: 'Boiled Egg (whole)', calories: 78, protein: 6, carbs: 0.6, fat: 5.3, category: 'Protein', emoji: '🥚', serving: '1 egg'),
  FoodItem(name: 'Egg Curry (2 eggs)', calories: 200, protein: 14, carbs: 6, fat: 13, category: 'Protein', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Grilled Chicken Breast', calories: 165, protein: 31, carbs: 0, fat: 3.6, category: 'Protein', emoji: '🍗', serving: '100g'),
  FoodItem(name: 'Boiled Chicken', calories: 215, protein: 40, carbs: 0, fat: 5.5, category: 'Protein', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Chicken Curry', calories: 248, protein: 28, carbs: 6, fat: 12, category: 'Protein', emoji: '🍛', serving: '150g'),
  FoodItem(name: 'Paneer (raw)', calories: 265, protein: 18, carbs: 3.5, fat: 20, category: 'Protein', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Paneer Bhurji', calories: 200, protein: 16, carbs: 6, fat: 13, category: 'Protein', emoji: '🧆', serving: '100g'),
  FoodItem(name: 'Paneer Tikka', calories: 230, protein: 19, carbs: 7, fat: 14, category: 'Protein', emoji: '🍢', serving: '100g'),
  FoodItem(name: 'Tofu (firm)', calories: 76, protein: 8, carbs: 1.9, fat: 4.8, category: 'Protein', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Moong Dal (cooked)', calories: 105, protein: 7, carbs: 19, fat: 0.4, category: 'Protein', emoji: '🫘', serving: '100g cooked'),
  FoodItem(name: 'Sprouts (mixed)', calories: 62, protein: 4, carbs: 11, fat: 0.5, category: 'Protein', emoji: '🌱', serving: '100g'),
  FoodItem(name: 'Tuna (canned)', calories: 116, protein: 25, carbs: 0, fat: 1, category: 'Protein', emoji: '🐟', serving: '100g drained'),
  FoodItem(name: 'Fish Curry', calories: 190, protein: 22, carbs: 5, fat: 9, category: 'Protein', emoji: '🐟', serving: '150g'),
  FoodItem(name: 'Soya Chunks (cooked)', calories: 145, protein: 20, carbs: 12, fat: 1.5, category: 'Protein', emoji: '🌱', serving: '100g'),

  // ── Rice & Biryani ────────────────────────────────────────────────────────
  FoodItem(name: 'White Rice', calories: 130, protein: 2.7, carbs: 28, fat: 0.3, category: 'Rice & Biryani', emoji: '🍚', serving: '100g cooked'),
  FoodItem(name: 'Brown Rice', calories: 112, protein: 2.6, carbs: 24, fat: 0.9, category: 'Rice & Biryani', emoji: '🍚', serving: '100g cooked'),
  FoodItem(name: 'Jeera Rice', calories: 160, protein: 3, carbs: 30, fat: 3, category: 'Rice & Biryani', emoji: '🍚', serving: '1 cup cooked'),
  FoodItem(name: 'Veg Biryani', calories: 350, protein: 8, carbs: 55, fat: 10, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Chicken Biryani', calories: 490, protein: 28, carbs: 55, fat: 17, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Mutton Biryani', calories: 540, protein: 30, carbs: 56, fat: 21, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Egg Biryani', calories: 400, protein: 18, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Hyderabadi Biryani', calories: 510, protein: 26, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Kozhikodan Biryani', calories: 480, protein: 27, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Pulao (veg)', calories: 280, protein: 6, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Curd Rice', calories: 190, protein: 5, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Lemon Rice', calories: 200, protein: 3, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Tomato Rice', calories: 210, protein: 4, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Coconut Rice', calories: 230, protein: 3, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Rajma Chawal', calories: 390, protein: 15, carbs: 68, fat: 6, category: 'Rice & Biryani', emoji: '🫘', serving: '1 plate'),

  // ── Roti & Bread ──────────────────────────────────────────────────────────
  FoodItem(name: 'Roti (wheat)', calories: 104, protein: 3, carbs: 18, fat: 2.5, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Roti with Ghee', calories: 134, protein: 3, carbs: 18, fat: 5.7, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti + ghee'),
  FoodItem(name: 'Chapati (thin)', calories: 80, protein: 2.5, carbs: 15, fat: 1.5, category: 'Roti & Bread', emoji: '🫓', serving: '1 small'),
  FoodItem(name: 'Plain Paratha', calories: 200, protein: 4, carbs: 28, fat: 8, category: 'Roti & Bread', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Naan', calories: 262, protein: 8, carbs: 45, fat: 5, category: 'Roti & Bread', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Garlic Naan', calories: 290, protein: 8, carbs: 46, fat: 8, category: 'Roti & Bread', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Bread (White)', calories: 69, protein: 2.3, carbs: 13, fat: 0.9, category: 'Roti & Bread', emoji: '🍞', serving: '1 slice (30g)'),
  FoodItem(name: 'Bread (Brown)', calories: 65, protein: 3, carbs: 12, fat: 1, category: 'Roti & Bread', emoji: '🍞', serving: '1 slice (30g)'),
  FoodItem(name: 'Puri', calories: 160, protein: 2.5, carbs: 18, fat: 8, category: 'Roti & Bread', emoji: '🫓', serving: '1 piece'),

  // ── Dal & Curry ───────────────────────────────────────────────────────────
  FoodItem(name: 'Toor Dal', calories: 115, protein: 7, category: 'Dal & Curry', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Dal Makhani', calories: 200, protein: 9, category: 'Dal & Curry', emoji: '🫘', serving: '1 bowl'),
  FoodItem(name: 'Dal Tadka', calories: 150, protein: 8, category: 'Dal & Curry', emoji: '🫘', serving: '1 bowl'),
  FoodItem(name: 'Palak Dal', calories: 130, protein: 8, category: 'Dal & Curry', emoji: '🥬', serving: '1 katori'),
  FoodItem(name: 'Rajma', calories: 195, protein: 12, category: 'Dal & Curry', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Chole (Chickpeas)', calories: 210, protein: 11, category: 'Dal & Curry', emoji: '🫘', serving: '1 katori'),
  FoodItem(name: 'Sambar', calories: 85, protein: 4, category: 'Dal & Curry', emoji: '🍲', serving: '1 bowl'),
  FoodItem(name: 'Palak Paneer', calories: 220, protein: 14, category: 'Dal & Curry', emoji: '🥬', serving: '1 katori'),
  FoodItem(name: 'Butter Chicken', calories: 300, protein: 25, category: 'Dal & Curry', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Mixed Veg Curry', calories: 140, protein: 4, category: 'Dal & Curry', emoji: '🥘', serving: '1 katori'),

  // ── Street Food ───────────────────────────────────────────────────────────
  FoodItem(name: 'Pav Bhaji', calories: 400, protein: 10, carbs: 52, fat: 16, category: 'Street Food', emoji: '🥖', serving: '2 pav + bhaji'),
  FoodItem(name: 'Vada Pav', calories: 285, protein: 7, category: 'Street Food', emoji: '🥖', serving: '1 piece'),
  FoodItem(name: 'Pani Puri (6)', calories: 200, protein: 4, category: 'Street Food', emoji: '🫙', serving: '6 pieces'),
  FoodItem(name: 'Dahi Puri (6)', calories: 210, protein: 6, category: 'Street Food', emoji: '🫙', serving: '6 pieces'),
  FoodItem(name: 'Bhel Puri', calories: 180, protein: 5, category: 'Street Food', emoji: '🥗', serving: '1 plate'),
  FoodItem(name: 'Sev Puri', calories: 200, protein: 5, category: 'Street Food', emoji: '🥗', serving: '1 plate'),
  FoodItem(name: 'Masala Puri', calories: 230, protein: 6, category: 'Street Food', emoji: '🥗', serving: '1 plate'),
  FoodItem(name: 'Dabeli', calories: 280, protein: 6, category: 'Street Food', emoji: '🥖', serving: '1 piece'),
  FoodItem(name: 'Kathi Roll / Frankie (Veg)', calories: 280, protein: 7, category: 'Street Food', emoji: '🌯', serving: '1 roll'),
  FoodItem(name: 'Kathi Roll / Frankie (Chicken)', calories: 350, protein: 22, category: 'Street Food', emoji: '🌯', serving: '1 roll'),
  FoodItem(name: 'Egg Roll', calories: 320, protein: 14, category: 'Street Food', emoji: '🌯', serving: '1 roll'),
  FoodItem(name: 'Veg Sandwich', calories: 200, protein: 7, category: 'Street Food', emoji: '🥪', serving: '1 sandwich'),
  FoodItem(name: 'Bombay Sandwich', calories: 280, protein: 8, category: 'Street Food', emoji: '🥪', serving: '1 sandwich'),
  FoodItem(name: 'Club Sandwich', calories: 380, protein: 18, category: 'Street Food', emoji: '🥪', serving: '1 sandwich'),
  FoodItem(name: 'Chicken Sandwich', calories: 280, protein: 22, category: 'Street Food', emoji: '🥪', serving: '1 sandwich'),
  FoodItem(name: 'Maggi (1 pack)', calories: 350, protein: 8, category: 'Street Food', emoji: '🍜', serving: '1 pack (70g)'),
  FoodItem(name: 'Samosa', calories: 240, protein: 4, category: 'Street Food', emoji: '🥟', serving: '1 piece'),
  FoodItem(name: 'Pakora (3 pcs)', calories: 180, protein: 4, category: 'Street Food', emoji: '🧆', serving: '3 pieces'),
  FoodItem(name: 'Misal Pav', calories: 350, protein: 12, category: 'Street Food', emoji: '🥘', serving: '1 plate'),

  // ── Fast Food ─────────────────────────────────────────────────────────────
  FoodItem(name: 'McAloo Tikki Burger', calories: 340, protein: 10, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'McSpicy Paneer Burger', calories: 440, protein: 15, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'McSpicy Chicken Burger', calories: 510, protein: 28, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'KFC Chicken Burger', calories: 490, protein: 26, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'Veg Burger', calories: 310, protein: 10, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'Chicken Burger', calories: 430, protein: 28, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'French Fries (Medium)', calories: 320, protein: 4, category: 'Fast Food', emoji: '🍟', serving: '1 medium pack'),
  FoodItem(name: 'Pizza Margherita (2 slices)', calories: 500, protein: 20, category: 'Fast Food', emoji: '🍕', serving: '2 slices'),
  FoodItem(name: 'Pizza Farmhouse (2 slices)', calories: 560, protein: 24, category: 'Fast Food', emoji: '🍕', serving: '2 slices'),
  FoodItem(name: 'Pizza (1 slice)', calories: 285, protein: 12, category: 'Fast Food', emoji: '🍕', serving: '1 slice'),
  FoodItem(name: 'Subway Veg Sub (6")', calories: 350, protein: 12, category: 'Fast Food', emoji: '🥖', serving: '6 inch sub'),
  FoodItem(name: 'Subway Chicken Sub (6")', calories: 420, protein: 28, category: 'Fast Food', emoji: '🥖', serving: '6 inch sub'),
  FoodItem(name: 'Loaded Nachos', calories: 420, protein: 8, category: 'Fast Food', emoji: '🌮', serving: '1 plate'),
  FoodItem(name: 'Chicken Wings (6 pcs)', calories: 430, protein: 36, category: 'Fast Food', emoji: '🍗', serving: '6 pieces'),
  FoodItem(name: 'Lays Chips (30g)', calories: 160, protein: 2, category: 'Fast Food', emoji: '🥔', serving: '30g bag'),
  FoodItem(name: 'Kurkure (30g)', calories: 150, protein: 2, category: 'Fast Food', emoji: '🌽', serving: '30g'),

  // ── Sweets & Desserts ──────────────────────────────────────────────────────
  FoodItem(name: 'Gulab Jamun', calories: 175, protein: 3, category: 'Sweets & Desserts', emoji: '🍮', serving: '2 pieces'),
  FoodItem(name: 'Rasgulla', calories: 100, protein: 3, category: 'Sweets & Desserts', emoji: '⚪', serving: '2 pieces'),
  FoodItem(name: 'Rasmalai', calories: 150, protein: 5, category: 'Sweets & Desserts', emoji: '🍮', serving: '2 pieces'),
  FoodItem(name: 'Jalebi', calories: 150, protein: 1, category: 'Sweets & Desserts', emoji: '🍩', serving: '2 pieces (50g)'),
  FoodItem(name: 'Imarti', calories: 160, protein: 2, category: 'Sweets & Desserts', emoji: '🍩', serving: '1 piece'),
  FoodItem(name: 'Besan Ladoo', calories: 175, protein: 4, category: 'Sweets & Desserts', emoji: '🟡', serving: '1 piece (40g)'),
  FoodItem(name: 'Motichoor Ladoo', calories: 180, protein: 3, category: 'Sweets & Desserts', emoji: '🟡', serving: '1 piece (40g)'),
  FoodItem(name: 'Coconut Ladoo', calories: 160, protein: 2, category: 'Sweets & Desserts', emoji: '🥥', serving: '1 piece (35g)'),
  FoodItem(name: 'Gajar Halwa', calories: 200, protein: 3, category: 'Sweets & Desserts', emoji: '🥕', serving: '1 katori (100g)'),
  FoodItem(name: 'Suji Halwa', calories: 190, protein: 3, category: 'Sweets & Desserts', emoji: '🍮', serving: '1 katori (100g)'),
  FoodItem(name: 'Moong Dal Halwa', calories: 220, protein: 6, category: 'Sweets & Desserts', emoji: '🍮', serving: '1 katori'),
  FoodItem(name: 'Rice Kheer', calories: 180, protein: 4, category: 'Sweets & Desserts', emoji: '🥣', serving: '1 bowl'),
  FoodItem(name: 'Seviyan Kheer', calories: 190, protein: 5, category: 'Sweets & Desserts', emoji: '🥣', serving: '1 bowl'),
  FoodItem(name: 'Kaju Barfi', calories: 195, protein: 4, category: 'Sweets & Desserts', emoji: '🍬', serving: '2 pieces (40g)'),
  FoodItem(name: 'Milk Barfi', calories: 185, protein: 4, category: 'Sweets & Desserts', emoji: '🍬', serving: '2 pieces'),
  FoodItem(name: 'Coconut Barfi', calories: 170, protein: 2, category: 'Sweets & Desserts', emoji: '🥥', serving: '2 pieces'),
  FoodItem(name: 'Peda', calories: 130, protein: 3, category: 'Sweets & Desserts', emoji: '🟤', serving: '2 pieces'),
  FoodItem(name: 'Sandesh', calories: 120, protein: 5, category: 'Sweets & Desserts', emoji: '⚪', serving: '2 pieces'),
  FoodItem(name: 'Mysore Pak', calories: 180, protein: 3, category: 'Sweets & Desserts', emoji: '🍬', serving: '1 piece (30g)'),
  FoodItem(name: 'Kulfi (Matka)', calories: 130, protein: 4, category: 'Sweets & Desserts', emoji: '🍦', serving: '1 piece (80g)'),
  FoodItem(name: 'Rabri', calories: 190, protein: 5, category: 'Sweets & Desserts', emoji: '🥛', serving: '1 bowl'),
  FoodItem(name: 'Basundi', calories: 200, protein: 6, category: 'Sweets & Desserts', emoji: '🥛', serving: '1 bowl'),
  FoodItem(name: 'Ice Cream (Vanilla)', calories: 207, protein: 4, category: 'Sweets & Desserts', emoji: '🍦', serving: '100g'),
  FoodItem(name: 'Payasam', calories: 210, protein: 4, category: 'Sweets & Desserts', emoji: '🍮', serving: '1 bowl'),
  FoodItem(name: 'Halwa Poori (combo)', calories: 520, protein: 8, category: 'Sweets & Desserts', emoji: '🍮', serving: '1 plate'),

  // ── Snacks ───────────────────────────────────────────────────────────────
  FoodItem(name: 'Roasted Chana', calories: 164, protein: 9, category: 'Snacks', emoji: '🫘', serving: '30g'),
  FoodItem(name: 'Khakhra (2)', calories: 120, protein: 3, category: 'Snacks', emoji: '🫓', serving: '2 pieces'),
  FoodItem(name: 'Marie Biscuits (3)', calories: 90, protein: 1.5, category: 'Snacks', emoji: '🍪', serving: '3 biscuits'),
  FoodItem(name: 'Digestive Biscuit (2)', calories: 140, protein: 2, category: 'Snacks', emoji: '🍪', serving: '2 biscuits'),
  FoodItem(name: 'Protein Bar (MuscleBlaze)', calories: 210, protein: 20, category: 'Snacks', emoji: '🍫', serving: '1 bar (70g)'),
  FoodItem(name: 'Banana Chips (30g)', calories: 162, protein: 1, category: 'Snacks', emoji: '🍌', serving: '30g'),
  FoodItem(name: 'Popcorn (plain)', calories: 93, protein: 3, category: 'Snacks', emoji: '🍿', serving: '30g popped'),
  FoodItem(name: 'Peanuts (salted)', calories: 170, protein: 7.7, category: 'Snacks', emoji: '🥜', serving: '30g'),
  FoodItem(name: 'Chivda / Mixture', calories: 160, protein: 4, category: 'Snacks', emoji: '🌾', serving: '30g'),
  FoodItem(name: 'Mathri', calories: 160, protein: 3, category: 'Snacks', emoji: '🫓', serving: '3 pieces'),
  FoodItem(name: 'Namak Para', calories: 155, protein: 3, category: 'Snacks', emoji: '🫓', serving: '30g'),

  // ── Fruits ───────────────────────────────────────────────────────────────
  FoodItem(name: 'Apple', calories: 52, protein: 0.3, carbs: 14, fat: 0.2, category: 'Fruits', emoji: '🍎', serving: '1 medium (150g)'),
  FoodItem(name: 'Banana', calories: 89, protein: 1.1, carbs: 23, fat: 0.3, category: 'Fruits', emoji: '🍌', serving: '1 medium (120g)'),
  FoodItem(name: 'Mango', calories: 135, protein: 1.4, carbs: 33, fat: 0.6, category: 'Fruits', emoji: '🥭', serving: '1 medium (200g)'),
  FoodItem(name: 'Orange', calories: 47, protein: 0.9, carbs: 12, fat: 0.1, category: 'Fruits', emoji: '🍊', serving: '1 medium (130g)'),
  FoodItem(name: 'Papaya', calories: 43, protein: 0.5, carbs: 11, fat: 0.3, category: 'Fruits', emoji: '🍈', serving: '100g'),
  FoodItem(name: 'Watermelon', calories: 30, protein: 0.6, carbs: 7.6, fat: 0.2, category: 'Fruits', emoji: '🍉', serving: '100g'),
  FoodItem(name: 'Pomegranate', calories: 83, protein: 1.7, carbs: 19, fat: 1.2, category: 'Fruits', emoji: '🍎', serving: '100g arils'),
  FoodItem(name: 'Grapes', calories: 67, protein: 0.6, carbs: 17, fat: 0.4, category: 'Fruits', emoji: '🍇', serving: '100g'),
  FoodItem(name: 'Guava', calories: 68, protein: 2.6, carbs: 14, fat: 1, category: 'Fruits', emoji: '🍈', serving: '1 medium (100g)'),
  FoodItem(name: 'Pineapple', calories: 50, protein: 0.5, carbs: 13, fat: 0.1, category: 'Fruits', emoji: '🍍', serving: '100g'),
  FoodItem(name: 'Strawberry', calories: 32, protein: 0.7, carbs: 7.7, fat: 0.3, category: 'Fruits', emoji: '🍓', serving: '100g'),
  FoodItem(name: 'Chickoo (Sapota)', calories: 83, protein: 0.4, carbs: 20, fat: 1.1, category: 'Fruits', emoji: '🍈', serving: '100g'),
  FoodItem(name: 'Kiwi', calories: 61, protein: 1.1, carbs: 15, fat: 0.5, category: 'Fruits', emoji: '🥝', serving: '1 medium (76g)'),
  FoodItem(name: 'Dates (Khajur)', calories: 282, protein: 2.5, carbs: 75, fat: 0.4, category: 'Fruits', emoji: '🤎', serving: '4 pieces (40g)'),

  // ── Dairy ────────────────────────────────────────────────────────────────
  FoodItem(name: 'Full-Fat Milk', calories: 122, protein: 6.4, carbs: 9.6, fat: 6.6, category: 'Dairy', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Toned Milk', calories: 100, protein: 6, carbs: 10, fat: 3.6, category: 'Dairy', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Skim Milk', calories: 70, protein: 7, carbs: 10, fat: 0.2, category: 'Dairy', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Curd / Dahi', calories: 60, protein: 3.5, carbs: 4.7, fat: 3.3, category: 'Dairy', emoji: '🥛', serving: '100g'),
  FoodItem(name: 'Greek Yogurt', calories: 100, protein: 10, carbs: 6, fat: 4, category: 'Dairy', emoji: '🥛', serving: '150g'),
  FoodItem(name: 'Buttermilk (Chaas)', calories: 45, protein: 3, carbs: 5, fat: 1.2, category: 'Dairy', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Paneer', calories: 265, protein: 18, carbs: 3.5, fat: 20, category: 'Dairy', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Ghee', calories: 112, protein: 0, carbs: 0, fat: 12.7, category: 'Dairy', emoji: '🧈', serving: '1 tsp (14g)'),
  FoodItem(name: 'Butter', calories: 102, protein: 0.1, carbs: 0.1, fat: 11.5, category: 'Dairy', emoji: '🧈', serving: '1 tbsp (14g)'),

  // ── Nuts & Seeds ──────────────────────────────────────────────────────────
  FoodItem(name: 'Almonds', calories: 58, protein: 2.1, carbs: 2.2, fat: 5, category: 'Nuts & Seeds', emoji: '🌰', serving: '10g (~8 nuts)'),
  FoodItem(name: 'Cashews', calories: 55, protein: 1.8, carbs: 3, fat: 4.4, category: 'Nuts & Seeds', emoji: '🥜', serving: '10g (~6 nuts)'),
  FoodItem(name: 'Walnuts', calories: 65, protein: 1.5, carbs: 1.4, fat: 6.5, category: 'Nuts & Seeds', emoji: '🌰', serving: '10g'),
  FoodItem(name: 'Peanuts', calories: 170, protein: 7.7, carbs: 4.8, fat: 14, category: 'Nuts & Seeds', emoji: '🥜', serving: '30g'),
  FoodItem(name: 'Peanut Butter (1 tbsp)', calories: 94, protein: 4, carbs: 3, fat: 8, category: 'Nuts & Seeds', emoji: '🥜', serving: '1 tbsp (16g)'),
  FoodItem(name: 'Chia Seeds', calories: 58, protein: 2, carbs: 5, fat: 3.7, category: 'Nuts & Seeds', emoji: '🌱', serving: '1 tbsp (15g)'),
  FoodItem(name: 'Flax Seeds', calories: 55, protein: 1.9, carbs: 3, fat: 4.3, category: 'Nuts & Seeds', emoji: '🌱', serving: '1 tbsp (14g)'),
  FoodItem(name: 'Mixed Nuts (30g)', calories: 170, protein: 4.5, carbs: 6, fat: 15, category: 'Nuts & Seeds', emoji: '🌰', serving: '30g'),
  FoodItem(name: 'Pistachios', calories: 57, protein: 2.1, carbs: 2.8, fat: 4.5, category: 'Nuts & Seeds', emoji: '🌰', serving: '10g'),

  // ── Drinks ───────────────────────────────────────────────────────────────
  FoodItem(name: 'Black Coffee', calories: 2, protein: 0.3, category: 'Drinks', emoji: '☕', serving: '1 cup (240ml)'),
  FoodItem(name: 'Coffee with Milk', calories: 65, protein: 3.5, category: 'Drinks', emoji: '☕', serving: '1 cup + 100ml milk'),
  FoodItem(name: 'Filter Coffee (South Indian)', calories: 80, protein: 3, category: 'Drinks', emoji: '☕', serving: '1 cup with milk'),
  FoodItem(name: 'Tea (no sugar)', calories: 5, protein: 0, category: 'Drinks', emoji: '🍵', serving: '1 cup'),
  FoodItem(name: 'Masala Chai', calories: 60, protein: 2, category: 'Drinks', emoji: '🍵', serving: '1 cup (150ml)'),
  FoodItem(name: 'Tea with Milk & Sugar', calories: 55, protein: 1.5, category: 'Drinks', emoji: '🍵', serving: '1 cup'),
  FoodItem(name: 'Badam Milk', calories: 165, protein: 7, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Turmeric Milk (Haldi Doodh)', calories: 110, protein: 5, category: 'Drinks', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Banana Protein Shake', calories: 280, protein: 28, category: 'Drinks', emoji: '🥤', serving: '1 shake'),
  FoodItem(name: 'Coconut Water', calories: 48, protein: 0.5, category: 'Drinks', emoji: '🥥', serving: '240ml'),
  FoodItem(name: 'Lassi (sweet)', calories: 170, protein: 5, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Lassi (salted)', calories: 75, protein: 5, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Mango Lassi', calories: 220, protein: 4, category: 'Drinks', emoji: '🥭', serving: '250ml'),
  FoodItem(name: 'Nimbu Pani / Lemonade', calories: 30, protein: 0, category: 'Drinks', emoji: '🍋', serving: '1 glass'),
  FoodItem(name: 'Sugarcane Juice', calories: 180, protein: 0.3, category: 'Drinks', emoji: '🍹', serving: '1 glass (250ml)'),
  FoodItem(name: 'Orange Juice (fresh)', calories: 112, protein: 1.7, category: 'Drinks', emoji: '🍊', serving: '240ml'),
  FoodItem(name: 'Aam Panna', calories: 90, protein: 0.5, category: 'Drinks', emoji: '🥭', serving: '1 glass'),
  FoodItem(name: 'Jaljeera', calories: 40, protein: 0.5, category: 'Drinks', emoji: '🥤', serving: '1 glass'),
  FoodItem(name: 'Rose Milk', calories: 150, protein: 5, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Protein Milk (200ml)', calories: 145, protein: 12, category: 'Drinks', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Energy Drink (can)', calories: 110, protein: 1, category: 'Drinks', emoji: '⚡', serving: '250ml can'),
  FoodItem(name: 'Cold Coffee', calories: 150, protein: 5, category: 'Drinks', emoji: '☕', serving: '250ml'),
  FoodItem(name: 'Thandai', calories: 190, protein: 5, category: 'Drinks', emoji: '🥛', serving: '1 glass'),

  // ── Millets & Ancient Grains ──────────────────────────────────────────────
  FoodItem(name: 'Ragi Malt (Finger Millet Porridge)', calories: 80, protein: 2.0, category: 'Breakfast', emoji: '🌾', serving: '200ml cup'),
  FoodItem(name: 'Ragi Roti', calories: 107, protein: 3.5, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Foxtail Millet (Thinai) cooked', calories: 97, protein: 3.5, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Barnyard Millet cooked', calories: 76, protein: 2.5, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Kodo Millet cooked', calories: 94, protein: 2.8, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Little Millet (Kutki) cooked', calories: 78, protein: 2.1, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Pearl Millet / Bajra Roti', calories: 110, protein: 4.0, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Jowar Roti', calories: 105, protein: 3.5, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Jowar Porridge', calories: 72, protein: 2.3, category: 'Breakfast', emoji: '🌾', serving: '200ml'),
  FoodItem(name: 'Amaranth (Rajgira) Porridge', calories: 105, protein: 4.0, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Buckwheat (Kuttu) Roti', calories: 98, protein: 3.8, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Quinoa cooked', calories: 120, protein: 4.4, category: 'Breakfast', emoji: '🌾', serving: '100g'),
  FoodItem(name: 'Mixed Millet Porridge (Malt)', calories: 85, protein: 2.5, category: 'Breakfast', emoji: '🌾', serving: '200ml'),

  // ── More South Indian ─────────────────────────────────────────────────────
  FoodItem(name: 'Pesarattu (Green Moong Dosa)', calories: 105, protein: 5.0, category: 'South Indian', emoji: '🫓', serving: '1 piece (80g)'),
  FoodItem(name: 'Puttu', calories: 170, protein: 3.0, category: 'South Indian', emoji: '🌀', serving: '1 piece (80g)'),
  FoodItem(name: 'Thoran (Coconut Veg Stir-fry)', calories: 90, protein: 2.0, category: 'South Indian', emoji: '🥗', serving: '100g'),
  FoodItem(name: 'Kozhukatta', calories: 140, protein: 2.5, category: 'South Indian', emoji: '🌀', serving: '2 pieces (80g)'),
  FoodItem(name: 'Kadala Curry (Black Chickpea)', calories: 160, protein: 7.0, category: 'South Indian', emoji: '🫘', serving: '150g'),
  FoodItem(name: 'Sambhar (full bowl)', calories: 80, protein: 4.0, category: 'South Indian', emoji: '🍲', serving: '200ml'),
  FoodItem(name: 'Medu Vada (2 pcs)', calories: 180, protein: 5.0, category: 'South Indian', emoji: '🍩', serving: '2 pieces (80g)'),
  FoodItem(name: 'Rava Upma', calories: 180, protein: 4.0, category: 'South Indian', emoji: '🥣', serving: '150g'),
  FoodItem(name: 'Kichdi', calories: 180, protein: 6.0, category: 'South Indian', emoji: '🥣', serving: '150g'),
  FoodItem(name: 'Bisibelebath', calories: 200, protein: 7.0, category: 'South Indian', emoji: '🍲', serving: '200g'),

  // ── More North Indian ─────────────────────────────────────────────────────
  FoodItem(name: 'Makki ki Roti', calories: 115, protein: 2.5, category: 'North Indian', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Sarson ka Saag', calories: 120, protein: 4.0, category: 'North Indian', emoji: '🥬', serving: '150g'),
  FoodItem(name: 'Besan Chilla', calories: 130, protein: 8.0, category: 'North Indian', emoji: '🥞', serving: '1 piece (80g)'),
  FoodItem(name: 'Moong Dal Chilla', calories: 120, protein: 8.0, category: 'North Indian', emoji: '🥞', serving: '1 piece (80g)'),
  FoodItem(name: 'Biryani (Chicken) 200g', calories: 320, protein: 16.0, category: 'Rice & Biryani', emoji: '🍛', serving: '200g'),
  FoodItem(name: 'Biryani (Veg) 200g', calories: 260, protein: 6.0, category: 'Rice & Biryani', emoji: '🍛', serving: '200g'),
  FoodItem(name: 'Matar Paneer', calories: 220, protein: 10.0, category: 'North Indian', emoji: '🧀', serving: '150g'),
  FoodItem(name: 'Shahi Paneer', calories: 280, protein: 11.0, category: 'North Indian', emoji: '🧀', serving: '150g'),
  FoodItem(name: 'Palak Paneer', calories: 200, protein: 10.0, category: 'North Indian', emoji: '🥬', serving: '150g'),
  FoodItem(name: 'Butter Chicken 150g', calories: 250, protein: 18.0, category: 'North Indian', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Poha', calories: 165, protein: 3.5, category: 'Breakfast', emoji: '🥣', serving: '150g'),

  // ── Snacks ────────────────────────────────────────────────────────────────
  FoodItem(name: 'Murmura (Puffed Rice)', calories: 84, protein: 2.0, category: 'Snacks', emoji: '🌾', serving: '30g'),
  FoodItem(name: 'Roasted Makhana (Fox Nuts)', calories: 90, protein: 4.0, category: 'Snacks', emoji: '⚪', serving: '30g'),
  FoodItem(name: 'Chivda (Low Oil)', calories: 140, protein: 5.0, category: 'Snacks', emoji: '🌾', serving: '40g'),
  FoodItem(name: 'Dhokla (2 pcs)', calories: 160, protein: 5.0, category: 'Snacks', emoji: '🟡', serving: '2 pieces (80g)'),

  // ── More Dairy & Protein ──────────────────────────────────────────────────
  FoodItem(name: 'Chhena (Fresh Paneer Solids)', calories: 200, protein: 14.0, category: 'Dairy', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Lassi (Sweet) 250ml', calories: 150, protein: 5.0, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Lassi (Salted) 250ml', calories: 80, protein: 4.0, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Chaas (Buttermilk)', calories: 40, protein: 2.0, category: 'Drinks', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Dahi Full Fat', calories: 120, protein: 6.0, category: 'Dairy', emoji: '🥛', serving: '150g'),
  FoodItem(name: 'Mishti Doi', calories: 180, protein: 6.0, category: 'Sweets & Desserts', emoji: '🍮', serving: '150g'),
  FoodItem(name: 'Mozzarella Cheese', calories: 280, protein: 20.0, category: 'Dairy', emoji: '🧀', serving: '30g'),

  // ── More Fruits ───────────────────────────────────────────────────────────
  FoodItem(name: 'Chikoo (Sapodilla)', calories: 83, protein: 0.5, category: 'Fruits', emoji: '🍈', serving: '100g'),
  FoodItem(name: 'Custard Apple (Sitaphal)', calories: 101, protein: 1.7, category: 'Fruits', emoji: '🍈', serving: '100g'),
  FoodItem(name: 'Jamun (Java Plum)', calories: 62, protein: 0.7, category: 'Fruits', emoji: '🍇', serving: '100g'),
  FoodItem(name: 'Amla (Indian Gooseberry)', calories: 44, protein: 0.9, category: 'Fruits', emoji: '🍈', serving: '50g'),
  FoodItem(name: 'Kokum', calories: 25, protein: 0.5, category: 'Fruits', emoji: '🍈', serving: '50g'),
  FoodItem(name: 'Tamarind', calories: 239, protein: 2.8, category: 'Fruits', emoji: '🍈', serving: '50g'),

  // ── More Drinks ───────────────────────────────────────────────────────────
  FoodItem(name: 'Turmeric Milk (Haldi Doodh)', calories: 120, protein: 5.0, category: 'Drinks', emoji: '🥛', serving: '200ml'),
  FoodItem(name: 'Masala Chai with Milk', calories: 60, protein: 2.0, category: 'Drinks', emoji: '🍵', serving: '150ml'),
  FoodItem(name: 'Filter Coffee with Milk', calories: 55, protein: 2.0, category: 'Drinks', emoji: '☕', serving: '150ml'),
  FoodItem(name: 'Sugarcane Juice', calories: 115, protein: 0.2, category: 'Drinks', emoji: '🍹', serving: '240ml'),
  FoodItem(name: 'Jaljeera', calories: 30, protein: 0.5, category: 'Drinks', emoji: '🥤', serving: '200ml'),
  FoodItem(name: 'Rose Milk 200ml', calories: 150, protein: 4.0, category: 'Drinks', emoji: '🥛', serving: '200ml'),

  // ── More Sweets ───────────────────────────────────────────────────────────
  FoodItem(name: 'Pongal (Sweet)', calories: 220, protein: 4.0, category: 'Sweets & Desserts', emoji: '🍮', serving: '150g'),
  FoodItem(name: 'Payasam / Kheer', calories: 200, protein: 5.0, category: 'Sweets & Desserts', emoji: '🥣', serving: '150ml'),
  FoodItem(name: 'Sooji Halwa', calories: 250, protein: 4.0, category: 'Sweets & Desserts', emoji: '🍮', serving: '100g'),
  FoodItem(name: 'Ladoo (Besan)', calories: 180, protein: 4.0, category: 'Sweets & Desserts', emoji: '🟡', serving: '1 piece (40g)'),
  FoodItem(name: 'Ladoo (Boondi)', calories: 160, protein: 3.0, category: 'Sweets & Desserts', emoji: '🟡', serving: '1 piece (40g)'),
  FoodItem(name: 'Jalebi (2 pcs)', calories: 149, protein: 2.0, category: 'Sweets & Desserts', emoji: '🍩', serving: '2 pieces (50g)'),
  FoodItem(name: 'Rasgulla (2 pcs)', calories: 106, protein: 3.0, category: 'Sweets & Desserts', emoji: '⚪', serving: '2 pieces (70g)'),
  FoodItem(name: 'Gulab Jamun (2 pcs)', calories: 175, protein: 3.0, category: 'Sweets & Desserts', emoji: '🍮', serving: '2 pieces (60g)'),
  FoodItem(name: 'Mysore Pak (40g)', calories: 200, protein: 4.0, category: 'Sweets & Desserts', emoji: '🍬', serving: '40g'),
  FoodItem(name: 'Barfi (Milk)', calories: 160, protein: 4.0, category: 'Sweets & Desserts', emoji: '🍬', serving: '40g'),
  FoodItem(name: 'Chole Bhature (1 plate)', calories: 450, protein: 12.0, category: 'North Indian', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Pav Bhaji (1 plate)', calories: 350, protein: 8.0, category: 'North Indian', emoji: '🥖', serving: '2 pav + bhaji'),

  // ── Andhra & Telangana ────────────────────────────────────────────────────
  FoodItem(name: 'Pesarattu', calories: 105, protein: 5, category: 'Andhra & Telangana', emoji: '🫓', serving: '1 piece (80g)'),
  FoodItem(name: 'Gongura Chicken Curry', calories: 280, protein: 30, category: 'Andhra & Telangana', emoji: '🍗', serving: '200g'),
  FoodItem(name: 'Gongura Mutton', calories: 320, protein: 32, category: 'Andhra & Telangana', emoji: '🍖', serving: '200g'),
  FoodItem(name: 'Gongura Pickle', calories: 45, protein: 1, category: 'Andhra & Telangana', emoji: '🌿', serving: '1 tbsp (30g)'),
  FoodItem(name: 'Natu Kodi Curry (Country Chicken)', calories: 260, protein: 28, category: 'Andhra & Telangana', emoji: '🍗', serving: '200g'),
  FoodItem(name: 'Gutti Vankaya (Stuffed Brinjal)', calories: 180, protein: 4, category: 'Andhra & Telangana', emoji: '🍆', serving: '2 pieces (200g)'),
  FoodItem(name: 'Pappu (Andhra Dal)', calories: 130, protein: 8, category: 'Andhra & Telangana', emoji: '🫘', serving: '1 katori (150g)'),
  FoodItem(name: 'Chepala Pulusu (Andhra Fish Curry)', calories: 220, protein: 25, category: 'Andhra & Telangana', emoji: '🐟', serving: '200g'),
  FoodItem(name: 'Royyala Iguru (Andhra Prawn Curry)', calories: 240, protein: 26, category: 'Andhra & Telangana', emoji: '🦐', serving: '200g'),
  FoodItem(name: 'Pulusu (Tamarind Stew)', calories: 110, protein: 4, category: 'Andhra & Telangana', emoji: '🍲', serving: '1 bowl (150ml)'),
  FoodItem(name: 'Punugulu', calories: 180, protein: 5, category: 'Andhra & Telangana', emoji: '🧆', serving: '4 pieces'),
  FoodItem(name: 'Bobbatlu / Puran Poli', calories: 280, protein: 6, category: 'Andhra & Telangana', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Kodi Pulao (Andhra Chicken Pulao)', calories: 420, protein: 24, category: 'Andhra & Telangana', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Mudda Pappu Anna (Rice + Dal)', calories: 340, protein: 12, category: 'Andhra & Telangana', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Pesara Pappu (Green Moong Dal)', calories: 120, protein: 8, category: 'Andhra & Telangana', emoji: '🫘', serving: '1 katori (150g)'),
  FoodItem(name: 'Ariselu', calories: 190, protein: 3, category: 'Andhra & Telangana', emoji: '🍩', serving: '2 pieces'),
  FoodItem(name: 'Boorelu', calories: 160, protein: 4, category: 'Andhra & Telangana', emoji: '🟡', serving: '2 pieces'),
  FoodItem(name: 'Hyderabad Haleem', calories: 350, protein: 25, category: 'Andhra & Telangana', emoji: '🥘', serving: '1 bowl (250g)'),
  FoodItem(name: 'Mirchi Bajji (Andhra Chilli Fritter)', calories: 160, protein: 3, category: 'Andhra & Telangana', emoji: '🌶️', serving: '2 pieces'),
  FoodItem(name: 'Andhra Chicken Biryani', calories: 520, protein: 30, category: 'Andhra & Telangana', emoji: '🍛', serving: '1 plate'),

  // ── Karnataka ─────────────────────────────────────────────────────────────
  FoodItem(name: 'Bisi Bele Bath', calories: 200, protein: 7, category: 'Karnataka', emoji: '🍲', serving: '200g'),
  FoodItem(name: 'Set Dosa (2 pcs)', calories: 280, protein: 7, category: 'Karnataka', emoji: '🥞', serving: '2 dosas'),
  FoodItem(name: 'Akki Roti', calories: 130, protein: 3, category: 'Karnataka', emoji: '🫓', serving: '1 piece (~50g)'),
  FoodItem(name: 'Davanagere Benne Dosa', calories: 350, protein: 6, category: 'Karnataka', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Mysore Masala Dosa', calories: 320, protein: 7, category: 'Karnataka', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Obbattu / Holige', calories: 250, protein: 5, category: 'Karnataka', emoji: '🫓', serving: '1 piece'),
  FoodItem(name: 'Chiroti', calories: 200, protein: 3, category: 'Karnataka', emoji: '🫓', serving: '2 pieces'),
  FoodItem(name: 'Jolada Rotti (Jowar Flatbread)', calories: 105, protein: 3, category: 'Karnataka', emoji: '🫓', serving: '1 piece (~40g)'),
  FoodItem(name: 'Saaru (Karnataka Rasam)', calories: 40, protein: 2, category: 'Karnataka', emoji: '🍲', serving: '200ml'),
  FoodItem(name: 'Badnekai Gojju (Brinjal Curry)', calories: 150, protein: 3, category: 'Karnataka', emoji: '🍆', serving: '150g'),
  FoodItem(name: 'Palya (Karnataka Stir-fried Veggie)', calories: 90, protein: 2, category: 'Karnataka', emoji: '🥗', serving: '100g'),
  FoodItem(name: 'Shavige Bath (Vermicelli Upma)', calories: 170, protein: 4, category: 'Karnataka', emoji: '🥣', serving: '150g'),
  FoodItem(name: 'Kesari Bath', calories: 250, protein: 3, category: 'Karnataka', emoji: '🍮', serving: '100g'),
  FoodItem(name: 'Masala Vade (2 pcs)', calories: 150, protein: 6, category: 'Karnataka', emoji: '🍩', serving: '2 pieces'),
  FoodItem(name: 'Rave Unde (Semolina Ladoo)', calories: 80, protein: 2, category: 'Karnataka', emoji: '🟡', serving: '1 piece'),
  FoodItem(name: 'Mangalore Buns', calories: 200, protein: 4, category: 'Karnataka', emoji: '🫓', serving: '2 pieces'),
  FoodItem(name: 'Neer Dosa', calories: 120, protein: 2, category: 'Karnataka', emoji: '🫓', serving: '2 pieces'),
  FoodItem(name: 'Coorg Pork Curry', calories: 300, protein: 28, category: 'Karnataka', emoji: '🥘', serving: '150g'),
  FoodItem(name: 'Alasande Curry (Black Eyed Peas)', calories: 150, protein: 8, category: 'Karnataka', emoji: '🫘', serving: '150g'),

  // ── Salads & Light Meals ──────────────────────────────────────────────────
  FoodItem(name: 'Kachumber Salad', calories: 45, protein: 2, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Green Garden Salad', calories: 55, protein: 2, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Cucumber Raita', calories: 65, protein: 3, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Sprout Salad', calories: 90, protein: 6, category: 'Salads & Light Meals', emoji: '🌱', serving: '1 bowl (100g)'),
  FoodItem(name: 'Egg Salad with Mayo', calories: 210, protein: 12, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Caesar Salad (no croutons)', calories: 180, protein: 8, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Greek Salad', calories: 130, protein: 4, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Corn Salad', calories: 120, protein: 3, category: 'Salads & Light Meals', emoji: '🌽', serving: '1 bowl (150g)'),
  FoodItem(name: 'Paneer Salad', calories: 200, protein: 12, category: 'Salads & Light Meals', emoji: '🧀', serving: '1 bowl (150g)'),
  FoodItem(name: 'Chicken Salad', calories: 250, protein: 28, category: 'Salads & Light Meals', emoji: '🍗', serving: '1 bowl (200g)'),
  FoodItem(name: 'Tuna Salad', calories: 190, protein: 22, category: 'Salads & Light Meals', emoji: '🐟', serving: '1 bowl (150g)'),
  FoodItem(name: 'Carrot Peanut Salad', calories: 140, protein: 5, category: 'Salads & Light Meals', emoji: '🥕', serving: '1 bowl (100g)'),
  FoodItem(name: 'Mixed Vegetable Salad', calories: 60, protein: 2, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Beet Salad', calories: 75, protein: 2, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),
  FoodItem(name: 'Onion Tomato Salad', calories: 40, protein: 1, category: 'Salads & Light Meals', emoji: '🍅', serving: '1 bowl (150g)'),
  FoodItem(name: 'Boiled Chana Salad', calories: 165, protein: 9, category: 'Salads & Light Meals', emoji: '🫘', serving: '1 bowl (100g)'),
  FoodItem(name: 'Avocado Salad', calories: 160, protein: 3, category: 'Salads & Light Meals', emoji: '🥑', serving: '1/2 avocado + veg (150g)'),
  FoodItem(name: 'Thai Cucumber Salad', calories: 55, protein: 1, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (150g)'),

  // ── Eggs ─────────────────────────────────────────────────────────────────
  FoodItem(name: 'Boiled Egg (whole)', calories: 78, protein: 6, carbs: 0.6, fat: 5.3, category: 'Eggs', emoji: '🥚', serving: '1 egg'),
  FoodItem(name: 'Egg White (boiled)', calories: 17, protein: 3.6, category: 'Eggs', emoji: '🥚', serving: '1 white'),
  FoodItem(name: 'Fried Egg (sunny side)', calories: 90, protein: 6, category: 'Eggs', emoji: '🍳', serving: '1 egg'),
  FoodItem(name: 'Scrambled Eggs (2)', calories: 150, protein: 12, category: 'Eggs', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Egg Omelette (2 eggs)', calories: 165, protein: 13, category: 'Eggs', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Masala Omelette (2 eggs)', calories: 175, protein: 13, category: 'Eggs', emoji: '🍳', serving: '2 eggs + onion/chilli'),
  FoodItem(name: 'Egg Bhurji (2 eggs)', calories: 155, protein: 12, carbs: 3, fat: 10, category: 'Eggs', emoji: '🍳', serving: '2 eggs'),
  FoodItem(name: 'Egg Curry (2 eggs)', calories: 200, protein: 14, carbs: 6, fat: 13, category: 'Eggs', emoji: '🍛', serving: '2 eggs + gravy'),
  FoodItem(name: 'Egg Paratha', calories: 350, protein: 14, category: 'Eggs', emoji: '🫓', serving: '1 paratha + 1 egg'),
  FoodItem(name: 'Deviled Eggs (2)', calories: 150, protein: 11, category: 'Eggs', emoji: '🥚', serving: '2 halves'),
  FoodItem(name: 'Egg Drop Soup', calories: 75, protein: 6, category: 'Eggs', emoji: '🍜', serving: '1 bowl (250ml)'),
  FoodItem(name: 'Egg Sandwich', calories: 280, protein: 16, category: 'Eggs', emoji: '🥪', serving: '2 slices + 2 eggs'),
  FoodItem(name: 'Half Fry (1 egg)', calories: 90, protein: 6, category: 'Eggs', emoji: '🍳', serving: '1 egg'),

  // ── Fried & Grilled ───────────────────────────────────────────────────────
  FoodItem(name: 'Tandoori Chicken', calories: 250, protein: 35, category: 'Fried & Grilled', emoji: '🍗', serving: '200g'),
  FoodItem(name: 'Chicken Fry (Dry)', calories: 280, protein: 30, category: 'Fried & Grilled', emoji: '🍗', serving: '150g'),
  FoodItem(name: 'Mutton Fry', calories: 320, protein: 28, category: 'Fried & Grilled', emoji: '🍖', serving: '150g'),
  FoodItem(name: 'Fish Fry (Tawa)', calories: 230, protein: 26, category: 'Fried & Grilled', emoji: '🐟', serving: '150g'),
  FoodItem(name: 'Fish Tikka', calories: 200, protein: 28, category: 'Fried & Grilled', emoji: '🐟', serving: '150g'),
  FoodItem(name: 'Prawn Fry', calories: 220, protein: 22, category: 'Fried & Grilled', emoji: '🦐', serving: '150g'),
  FoodItem(name: 'Grilled Paneer', calories: 200, protein: 15, category: 'Fried & Grilled', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Paneer Tikka', calories: 230, protein: 19, carbs: 7, fat: 14, category: 'Fried & Grilled', emoji: '🍢', serving: '100g'),
  FoodItem(name: 'Veg Cutlet (2 pcs)', calories: 200, protein: 5, category: 'Fried & Grilled', emoji: '🥙', serving: '2 pieces'),
  FoodItem(name: 'Chicken Cutlet (2 pcs)', calories: 280, protein: 24, category: 'Fried & Grilled', emoji: '🥙', serving: '2 pieces'),
  FoodItem(name: 'Crispy Fried Chicken (KFC style)', calories: 290, protein: 22, category: 'Fried & Grilled', emoji: '🍗', serving: '1 piece (~100g)'),
  FoodItem(name: 'Bhajia / Mixed Pakora (4 pcs)', calories: 220, protein: 5, category: 'Fried & Grilled', emoji: '🧆', serving: '4 pieces'),
  FoodItem(name: 'Aloo Tikki (2 pcs)', calories: 200, protein: 4, category: 'Fried & Grilled', emoji: '🥔', serving: '2 pieces'),
  FoodItem(name: 'Stuffed Capsicum (1 pc)', calories: 160, protein: 6, category: 'Fried & Grilled', emoji: '🫑', serving: '1 piece (~150g)'),
  FoodItem(name: 'Grilled Chicken Breast', calories: 165, protein: 31, carbs: 0, fat: 3.6, category: 'Fried & Grilled', emoji: '🍗', serving: '100g'),
  FoodItem(name: 'Seekh Kebab (2 pcs)', calories: 220, protein: 22, category: 'Fried & Grilled', emoji: '🍢', serving: '2 pieces'),
  FoodItem(name: 'Shammi Kebab (2 pcs)', calories: 200, protein: 18, category: 'Fried & Grilled', emoji: '🍢', serving: '2 pieces'),
  FoodItem(name: 'Kakori Kebab (2 pcs)', calories: 220, protein: 16, category: 'Fried & Grilled', emoji: '🍢', serving: '2 pieces'),
  FoodItem(name: 'Hara Bhara Kebab (2 pcs)', calories: 140, protein: 5, category: 'Fried & Grilled', emoji: '🍢', serving: '2 pieces'),
  FoodItem(name: 'Masala Papad', calories: 80, protein: 3, category: 'Fried & Grilled', emoji: '🌾', serving: '1 piece'),
  FoodItem(name: 'Fried Papad', calories: 130, protein: 4, category: 'Fried & Grilled', emoji: '🌾', serving: '1 piece'),

  // ── Middle Eastern / Shawarma ─────────────────────────────────────────────
  FoodItem(name: 'Chicken Shawarma (Wrap)', calories: 450, protein: 30, category: 'Fast Food', emoji: '🌯', serving: '1 wrap (~250g)'),
  FoodItem(name: 'Mutton Shawarma (Wrap)', calories: 520, protein: 28, category: 'Fast Food', emoji: '🌯', serving: '1 wrap (~250g)'),
  FoodItem(name: 'Veg Shawarma (Wrap)', calories: 350, protein: 10, category: 'Fast Food', emoji: '🌯', serving: '1 wrap (~200g)'),
  FoodItem(name: 'Shawarma Plate (Chicken)', calories: 580, protein: 38, category: 'Fast Food', emoji: '🍽️', serving: '1 plate with rice'),
  FoodItem(name: 'Falafel Wrap', calories: 380, protein: 12, category: 'Fast Food', emoji: '🌯', serving: '1 wrap'),
  FoodItem(name: 'Hummus with Pita', calories: 280, protein: 9, category: 'Fast Food', emoji: '🫓', serving: '3 tbsp hummus + 1 pita'),
  FoodItem(name: 'Kebab Roll', calories: 420, protein: 28, category: 'Fast Food', emoji: '🌯', serving: '1 roll'),

  // ── More Andhra & Telangana ───────────────────────────────────────────────
  FoodItem(name: 'Vankaya Iguru (Andhra Brinjal Fry)', calories: 160, protein: 3, category: 'Andhra & Telangana', emoji: '🍆', serving: '150g'),
  FoodItem(name: 'Bendakaya Fry (Okra/Bhindi Fry)', calories: 130, protein: 3, category: 'Andhra & Telangana', emoji: '🌿', serving: '150g'),
  FoodItem(name: 'Aloo Iguru (Andhra Potato Fry)', calories: 180, protein: 3, category: 'Andhra & Telangana', emoji: '🥔', serving: '150g'),
  FoodItem(name: 'Tomato Pappu (Tomato Dal)', calories: 135, protein: 8, category: 'Andhra & Telangana', emoji: '🍅', serving: '1 katori (150g)'),
  FoodItem(name: 'Spinach Pappu (Palakura Pappu)', calories: 130, protein: 9, category: 'Andhra & Telangana', emoji: '🥬', serving: '1 katori (150g)'),
  FoodItem(name: 'Mamidikaya Pappu (Raw Mango Dal)', calories: 140, protein: 8, category: 'Andhra & Telangana', emoji: '🥭', serving: '1 katori (150g)'),
  FoodItem(name: 'Charu (Andhra Rasam)', calories: 40, protein: 2, category: 'Andhra & Telangana', emoji: '🍲', serving: '1 cup (200ml)'),
  FoodItem(name: 'Kodi Vepudu (Andhra Chicken Fry)', calories: 290, protein: 30, category: 'Andhra & Telangana', emoji: '🍗', serving: '200g'),
  FoodItem(name: 'Ragi Sangati', calories: 180, protein: 4, category: 'Andhra & Telangana', emoji: '🌾', serving: '200g ball'),
  FoodItem(name: 'Gongura Pachadi (Sorrel Chutney)', calories: 50, protein: 1, category: 'Andhra & Telangana', emoji: '🌿', serving: '2 tbsp (40g)'),
  FoodItem(name: 'Avakaya (Raw Mango Pickle)', calories: 35, protein: 0.5, category: 'Andhra & Telangana', emoji: '🥭', serving: '1 tbsp (20g)'),
  FoodItem(name: 'Pesarapappu Payasam', calories: 210, protein: 7, category: 'Andhra & Telangana', emoji: '🍮', serving: '1 bowl (150ml)'),
  FoodItem(name: 'Andhra Meals Thali (Veg)', calories: 780, protein: 22, category: 'Andhra & Telangana', emoji: '🍽️', serving: '1 full thali'),
  FoodItem(name: 'Andhra Meals Thali (Non-Veg)', calories: 950, protein: 45, category: 'Andhra & Telangana', emoji: '🍽️', serving: '1 full thali'),
  FoodItem(name: 'Bamboo Chicken (Gudala Kodi)', calories: 320, protein: 35, category: 'Andhra & Telangana', emoji: '🎋', serving: '200g'),
  FoodItem(name: 'Natukodi Pulusu (Country Chicken Stew)', calories: 270, protein: 30, category: 'Andhra & Telangana', emoji: '🍗', serving: '200g'),
  FoodItem(name: 'Mutton Pulusu', calories: 310, protein: 28, category: 'Andhra & Telangana', emoji: '🍖', serving: '200g'),

  // ── Gym & Fitness Foods ────────────────────────────────────────────────────
  FoodItem(name: 'Protein Pancakes (2)', calories: 260, protein: 22, category: 'Breakfast', emoji: '🥞', serving: '2 pancakes'),
  FoodItem(name: 'Overnight Oats (banana+PB)', calories: 320, protein: 12, category: 'Breakfast', emoji: '🥣', serving: '1 jar (300ml)'),
  FoodItem(name: 'Egg White Bhurji (4 whites)', calories: 70, protein: 15, category: 'Protein', emoji: '🥚', serving: '4 whites'),
  FoodItem(name: 'Boiled Chicken + Rice Bowl', calories: 400, protein: 38, category: 'Protein', emoji: '🍗', serving: '1 bowl'),
  FoodItem(name: 'Tuna Rice Bowl', calories: 360, protein: 32, category: 'Protein', emoji: '🐟', serving: '1 bowl'),
  FoodItem(name: 'Paneer Scramble (100g)', calories: 195, protein: 16, category: 'Protein', emoji: '🧀', serving: '100g paneer + 2 eggs'),
  FoodItem(name: 'Cottage Cheese (low fat)', calories: 82, protein: 11, category: 'Protein', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Greek Yogurt with Honey', calories: 135, protein: 10, category: 'Protein', emoji: '🥛', serving: '150g + 1 tsp honey'),
  FoodItem(name: 'Protein Oats (whey added)', calories: 250, protein: 27, category: 'Protein', emoji: '🥣', serving: '40g oats + 1 scoop whey'),
  FoodItem(name: 'Boiled Sweet Potato', calories: 86, protein: 1.6, category: 'Breakfast', emoji: '🍠', serving: '100g'),
  FoodItem(name: 'Roasted Chickpeas', calories: 180, protein: 9, category: 'Snacks', emoji: '🫘', serving: '50g'),
  FoodItem(name: 'Rice Cakes (2)', calories: 70, protein: 1.5, category: 'Snacks', emoji: '🍘', serving: '2 cakes (18g)'),
  FoodItem(name: 'Hummus (3 tbsp)', calories: 115, protein: 5, category: 'Snacks', emoji: '🫙', serving: '3 tbsp (60g)'),
  FoodItem(name: 'Mixed Seed Mix (30g)', calories: 165, protein: 5.5, category: 'Snacks', emoji: '🌱', serving: '30g'),
  FoodItem(name: 'Peanut Butter Banana Toast', calories: 290, protein: 9, category: 'Breakfast', emoji: '🍞', serving: '2 slices + PB + banana'),
  FoodItem(name: 'Avocado Toast (1 slice)', calories: 195, protein: 4, category: 'Breakfast', emoji: '🥑', serving: '1 slice + 1/2 avocado'),
  FoodItem(name: 'Smoothie (Banana+Milk+PB)', calories: 350, protein: 15, category: 'Drinks', emoji: '🥤', serving: '1 glass (350ml)'),
  FoodItem(name: 'Green Smoothie (Spinach+Banana)', calories: 160, protein: 4, category: 'Drinks', emoji: '🥤', serving: '1 glass (300ml)'),
  FoodItem(name: 'Soya Milk (250ml)', calories: 100, protein: 8, category: 'Drinks', emoji: '🥛', serving: '250ml'),
  FoodItem(name: 'Almond Milk (250ml)', calories: 40, protein: 1.5, category: 'Drinks', emoji: '🥛', serving: '250ml'),

  // ── More Vegetables & Sides ────────────────────────────────────────────────
  FoodItem(name: 'Steamed Broccoli', calories: 34, protein: 2.8, category: 'Salads & Light Meals', emoji: '🥦', serving: '100g'),
  FoodItem(name: 'Stir-fried Mushrooms', calories: 50, protein: 3.5, category: 'Salads & Light Meals', emoji: '🍄', serving: '100g'),
  FoodItem(name: 'Baked Sweet Potato', calories: 103, protein: 2.3, category: 'Salads & Light Meals', emoji: '🍠', serving: '150g'),
  FoodItem(name: 'Palak Soup', calories: 70, protein: 3, category: 'Salads & Light Meals', emoji: '🍵', serving: '1 bowl (250ml)'),
  FoodItem(name: 'Tomato Soup (homemade)', calories: 80, protein: 2, category: 'Salads & Light Meals', emoji: '🍅', serving: '1 bowl (250ml)'),
  FoodItem(name: 'Mushroom Soup', calories: 95, protein: 3, category: 'Salads & Light Meals', emoji: '🍄', serving: '1 bowl (250ml)'),
  FoodItem(name: 'Carrot Soup', calories: 75, protein: 1.5, category: 'Salads & Light Meals', emoji: '🥕', serving: '1 bowl (250ml)'),
  FoodItem(name: 'Cucumber Slices', calories: 15, protein: 0.7, category: 'Salads & Light Meals', emoji: '🥒', serving: '100g'),
  FoodItem(name: 'Roasted Vegetables', calories: 80, protein: 2.5, category: 'Salads & Light Meals', emoji: '🥗', serving: '150g'),

  // ── More Regional Indian ───────────────────────────────────────────────────
  FoodItem(name: 'Solkadhi', calories: 50, protein: 1, category: 'South Indian', emoji: '🍹', serving: '1 glass (200ml)'),
  FoodItem(name: 'Kori Rotti (Tulu Chicken Curry)', calories: 420, protein: 32, category: 'Karnataka', emoji: '🍗', serving: '1 plate'),
  FoodItem(name: 'Neer Dosa with Chicken Curry', calories: 340, protein: 22, category: 'Karnataka', emoji: '🫓', serving: '2 dosas + curry'),
  FoodItem(name: 'Mangalore Fish Curry', calories: 210, protein: 24, category: 'Karnataka', emoji: '🐟', serving: '200g'),
  FoodItem(name: 'Pathrode (Taro Leaf Rolls)', calories: 160, protein: 3, category: 'Karnataka', emoji: '🌿', serving: '2 pieces (100g)'),
  FoodItem(name: 'Veg Stew (Kerala)', calories: 120, protein: 3.5, category: 'South Indian', emoji: '🥘', serving: '1 bowl'),
  FoodItem(name: 'Karimeen Pollichathu', calories: 250, protein: 28, category: 'South Indian', emoji: '🐟', serving: '1 fish (200g)'),
  FoodItem(name: 'Dum Aloo', calories: 200, protein: 4, category: 'North Indian', emoji: '🥔', serving: '1 katori (150g)'),
  FoodItem(name: 'Aloo Jeera', calories: 155, protein: 3, category: 'North Indian', emoji: '🥔', serving: '1 katori (150g)'),
  FoodItem(name: 'Batata Vada', calories: 185, protein: 4, category: 'Street Food', emoji: '🥟', serving: '1 piece'),
  FoodItem(name: 'Dabba Gosht (Mutton)', calories: 380, protein: 30, category: 'North Indian', emoji: '🍖', serving: '1 serving (200g)'),
  FoodItem(name: 'Keema Matar', calories: 310, protein: 26, category: 'North Indian', emoji: '🥩', serving: '1 katori (150g)'),
  FoodItem(name: 'Nihari', calories: 350, protein: 28, category: 'North Indian', emoji: '🍖', serving: '200g'),
  FoodItem(name: 'Rogan Josh (Mutton)', calories: 320, protein: 26, category: 'North Indian', emoji: '🍖', serving: '200g'),
  FoodItem(name: 'Mutton Biryani', calories: 540, protein: 30, carbs: 56, fat: 21, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Hyderabad Dum Biryani (Veg)', calories: 380, protein: 8, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Ambur Star Biryani', calories: 500, protein: 26, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Dindigul Biryani', calories: 480, protein: 25, category: 'Rice & Biryani', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Mandi (Chicken)', calories: 600, protein: 40, category: 'Rice & Biryani', emoji: '🍗', serving: '1 plate'),

  // ── Supplement ────────────────────────────────────────────────────────────
  FoodItem(name: 'Whey Protein (1 scoop)', calories: 130, protein: 25, category: 'Supplement', emoji: '💪', serving: '1 scoop (33g)'),
  FoodItem(name: 'Creatine', calories: 0, protein: 0, category: 'Supplement', emoji: '⚡', serving: '5g'),
  FoodItem(name: 'BCAA (1 serving)', calories: 20, protein: 5, category: 'Supplement', emoji: '💊', serving: '1 scoop'),
  FoodItem(name: 'Mass Gainer (1 scoop)', calories: 380, protein: 28, category: 'Supplement', emoji: '💪', serving: '1 scoop (100g)'),
  FoodItem(name: 'Multivitamin Tablet', calories: 5, protein: 0, category: 'Supplement', emoji: '💊', serving: '1 tablet'),
  FoodItem(name: 'Casein Protein (1 scoop)', calories: 120, protein: 24, category: 'Supplement', emoji: '💪', serving: '1 scoop (34g)'),

  // ── Gobi / Cauliflower dishes ───────────────────────────────────────────────
  FoodItem(name: 'Gobi 65', calories: 230, protein: 6, category: 'Indo-Chinese', emoji: '🍛', serving: '1 plate (150g)'),
  FoodItem(name: 'Gobi Manchurian (Dry)', calories: 250, protein: 6, category: 'Indo-Chinese', emoji: '🥦', serving: '1 plate (150g)'),
  FoodItem(name: 'Gobi Manchurian (Gravy)', calories: 280, protein: 7, category: 'Indo-Chinese', emoji: '🥦', serving: '1 plate (200g)'),
  FoodItem(name: 'Aloo Gobi', calories: 180, protein: 5, category: 'North Indian', emoji: '🥔', serving: '1 katori (150g)'),
  FoodItem(name: 'Gobi Paratha', calories: 210, protein: 6, category: 'Roti & Bread', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Gobi Fried Rice', calories: 320, protein: 8, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Cauliflower (steamed)', calories: 25, protein: 2, category: 'Salads & Light Meals', emoji: '🥦', serving: '100g'),

  // ── Chicken popcorn & fried chicken ────────────────────────────────────────
  FoodItem(name: 'Chicken Popcorn', calories: 290, protein: 18, category: 'Fast Food', emoji: '🍗', serving: '1 serving (100g)'),
  FoodItem(name: 'Chicken Nuggets (6 pc)', calories: 270, protein: 15, category: 'Fast Food', emoji: '🍗', serving: '6 pieces'),
  FoodItem(name: 'Chicken Strips (3 pc)', calories: 300, protein: 22, category: 'Fast Food', emoji: '🍗', serving: '3 strips'),
  FoodItem(name: 'Fried Chicken (1 pc)', calories: 320, protein: 22, category: 'Fast Food', emoji: '🍗', serving: '1 piece'),
  FoodItem(name: 'Chicken Lollipop (4 pc)', calories: 350, protein: 26, category: 'Indo-Chinese', emoji: '🍗', serving: '4 pieces'),
  FoodItem(name: 'Chilli Chicken (Dry)', calories: 300, protein: 28, category: 'Indo-Chinese', emoji: '🌶️', serving: '1 plate (150g)'),
  FoodItem(name: 'Chicken 65', calories: 290, protein: 27, category: 'South Indian', emoji: '🍗', serving: '1 plate (150g)'),
  FoodItem(name: 'Chicken Manchurian', calories: 310, protein: 26, category: 'Indo-Chinese', emoji: '🍗', serving: '1 plate (200g)'),

  // ── Ice cream & frozen desserts ────────────────────────────────────────────
  FoodItem(name: 'Vanilla Ice Cream', calories: 210, protein: 4, category: 'Sweets & Desserts', emoji: '🍨', serving: '1 scoop (100g)'),
  FoodItem(name: 'Chocolate Ice Cream', calories: 230, protein: 4, category: 'Sweets & Desserts', emoji: '🍫', serving: '1 scoop (100g)'),
  FoodItem(name: 'Butterscotch Ice Cream', calories: 240, protein: 4, category: 'Sweets & Desserts', emoji: '🍨', serving: '1 scoop (100g)'),
  FoodItem(name: 'Mango Ice Cream', calories: 220, protein: 3.5, category: 'Sweets & Desserts', emoji: '🥭', serving: '1 scoop (100g)'),
  FoodItem(name: 'Kulfi', calories: 200, protein: 5, category: 'Sweets & Desserts', emoji: '🍡', serving: '1 piece (80g)'),
  FoodItem(name: 'Matka Kulfi', calories: 240, protein: 6, category: 'Sweets & Desserts', emoji: '🍡', serving: '1 matka'),
  FoodItem(name: 'Ice Cream Sundae', calories: 350, protein: 6, category: 'Sweets & Desserts', emoji: '🍨', serving: '1 sundae'),
  FoodItem(name: 'Choco Bar', calories: 180, protein: 2.5, category: 'Sweets & Desserts', emoji: '🍫', serving: '1 bar'),
  FoodItem(name: 'Cassata Slice', calories: 260, protein: 5, category: 'Sweets & Desserts', emoji: '🍰', serving: '1 slice'),
  FoodItem(name: 'Falooda', calories: 320, protein: 7, category: 'Sweets & Desserts', emoji: '🍨', serving: '1 glass'),

  // ── More Indian sweets ─────────────────────────────────────────────────────
  FoodItem(name: 'Gulab Jamun (2 pc)', calories: 300, protein: 4, category: 'Sweets & Desserts', emoji: '🍮', serving: '2 pieces'),
  FoodItem(name: 'Rasgulla (2 pc)', calories: 250, protein: 5, category: 'Sweets & Desserts', emoji: '⚪', serving: '2 pieces'),
  FoodItem(name: 'Jalebi (100g)', calories: 380, protein: 3, category: 'Sweets & Desserts', emoji: '🍥', serving: '100g'),
  FoodItem(name: 'Rasmalai (1 pc)', calories: 180, protein: 6, category: 'Sweets & Desserts', emoji: '🍮', serving: '1 piece'),
  FoodItem(name: 'Kaju Katli (3 pc)', calories: 200, protein: 4, category: 'Sweets & Desserts', emoji: '🔶', serving: '3 pieces'),
  FoodItem(name: 'Soan Papdi (1 pc)', calories: 150, protein: 2, category: 'Sweets & Desserts', emoji: '🟨', serving: '1 piece'),
  FoodItem(name: 'Mysore Pak (1 pc)', calories: 240, protein: 3, category: 'Sweets & Desserts', emoji: '🟧', serving: '1 piece'),
  FoodItem(name: 'Ladoo (Besan, 1 pc)', calories: 185, protein: 4, category: 'Sweets & Desserts', emoji: '🟡', serving: '1 ladoo'),
  FoodItem(name: 'Kheer / Payasam', calories: 250, protein: 6, category: 'Sweets & Desserts', emoji: '🥣', serving: '1 bowl'),
  FoodItem(name: 'Gajar Halwa', calories: 320, protein: 5, category: 'Sweets & Desserts', emoji: '🥕', serving: '1 bowl (150g)'),

  // ── More street food & snacks ──────────────────────────────────────────────
  FoodItem(name: 'Pani Puri (6 pc)', calories: 180, protein: 4, category: 'Street Food', emoji: '🥟', serving: '6 puris'),
  FoodItem(name: 'Bhel Puri', calories: 250, protein: 6, category: 'Street Food', emoji: '🥗', serving: '1 plate'),
  FoodItem(name: 'Sev Puri', calories: 280, protein: 6, category: 'Street Food', emoji: '🥟', serving: '1 plate'),
  FoodItem(name: 'Dahi Puri', calories: 260, protein: 7, category: 'Street Food', emoji: '🥟', serving: '1 plate'),
  FoodItem(name: 'Aloo Tikki (2 pc)', calories: 230, protein: 5, category: 'Street Food', emoji: '🥔', serving: '2 pieces'),
  FoodItem(name: 'Samosa', calories: 260, protein: 5, category: 'Street Food', emoji: '🥟', serving: '1 piece'),
  FoodItem(name: 'Kachori', calories: 280, protein: 6, category: 'Street Food', emoji: '🥮', serving: '1 piece'),
  FoodItem(name: 'Vada Pav', calories: 290, protein: 8, category: 'Street Food', emoji: '🍔', serving: '1 piece'),
  FoodItem(name: 'Pav Bhaji', calories: 400, protein: 10, carbs: 52, fat: 16, category: 'Street Food', emoji: '🍛', serving: '1 plate (2 pav)'),
  FoodItem(name: 'Frankie / Kathi Roll', calories: 350, protein: 14, category: 'Street Food', emoji: '🌯', serving: '1 roll'),
  FoodItem(name: 'Momos (Veg, 6 pc)', calories: 220, protein: 7, category: 'Street Food', emoji: '🥟', serving: '6 pieces'),
  FoodItem(name: 'Momos (Chicken, 6 pc)', calories: 260, protein: 14, category: 'Street Food', emoji: '🥟', serving: '6 pieces'),
  FoodItem(name: 'Spring Roll (Veg)', calories: 180, protein: 4, category: 'Indo-Chinese', emoji: '🌯', serving: '1 roll'),

  // ── More fast food ─────────────────────────────────────────────────────────
  FoodItem(name: 'Veg Burger', calories: 350, protein: 10, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'Chicken Burger', calories: 450, protein: 23, category: 'Fast Food', emoji: '🍔', serving: '1 burger'),
  FoodItem(name: 'French Fries', calories: 320, protein: 4, category: 'Fast Food', emoji: '🍟', serving: 'medium (110g)'),
  FoodItem(name: 'Peri Peri Fries', calories: 350, protein: 5, category: 'Fast Food', emoji: '🍟', serving: 'medium'),
  FoodItem(name: 'Margherita Pizza (1 slice)', calories: 250, protein: 11, category: 'Fast Food', emoji: '🍕', serving: '1 slice'),
  FoodItem(name: 'Chicken Pizza (1 slice)', calories: 290, protein: 14, category: 'Fast Food', emoji: '🍕', serving: '1 slice'),
  FoodItem(name: 'Garlic Bread (2 pc)', calories: 200, protein: 6, category: 'Fast Food', emoji: '🥖', serving: '2 pieces'),
  FoodItem(name: 'Pasta (White Sauce)', calories: 400, protein: 12, category: 'Fast Food', emoji: '🍝', serving: '1 plate'),
  FoodItem(name: 'Pasta (Red Sauce)', calories: 350, protein: 11, category: 'Fast Food', emoji: '🍝', serving: '1 plate'),
  FoodItem(name: 'Hot Dog', calories: 290, protein: 11, category: 'Fast Food', emoji: '🌭', serving: '1 hot dog'),

  // ── More Indo-Chinese ──────────────────────────────────────────────────────
  FoodItem(name: 'Veg Fried Rice', calories: 330, protein: 7, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Chicken Fried Rice', calories: 380, protein: 18, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Egg Fried Rice', calories: 350, protein: 12, category: 'Indo-Chinese', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Veg Hakka Noodles', calories: 340, protein: 8, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Chicken Noodles', calories: 390, protein: 19, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Schezwan Noodles', calories: 380, protein: 9, category: 'Indo-Chinese', emoji: '🍜', serving: '1 plate'),
  FoodItem(name: 'Manchow Soup', calories: 120, protein: 5, category: 'Indo-Chinese', emoji: '🍲', serving: '1 bowl'),
  FoodItem(name: 'Sweet Corn Soup', calories: 110, protein: 4, category: 'Indo-Chinese', emoji: '🌽', serving: '1 bowl'),
  FoodItem(name: 'Paneer Chilli (Dry)', calories: 320, protein: 16, category: 'Indo-Chinese', emoji: '🌶️', serving: '1 plate'),
  FoodItem(name: 'Paneer Manchurian', calories: 340, protein: 15, category: 'Indo-Chinese', emoji: '🧀', serving: '1 plate'),

  // ── More paneer & North Indian ─────────────────────────────────────────────
  FoodItem(name: 'Paneer Butter Masala', calories: 350, protein: 14, category: 'North Indian', emoji: '🧀', serving: '1 katori (200g)'),
  FoodItem(name: 'Palak Paneer', calories: 280, protein: 15, category: 'North Indian', emoji: '🥬', serving: '1 katori (200g)'),
  FoodItem(name: 'Kadai Paneer', calories: 320, protein: 15, category: 'North Indian', emoji: '🧀', serving: '1 katori (200g)'),
  FoodItem(name: 'Shahi Paneer', calories: 360, protein: 14, category: 'North Indian', emoji: '🧀', serving: '1 katori (200g)'),
  FoodItem(name: 'Matar Paneer', calories: 300, protein: 13, category: 'North Indian', emoji: '🟢', serving: '1 katori (200g)'),
  FoodItem(name: 'Chana Masala', calories: 260, protein: 11, category: 'North Indian', emoji: '🫘', serving: '1 katori (200g)'),
  FoodItem(name: 'Rajma', calories: 245, protein: 12, category: 'Dal & Curry', emoji: '🫘', serving: '1 katori (200g)'),
  FoodItem(name: 'Chole Bhature', calories: 480, protein: 13, category: 'North Indian', emoji: '🍛', serving: '1 plate'),
  FoodItem(name: 'Butter Chicken', calories: 420, protein: 30, category: 'North Indian', emoji: '🍗', serving: '1 katori (200g)'),
  FoodItem(name: 'Chicken Tikka Masala', calories: 380, protein: 32, category: 'North Indian', emoji: '🍗', serving: '1 katori (200g)'),
  FoodItem(name: 'Egg Curry (2 eggs)', calories: 280, protein: 16, carbs: 8, fat: 20, category: 'Dal & Curry', emoji: '🥚', serving: '1 katori'),
  FoodItem(name: 'Fish Curry', calories: 250, protein: 26, carbs: 6, fat: 13, category: 'Dal & Curry', emoji: '🐟', serving: '1 katori (200g)'),
  FoodItem(name: 'Prawn Masala', calories: 230, protein: 24, category: 'Dal & Curry', emoji: '🦐', serving: '1 katori (150g)'),

  // ── More breakfast & tiffin ────────────────────────────────────────────────
  FoodItem(name: 'Masala Dosa', calories: 250, protein: 6, carbs: 37, fat: 8.5, category: 'Breakfast', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Plain Dosa', calories: 170, protein: 4, category: 'Breakfast', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Idli (2 pc)', calories: 120, protein: 4, category: 'Breakfast', emoji: '⚪', serving: '2 idlis'),
  FoodItem(name: 'Medu Vada (2 pc)', calories: 280, protein: 7, category: 'Breakfast', emoji: '🍩', serving: '2 vadas'),
  FoodItem(name: 'Upma', calories: 250, protein: 6, category: 'Breakfast', emoji: '🥣', serving: '1 bowl'),
  FoodItem(name: 'Poha', calories: 270, protein: 5, category: 'Breakfast', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Aloo Paratha', calories: 280, protein: 7, category: 'Breakfast', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Paneer Paratha', calories: 300, protein: 12, category: 'Breakfast', emoji: '🫓', serving: '1 paratha'),
  FoodItem(name: 'Uttapam', calories: 230, protein: 6, category: 'Breakfast', emoji: '🥞', serving: '1 uttapam'),
  FoodItem(name: 'Pongal', calories: 280, protein: 8, category: 'Breakfast', emoji: '🍚', serving: '1 bowl'),
  FoodItem(name: 'Bread Omelette', calories: 320, protein: 16, category: 'Breakfast', emoji: '🍳', serving: '2 bread + 2 eggs'),

  // ── More fruits, dairy & drinks ────────────────────────────────────────────
  FoodItem(name: 'Banana', calories: 105, protein: 1.3, carbs: 27, fat: 0.4, category: 'Fruits', emoji: '🍌', serving: '1 medium'),
  FoodItem(name: 'Apple', calories: 95, protein: 0.5, carbs: 25, fat: 0.3, category: 'Fruits', emoji: '🍎', serving: '1 medium'),
  FoodItem(name: 'Mango', calories: 150, protein: 1, carbs: 38, fat: 0.6, category: 'Fruits', emoji: '🥭', serving: '1 medium'),
  FoodItem(name: 'Papaya (1 cup)', calories: 60, protein: 1, category: 'Fruits', emoji: '🍈', serving: '1 cup'),
  FoodItem(name: 'Watermelon (1 cup)', calories: 46, protein: 1, category: 'Fruits', emoji: '🍉', serving: '1 cup'),
  FoodItem(name: 'Pomegranate (1 cup)', calories: 145, protein: 3, category: 'Fruits', emoji: '🔴', serving: '1 cup'),
  FoodItem(name: 'Grapes (1 cup)', calories: 100, protein: 1, category: 'Fruits', emoji: '🍇', serving: '1 cup'),
  FoodItem(name: 'Curd / Dahi (1 cup)', calories: 100, protein: 9, category: 'Dairy', emoji: '🥛', serving: '1 cup (200g)'),
  FoodItem(name: 'Lassi (Sweet)', calories: 260, protein: 8, category: 'Drinks', emoji: '🥛', serving: '1 glass'),
  FoodItem(name: 'Buttermilk / Chaas', calories: 60, protein: 3, category: 'Drinks', emoji: '🥛', serving: '1 glass'),
  FoodItem(name: 'Masala Chai', calories: 90, protein: 2, category: 'Drinks', emoji: '☕', serving: '1 cup'),
  FoodItem(name: 'Filter Coffee', calories: 80, protein: 2, category: 'Drinks', emoji: '☕', serving: '1 cup'),
  FoodItem(name: 'Cold Coffee', calories: 180, protein: 5, category: 'Drinks', emoji: '🥤', serving: '1 glass'),
  FoodItem(name: 'Mango Shake', calories: 250, protein: 6, category: 'Drinks', emoji: '🥭', serving: '1 glass'),
  FoodItem(name: 'Soft Drink (Cola)', calories: 140, protein: 0, category: 'Drinks', emoji: '🥤', serving: '330ml can'),
  FoodItem(name: 'Fresh Lime Soda', calories: 90, protein: 0, category: 'Drinks', emoji: '🍋', serving: '1 glass'),
  FoodItem(name: 'Coconut Water', calories: 45, protein: 1.7, category: 'Drinks', emoji: '🥥', serving: '1 glass'),

  // ── New items (full macros) ────────────────────────────────────────────────
  // Protein & lean staples
  FoodItem(name: 'Chicken Thigh (cooked)', calories: 209, protein: 26, carbs: 0, fat: 11, category: 'Protein', emoji: '🍗', serving: '100g'),
  FoodItem(name: 'Egg Whites (4, boiled)', calories: 68, protein: 14.4, carbs: 0.8, fat: 0.2, category: 'Protein', emoji: '🥚', serving: '4 whites'),
  FoodItem(name: 'Salmon (grilled)', calories: 208, protein: 22, carbs: 0, fat: 13, category: 'Protein', emoji: '🐟', serving: '100g'),
  FoodItem(name: 'Prawns (boiled)', calories: 99, protein: 24, carbs: 0.2, fat: 0.3, category: 'Protein', emoji: '🦐', serving: '100g'),
  FoodItem(name: 'Mutton Curry', calories: 280, protein: 24, carbs: 6, fat: 18, category: 'Protein', emoji: '🍖', serving: '150g'),
  FoodItem(name: 'Soya Bhurji', calories: 175, protein: 18, carbs: 10, fat: 6, category: 'Protein', emoji: '🌱', serving: '150g'),
  FoodItem(name: 'Rajma (cooked)', calories: 127, protein: 8.7, carbs: 22.8, fat: 0.5, category: 'Protein', emoji: '🫘', serving: '100g cooked'),
  FoodItem(name: 'Chickpeas (boiled)', calories: 164, protein: 8.9, carbs: 27, fat: 2.6, category: 'Protein', emoji: '🫘', serving: '100g cooked'),
  FoodItem(name: 'Cottage Cheese (paneer, low-fat)', calories: 206, protein: 24, carbs: 4, fat: 10, category: 'Protein', emoji: '🧀', serving: '100g'),
  FoodItem(name: 'Egg Bhurji (2 eggs)', calories: 190, protein: 13, carbs: 4, fat: 13, category: 'Protein', emoji: '🍳', serving: '2 eggs'),

  // Whole grains & carbs
  FoodItem(name: 'Sweet Potato (boiled)', calories: 86, protein: 1.6, carbs: 20, fat: 0.1, category: 'Breakfast', emoji: '🍠', serving: '100g'),
  FoodItem(name: 'Whole Wheat Pasta (cooked)', calories: 124, protein: 5, carbs: 25, fat: 1, category: 'Fast Food', emoji: '🍝', serving: '100g cooked'),
  FoodItem(name: 'Daliya (Broken Wheat) cooked', calories: 120, protein: 4, carbs: 25, fat: 0.7, category: 'Breakfast', emoji: '🌾', serving: '150g'),
  FoodItem(name: 'Multigrain Roti', calories: 110, protein: 3.5, carbs: 19, fat: 2.3, category: 'Roti & Bread', emoji: '🫓', serving: '1 roti (~40g)'),
  FoodItem(name: 'Khichdi (Moong Dal)', calories: 200, protein: 8, carbs: 35, fat: 3.5, category: 'North Indian', emoji: '🥣', serving: '1 bowl (200g)'),
  FoodItem(name: 'Vegetable Pulao', calories: 260, protein: 6, carbs: 44, fat: 7, category: 'Rice & Biryani', emoji: '🍚', serving: '1 plate'),
  FoodItem(name: 'Lemon Coriander Soup', calories: 60, protein: 2, carbs: 9, fat: 1.5, category: 'Salads & Light Meals', emoji: '🍲', serving: '1 bowl (250ml)'),

  // South Indian additions
  FoodItem(name: 'Ragi Dosa', calories: 130, protein: 3.5, carbs: 24, fat: 2.5, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Oats Dosa', calories: 145, protein: 5, carbs: 22, fat: 4, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Tomato Uttapam', calories: 220, protein: 6, carbs: 35, fat: 6, category: 'South Indian', emoji: '🥞', serving: '1 piece'),
  FoodItem(name: 'Onion Rava Dosa', calories: 210, protein: 4, carbs: 30, fat: 8, category: 'South Indian', emoji: '🫓', serving: '1 dosa'),
  FoodItem(name: 'Lemon Sevai', calories: 190, protein: 4, carbs: 36, fat: 4, category: 'South Indian', emoji: '🍜', serving: '1 plate'),

  // North Indian additions
  FoodItem(name: 'Stuffed Capsicum Sabzi', calories: 150, protein: 4, carbs: 14, fat: 9, category: 'North Indian', emoji: '🫑', serving: '1 katori (150g)'),
  FoodItem(name: 'Lauki Sabzi (Bottle Gourd)', calories: 95, protein: 2, carbs: 9, fat: 6, category: 'North Indian', emoji: '🥒', serving: '1 katori (150g)'),
  FoodItem(name: 'Tinda Masala', calories: 110, protein: 2.5, carbs: 11, fat: 7, category: 'North Indian', emoji: '🥬', serving: '1 katori (150g)'),
  FoodItem(name: 'Methi Malai Matar', calories: 230, protein: 6, carbs: 16, fat: 16, category: 'North Indian', emoji: '🟢', serving: '1 katori (150g)'),
  FoodItem(name: 'Veg Kolhapuri', calories: 200, protein: 5, carbs: 18, fat: 13, category: 'North Indian', emoji: '🥘', serving: '1 katori (150g)'),

  // Healthy / fitness additions
  FoodItem(name: 'Boiled Chana Chaat', calories: 180, protein: 9, carbs: 27, fat: 4, category: 'Salads & Light Meals', emoji: '🫘', serving: '1 bowl (150g)'),
  FoodItem(name: 'Moong Sprouts Salad', calories: 100, protein: 7, carbs: 16, fat: 0.6, category: 'Salads & Light Meals', emoji: '🌱', serving: '1 bowl (120g)'),
  FoodItem(name: 'Grilled Veg Skewers', calories: 120, protein: 4, carbs: 14, fat: 5, category: 'Salads & Light Meals', emoji: '🍢', serving: '1 skewer (150g)'),
  FoodItem(name: 'Quinoa Veg Bowl', calories: 280, protein: 9, carbs: 45, fat: 7, category: 'Salads & Light Meals', emoji: '🥗', serving: '1 bowl (250g)'),
  FoodItem(name: 'Egg & Avocado Bowl', calories: 320, protein: 16, carbs: 10, fat: 24, category: 'Protein', emoji: '🥑', serving: '1 bowl'),
  FoodItem(name: 'Protein Smoothie Bowl', calories: 300, protein: 24, carbs: 35, fat: 6, category: 'Breakfast', emoji: '🥣', serving: '1 bowl'),

  // Snacks & nuts
  FoodItem(name: 'Roasted Almonds (15g)', calories: 87, protein: 3.2, carbs: 3.3, fat: 7.5, category: 'Nuts & Seeds', emoji: '🌰', serving: '15g'),
  FoodItem(name: 'Pumpkin Seeds (15g)', calories: 84, protein: 4.5, carbs: 1.6, fat: 7, category: 'Nuts & Seeds', emoji: '🌱', serving: '15g'),
  FoodItem(name: 'Sunflower Seeds (15g)', calories: 88, protein: 3.1, carbs: 3, fat: 7.6, category: 'Nuts & Seeds', emoji: '🌻', serving: '15g'),
  FoodItem(name: 'Trail Mix (30g)', calories: 150, protein: 4, carbs: 14, fat: 9, category: 'Snacks', emoji: '🥜', serving: '30g'),
  FoodItem(name: 'Roasted Peanuts (30g)', calories: 170, protein: 7, carbs: 6, fat: 14, category: 'Snacks', emoji: '🥜', serving: '30g'),
  FoodItem(name: 'Energy Bar (Date & Nut)', calories: 180, protein: 5, carbs: 24, fat: 7, category: 'Snacks', emoji: '🍫', serving: '1 bar (45g)'),
  FoodItem(name: 'Dark Chocolate (20g)', calories: 120, protein: 1.5, carbs: 9, fat: 8.5, category: 'Snacks', emoji: '🍫', serving: '20g (70% cocoa)'),

  // Fruits additions
  FoodItem(name: 'Avocado', calories: 160, protein: 2, carbs: 9, fat: 15, category: 'Fruits', emoji: '🥑', serving: '100g'),
  FoodItem(name: 'Muskmelon (Cantaloupe)', calories: 34, protein: 0.8, carbs: 8, fat: 0.2, category: 'Fruits', emoji: '🍈', serving: '100g'),
  FoodItem(name: 'Pear', calories: 57, protein: 0.4, carbs: 15, fat: 0.1, category: 'Fruits', emoji: '🍐', serving: '1 medium (100g)'),
  FoodItem(name: 'Blueberries', calories: 57, protein: 0.7, carbs: 14, fat: 0.3, category: 'Fruits', emoji: '🫐', serving: '100g'),
  FoodItem(name: 'Litchi', calories: 66, protein: 0.8, carbs: 17, fat: 0.4, category: 'Fruits', emoji: '🍒', serving: '100g'),

  // Dairy & drinks additions
  FoodItem(name: 'Low-Fat Yogurt', calories: 63, protein: 5.3, carbs: 7, fat: 1.6, category: 'Dairy', emoji: '🥛', serving: '100g'),
  FoodItem(name: 'Cheese Slice (Cheddar)', calories: 70, protein: 4, carbs: 1, fat: 5.5, category: 'Dairy', emoji: '🧀', serving: '1 slice (20g)'),
  FoodItem(name: 'Paneer Tikka Skewer', calories: 180, protein: 13, carbs: 5, fat: 12, category: 'Fried & Grilled', emoji: '🍢', serving: '4 cubes (80g)'),
  FoodItem(name: 'Green Tea', calories: 2, protein: 0, carbs: 0.4, fat: 0, category: 'Drinks', emoji: '🍵', serving: '1 cup'),
  FoodItem(name: 'Whey + Banana Smoothie', calories: 290, protein: 28, carbs: 32, fat: 4, category: 'Drinks', emoji: '🥤', serving: '1 glass (350ml)'),
  FoodItem(name: 'Black Coffee (no sugar)', calories: 2, protein: 0.3, carbs: 0, fat: 0, category: 'Drinks', emoji: '☕', serving: '1 cup'),
];


// ─── SmartScaleEntry ──────────────────────────────────────────────────────────

class SmartScaleEntry {
  final String id;
  final DateTime date;
  final double weightKg;
  final double bodyFatPercent;    // %
  final double bodyFatKg;         // kg
  final double muscleMassKg;      // kg
  final double muscleMassPercent; // %
  final double leanBodyMassKg;    // kg
  final int biologicalAge;        // years
  final int visceralFatIndex;     // 1-59 index
  final double bmr;               // kcal (from scale)
  final double bodyWaterPercent;  // %
  final double boneMassKg;        // kg
  final double proteinPercent;    // %
  final double skeletalMuscleMassKg; // kg

  SmartScaleEntry({
    required this.id,
    required this.date,
    required this.weightKg,
    required this.bodyFatPercent,
    required this.bodyFatKg,
    required this.muscleMassKg,
    required this.muscleMassPercent,
    required this.leanBodyMassKg,
    required this.biologicalAge,
    required this.visceralFatIndex,
    required this.bmr,
    required this.bodyWaterPercent,
    required this.boneMassKg,
    required this.proteinPercent,
    required this.skeletalMuscleMassKg,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'date': date.toIso8601String(),
    'weightKg': weightKg, 'bodyFatPercent': bodyFatPercent,
    'bodyFatKg': bodyFatKg, 'muscleMassKg': muscleMassKg,
    'muscleMassPercent': muscleMassPercent, 'leanBodyMassKg': leanBodyMassKg,
    'biologicalAge': biologicalAge, 'visceralFatIndex': visceralFatIndex,
    'bmr': bmr, 'bodyWaterPercent': bodyWaterPercent,
    'boneMassKg': boneMassKg, 'proteinPercent': proteinPercent,
    'skeletalMuscleMassKg': skeletalMuscleMassKg,
  };

  factory SmartScaleEntry.fromJson(Map<String, dynamic> j) {
    DateTime dt;
    try {
      dt = DateTime.parse(j['date'] as String? ?? '');
    } catch (_) {
      dt = DateTime.now();
    }
    return SmartScaleEntry(
      id: (j['id'] as String?) ?? '',
      date: dt,
      weightKg: ((j['weightKg'] as num?) ?? 0).toDouble(),
      bodyFatPercent: ((j['bodyFatPercent'] as num?) ?? 0).toDouble(),
      bodyFatKg: ((j['bodyFatKg'] as num?) ?? 0).toDouble(),
      muscleMassKg: ((j['muscleMassKg'] as num?) ?? 0).toDouble(),
      muscleMassPercent: ((j['muscleMassPercent'] as num?) ?? 0).toDouble(),
      leanBodyMassKg: ((j['leanBodyMassKg'] as num?) ?? 0).toDouble(),
      biologicalAge: ((j['biologicalAge'] as num?) ?? 0).toInt(),
      visceralFatIndex: ((j['visceralFatIndex'] as num?) ?? 0).toInt(),
      bmr: ((j['bmr'] as num?) ?? 0).toDouble(),
      bodyWaterPercent: ((j['bodyWaterPercent'] as num?) ?? 0).toDouble(),
      boneMassKg: ((j['boneMassKg'] as num?) ?? 0).toDouble(),
      proteinPercent: ((j['proteinPercent'] as num?) ?? 0).toDouble(),
      skeletalMuscleMassKg: ((j['skeletalMuscleMassKg'] as num?) ?? 0).toDouble(),
    );
  }
}
