import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../services/haptics.dart';
import '../widgets/input_formatters.dart';
import '../models/models.dart';
import '../theme/app_tokens.dart';
import '../widgets/kit/kit.dart';
import 'package:uuid/uuid.dart';

/// A clean, category-based Material icon for an exercise — replaces the
/// inconsistent per-exercise emoji with the app's monoline icon language.
IconData _exerciseIcon(String name) {
  switch (ExerciseDatabase.categoryOf(name)) {
    case 'Chest':
      return Icons.sports_handball_rounded;
    case 'Back':
      return Icons.rowing_rounded;
    case 'Shoulders':
      return Icons.accessibility_new_rounded;
    case 'Biceps':
      return Icons.front_hand_rounded;
    case 'Triceps':
      return Icons.back_hand_rounded;
    case 'Legs':
      return Icons.directions_walk_rounded;
    case 'Forearms / Grip':
      return Icons.pan_tool_rounded;
    case 'Core':
      return Icons.self_improvement_rounded;
    case 'Full Body / Compound':
      return Icons.sports_gymnastics_rounded;
    case 'Cardio':
      return Icons.directions_run_rounded;
    default:
      return Icons.fitness_center_rounded;
  }
}

/// Summarises a set list honestly. When all sets share the same reps & weight
/// it reads "3×10 @20kg"; when sets vary it shows the rep range
/// ("3 sets · 8–12 reps") instead of misleadingly echoing only the first set.
String _formatSets(List<SetData> sets, {bool compact = false}) {
  if (sets.isEmpty) return '';
  final reps = sets.map((s) => s.reps).toList();
  final weights = sets.map((s) => s.weight).toList();
  final sameReps = reps.toSet().length == 1;
  final sameWeight = weights.toSet().length == 1;
  final w = weights.first;
  final wStr = w > 0 ? '${w.toStringAsFixed(1)}kg' : '';

  if (sameReps && sameWeight) {
    final sep = compact ? '@' : ' @ ';
    return compact
        ? '${sets.length}×${reps.first}${w > 0 ? '@$wStr' : ''}'
        : '${sets.length} set${sets.length == 1 ? '' : 's'} × ${reps.first} reps'
            '${w > 0 ? '$sep$wStr' : ''}';
  }
  // Varied sets — show count + rep range (and weight range if it varies).
  final lo = reps.reduce((a, b) => a < b ? a : b);
  final hi = reps.reduce((a, b) => a > b ? a : b);
  final repPart = lo == hi ? '$lo reps' : '$lo–$hi reps';
  return compact
      ? '${sets.length} sets · $repPart'
      : '${sets.length} sets · $repPart';
}

/// Builds a deep-copied, de-duplicated exercise list to re-log from today's
/// [sessions]. Every [SetData] is cloned so editing the in-progress builder can
/// never mutate the logged history. Names already present in [existing] (the
/// builder's current exercises) are skipped, and a name repeated across multiple
/// sessions collapses to its first occurrence — giving the de-duped union the
/// today-summary already displays. Pure + side-effect free for easy testing.
List<ExerciseLog> repeatExercises(
    List<WorkoutLog> sessions, List<ExerciseLog> existing) {
  final seen = existing.map((e) => e.name).toSet();
  final copied = <ExerciseLog>[];
  for (final w in sessions) {
    for (final ex in w.exercises) {
      if (!seen.add(ex.name)) continue; // already in builder or already copied
      copied.add(ExerciseLog(
        name: ex.name,
        sets: ex.sets
            .map((s) => SetData(reps: s.reps, weight: s.weight))
            .toList(),
      ));
    }
  }
  return copied;
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});
  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  final List<ExerciseLog> _exercises = [];
  String _workoutName = '';
  String? _selectedCategory;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _isSaving = false; // guard against double-tap duplicate save

  @override
  void initState() {
    super.initState();
    _workoutName = _defaultWorkoutName();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Day-of-week default name for a freshly started session (no gym jargon).
  String _defaultWorkoutName() {
    final weekday = DateTime.now().weekday;
    // Simple day-based names — no gym jargon (was "Push/Pull split")
    switch (weekday) {
      case 1:
        return 'Monday Workout';
      case 2:
        return 'Tuesday Workout';
      case 3:
        return 'Wednesday Workout';
      case 4:
        return 'Thursday Workout';
      case 5:
        return 'Friday Workout';
      case 6:
        return 'Weekend Workout';
      default:
        return 'Sunday Workout';
    }
  }

  int get _estimatedCalories {
    final provider = context.read<FitnessProvider>();
    final dummy = WorkoutLog(
      id: 'tmp',
      date: DateTime.now(),
      name: _workoutName,
      exercises: _exercises,
    );
    return provider.calculateWorkoutCalories(dummy);
  }

  void _addExercise(String exerciseName) {
    _showSetEntryDialog(exerciseName);
  }

  void _showSetEntryDialog(String exerciseName) {
    final provider = context.read<FitnessProvider>();
    final lastWeight = provider.getLastExerciseWeight(exerciseName);
    final lastReps = provider.getLastExerciseReps(exerciseName);
    final pr = provider.getPersonalRecord(exerciseName);
    // Cardio is logged by minutes (stored in reps), not sets/reps/weight.
    final isCardio = ExerciseDatabase.isCardio(exerciseName);

    final setsCtrl = TextEditingController(text: '3');
    final repsCtrl = TextEditingController(text: (lastReps ?? 10).toString());
    final weightCtrl = TextEditingController(
      text: lastWeight != null ? lastWeight.toStringAsFixed(1) : '0',
    );

    // Resolve exercise info for the info panel.
    final info = ExerciseDatabase.infoFor(exerciseName);
    final primaryMuscle =
        info?.$1 ?? ExerciseDatabase.categoryOf(exerciseName) ?? '';
    final secondaryMuscles =
        (info?.$2 ?? '').isNotEmpty ? (info!.$2).split(' · ') : <String>[];
    final formTip = info?.$3 ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassSheet(
        child: Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            color: Colors.transparent,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Drag handle ──────────────────────────────────────────
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF8E8E93).withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Exercise title ───────────────────────────────────────
                  Text(
                    exerciseName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),

                  // ── Info panel ───────────────────────────────────────────
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      // Primary muscle chip (green-tinted)
                      if (primaryMuscle.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF30D158).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            primaryMuscle,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF30D158)),
                          ),
                        ),
                      // Secondary muscle chips (neutral)
                      for (final muscle in secondaryMuscles)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            muscle,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white70),
                          ),
                        ),
                    ],
                  ),

                  // Form cue (only when we have a known info entry with a tip)
                  if (formTip.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.tips_and_updates_outlined,
                          size: 14,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            formTip,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),

                  // ── PR chip ──────────────────────────────────────────────
                  if (pr != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9F0A).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.emoji_events,
                              color: Color(0xFFFF9F0A), size: 16),
                          const SizedBox(width: 6),
                          Text('PR: ${pr.toStringAsFixed(1)} kg',
                              style: const TextStyle(
                                  color: Color(0xFFFF9F0A), fontSize: 13)),
                        ],
                      ),
                    ),
                  ],

                  // ── Input fields ─────────────────────────────────────────
                  if (isCardio)
                    _buildField('Minutes', repsCtrl, isDecimal: false)
                  else
                    Row(children: [
                      Expanded(
                          child:
                              _buildField('Sets', setsCtrl, isDecimal: false)),
                      const SizedBox(width: 8),
                      Expanded(
                          child:
                              _buildField('Reps', repsCtrl, isDecimal: false)),
                      const SizedBox(width: 8),
                      Expanded(child: _buildField('kg', weightCtrl)),
                    ]),
                  const SizedBox(height: 8),

                  // ── Last session line ────────────────────────────────────
                  if (isCardio && lastReps != null)
                    Text('Last: $lastReps min',
                        style: const TextStyle(
                            color: Color(0xFF8E8E93), fontSize: 12))
                  else if (!isCardio && lastWeight != null)
                    Builder(builder: (_) {
                      final hint =
                          FitnessProvider.overloadSuggestion(lastWeight, lastReps);
                      return Row(children: [
                        Flexible(
                          child: Text(
                            'Last session: ${lastWeight.toStringAsFixed(1)} kg × ${lastReps ?? '?'} reps',
                            style: const TextStyle(
                                color: Color(0xFF8E8E93), fontSize: 12),
                          ),
                        ),
                        if (hint != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  const Color(0xFF30D158).withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.trending_up_rounded,
                                  size: 12, color: Color(0xFF30D158)),
                              const SizedBox(width: 4),
                              Text(hint,
                                  style: const TextStyle(
                                      color: Color(0xFF30D158),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ],
                      ]);
                    }),
                  const SizedBox(height: 20),

                  // ── Action buttons ───────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel',
                            style: TextStyle(color: Color(0xFF8E8E93))),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF30D158),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          final List<SetData> setLogs;
                          final String tip;
                          if (isCardio) {
                            final minutes = int.tryParse(repsCtrl.text) ?? 20;
                            setLogs = [SetData(reps: minutes, weight: 0)];
                            tip = '$minutes min logged 🏃';
                          } else {
                            final sets = int.tryParse(setsCtrl.text) ?? 3;
                            final reps = int.tryParse(repsCtrl.text) ?? 10;
                            final weight =
                                double.tryParse(weightCtrl.text) ?? 0;
                            tip = ExerciseDatabase.progressiveOverloadTip(
                                exerciseName,
                                sets,
                                reps,
                                weight,
                                lastReps ?? 10);
                            setLogs = List.generate(sets,
                                (_) => SetData(reps: reps, weight: weight));
                          }
                          setState(() {
                            final existingIdx = _exercises
                                .indexWhere((e) => e.name == exerciseName);
                            if (existingIdx >= 0) {
                              _exercises[existingIdx] = ExerciseLog(
                                name: exerciseName,
                                sets: [
                                  ..._exercises[existingIdx].sets,
                                  ...setLogs
                                ],
                              );
                            } else {
                              _exercises.add(ExerciseLog(
                                  name: exerciseName, sets: setLogs));
                            }
                          });
                          Haptics.tap();
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).clearSnackBars();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(tip),
                              duration: const Duration(seconds: 3),
                              backgroundColor: const Color(0xFF2C2C2E),
                            ),
                          );
                        },
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      setsCtrl.dispose();
      repsCtrl.dispose();
      weightCtrl.dispose();
    });
  }

  Widget _buildField(String label, TextEditingController ctrl,
      {bool isDecimal = true}) {
    return TextField(
      controller: ctrl,
      keyboardType: isDecimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.number,
      inputFormatters: isDecimal ? positiveDecimalInput : positiveIntInput,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
    );
  }

  /// Loads today's logged exercises into the in-progress builder as deep copies
  /// so the user can review/tweak and Save them as a NEW session. The original
  /// logged history is never touched. Only exercises not already in the builder
  /// are appended (no overwrite, no duplicates).
  void _repeatToday(List<WorkoutLog> todays) {
    final copied = repeatExercises(todays, _exercises);
    if (copied.isEmpty) return; // everything is already in the builder
    setState(() => _exercises.addAll(copied));
    Haptics.tap();
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text("Loaded today's exercises — review and Save"),
      duration: Duration(seconds: 2),
    ));
  }

  void _removeExercise(int index) {
    setState(() => _exercises.removeAt(index));
    Haptics.impact();
  }

  Future<void> _saveWorkout() async {
    if (_isSaving) return; // prevent double-tap duplicate workout
    if (_exercises.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one exercise first')),
      );
      return;
    }
    _isSaving = true;
    try {
      final provider = context.read<FitnessProvider>();
      final workout = WorkoutLog(
        id: const Uuid().v4(),
        date: DateTime.now(),
        name: _workoutName,
        exercises: List.from(_exercises),
      );
      await provider.logWorkout(workout);
      Haptics.success();
      if (mounted) {
        final cals = provider.calculateWorkoutCalories(workout);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ Workout saved! ~$cals kcal burned'),
          backgroundColor: const Color(0xFF30D158),
        ));
        setState(() {
          _exercises.clear();
          _workoutName = _defaultWorkoutName();
          _selectedCategory = null;
          _searchCtrl.clear();
          _searchQuery = '';
        });
      }
    } finally {
      _isSaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FitnessProvider>();
    final categories = ExerciseDatabase.categories.keys.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout Log'),
        actions: [
          if (_exercises.isNotEmpty)
            TextButton.icon(
              onPressed: _saveWorkout,
              icon: const Icon(Icons.check_circle, color: Color(0xFF30D158)),
              label: const Text('Save',
                  style: TextStyle(
                      color: Color(0xFF30D158), fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // Today's logged workouts (may be multiple sessions)
          if (provider.todayWorkouts.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _TodayWorkoutSummary(
                  workouts: provider.todayWorkouts,
                  provider: provider,
                  onRepeat: () => _repeatToday(provider.todayWorkouts)),
            ),
          ],

          // Current session being built
          if (_exercises.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    const Text('Current Session',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF30D158).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('~$_estimatedCalories kcal',
                          style: const TextStyle(
                              color: Color(0xFF30D158),
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _ExerciseCard(
                  exercise: _exercises[i],
                  onRemove: () => _removeExercise(i),
                  onEdit: () => _showSetEntryDialog(_exercises[i].name),
                  provider: provider,
                ),
                childCount: _exercises.length,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF30D158),
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _saveWorkout,
                  child: const Text('Save Workout',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: Divider(height: 1)),
          ],

          // Exercise picker header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: const Text('Add Exercise',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),

          // Search bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() {
                  _searchQuery = v.toLowerCase();
                  if (_searchQuery.isNotEmpty) _selectedCategory = null;
                }),
                decoration: InputDecoration(
                  hintText: 'Search exercises...',
                  prefixIcon: const Icon(Icons.search,
                      color: Color(0xFF8E8E93), size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear,
                              size: 18, color: Color(0xFF8E8E93)),
                          onPressed: () => setState(() {
                            _searchCtrl.clear();
                            _searchQuery = '';
                          }),
                        )
                      : null,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ),

          // Category chips
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final cat = categories[i];
                  final selected =
                      _selectedCategory == cat && _searchQuery.isEmpty;
                  return ChoiceChip(
                    label: Text(cat),
                    selected: selected,
                    selectedColor:
                        const Color(0xFF30D158).withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: selected
                          ? const Color(0xFF30D158)
                          : const Color(0xFF8E8E93),
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                    onSelected: (_) => setState(() {
                      _selectedCategory = selected ? null : cat;
                      if (!selected) {
                        _searchCtrl.clear();
                        _searchQuery = '';
                      }
                    }),
                    backgroundColor: const Color(0xFF1E1E22),
                    side: BorderSide(
                      color: selected
                          ? const Color(0xFF30D158)
                          : const Color(0xFF38383A),
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  );
                },
              ),
            ),
          ),

          // Exercise grid — filtered by search or category
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                16, 8, 16, 100 + MediaQuery.of(context).padding.bottom),
            sliver: Builder(
              builder: (ctx) {
                final exercises = _searchQuery.isNotEmpty
                    ? ExerciseDatabase.allExercises
                        .where((e) => e.toLowerCase().contains(_searchQuery))
                        .toList()
                    : (_selectedCategory != null
                        ? ExerciseDatabase.categories[_selectedCategory]!
                        : ExerciseDatabase.allExercises);
                return SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (ctx2, i) {
                      final name = exercises[i];
                      final alreadyAdded =
                          _exercises.any((e) => e.name == name);
                      return InkWell(
                        onTap: () => _addExercise(name),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: alreadyAdded
                                ? const Color(0xFF30D158)
                                    .withValues(alpha: 0.12)
                                : const Color(0xFF1E1E22),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: alreadyAdded
                                  ? const Color(0xFF30D158)
                                      .withValues(alpha: 0.4)
                                  : const Color(0xFF38383A),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(_exerciseIcon(name),
                                  size: 22,
                                  color: alreadyAdded
                                      ? const Color(0xFF30D158)
                                      : Colors.white70),
                              const SizedBox(height: 5),
                              Text(
                                name,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: alreadyAdded
                                      ? const Color(0xFF30D158)
                                      : Colors.white,
                                ),
                              ),
                              if (alreadyAdded) ...[
                                const SizedBox(height: 1),
                                const Icon(Icons.check,
                                    size: 11, color: Color(0xFF30D158)),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                    childCount: exercises.length,
                  ),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.2,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows ALL workout sessions saved today, with a combined calorie total.
class _TodayWorkoutSummary extends StatelessWidget {
  final List<WorkoutLog> workouts;
  final FitnessProvider provider;
  final VoidCallback onRepeat;
  const _TodayWorkoutSummary(
      {required this.workouts,
      required this.provider,
      required this.onRepeat});

  @override
  Widget build(BuildContext context) {
    final totalCals =
        workouts.fold(0, (s, w) => s + provider.calculateWorkoutCalories(w));
    final totalExercises = workouts.fold(0, (s, w) => s + w.exercises.length);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
        border:
            Border.all(color: const Color(0xFF30D158).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: today's summary
          Row(children: [
            const Icon(Icons.check_circle, color: Color(0xFF30D158), size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                workouts.length == 1 ? workouts.first.name : "Today's Workout",
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
            const Spacer(),
            // Re-log today's session: loads its exercises into the builder.
            OutlinedButton.icon(
              onPressed: onRepeat,
              icon: const Icon(Icons.replay_rounded, size: 15),
              label: const Text('Repeat'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF30D158),
                side: const BorderSide(color: Color(0xFF30D158)),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('~$totalCals kcal',
                  style: const TextStyle(
                      color: Color(0xFF30D158),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              if (workouts.length > 1)
                Text('${workouts.length} sessions · $totalExercises exercises',
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 10)),
            ]),
          ]),
          const SizedBox(height: 8),
          // List exercises from all sessions
          ...workouts.expand((w) => w.exercises).map((ex) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(_exerciseIcon(ex.name),
                      size: 16, color: const Color(0xFF8E8E93)),
                  const SizedBox(width: 8),
                  Expanded(
                      child:
                          Text(ex.name, style: const TextStyle(fontSize: 13))),
                  Text(
                    _formatSets(ex.sets, compact: true),
                    style:
                        const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
                  ),
                ]),
              )),
        ],
      ),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  final ExerciseLog exercise;
  final VoidCallback onRemove;
  final VoidCallback onEdit;
  final FitnessProvider provider;
  const _ExerciseCard(
      {required this.exercise,
      required this.onRemove,
      required this.onEdit,
      required this.provider});

  @override
  Widget build(BuildContext context) {
    final sets = exercise.sets;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(exercise.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 4),
              Text(
                _formatSets(sets),
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onEdit,
          icon: const Icon(Icons.add_circle_outline,
              color: Color(0xFF30D158), size: 22),
          tooltip: 'Add more sets',
        ),
        IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.remove_circle_outline,
              color: Color(0xFFFF453A), size: 22),
        ),
      ]),
    );
  }
}
