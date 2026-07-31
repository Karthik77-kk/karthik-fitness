import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/kit/kit.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          indicatorColor: Color(0xFF30D158),
          labelColor: Color(0xFF30D158),
          unselectedLabelColor: Color(0xFF8E8E93),
          tabs: const [
            Tab(text: 'Workouts'),
            Tab(text: 'Nutrition'),
            Tab(text: 'Weight'),
            Tab(text: 'Water'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _WorkoutHistory(),
          _NutritionHistory(),
          _WeightHistory(),
          _WaterHistory(),
        ],
      ),
    );
  }
}

// ── Workout History — grouped by date ────────────────────────────────────────

class _WorkoutHistory extends StatefulWidget {
  const _WorkoutHistory();
  @override
  State<_WorkoutHistory> createState() => _WorkoutHistoryState();
}

class _WorkoutHistoryState extends State<_WorkoutHistory> {
  final Set<String> _expanded = {};

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _displayDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(d.year, d.month, d.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final workouts = p.getRecentWorkouts(days: 60);
    if (workouts.isEmpty) {
      return const AppEmptyState(
        icon: '💪',
        title: 'No workouts logged yet',
        subtitle: 'Tap the Workout tab to log your first session',
      );
    }

    // Group by date key
    final Map<String, List<WorkoutLog>> grouped = {};
    for (final w in workouts) {
      final key = _dateKey(w.date);
      grouped.putIfAbsent(key, () => []).add(w);
    }
    final sortedKeys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      itemCount: sortedKeys.length,
      itemBuilder: (ctx, i) {
        final key = sortedKeys[i];
        final sessions = grouped[key]!;
        final totalCal =
            sessions.fold(0, (s, w) => s + p.calculateWorkoutCalories(w));
        final totalEx = sessions.fold(0, (s, w) => s + w.exercises.length);
        final isOpen = _expanded.contains(key);
        final date = sessions.first.date;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E22),
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            children: [
              // ── Day summary header ──────────────────────────────────────
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(() {
                  if (isOpen)
                    _expanded.remove(key);
                  else
                    _expanded.add(key);
                }),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF30D158).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.fitness_center_rounded,
                            color: Color(0xFF30D158), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_displayDate(date),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 2),
                            Text(
                              '${sessions.length} session${sessions.length > 1 ? 's' : ''}'
                              '  ·  $totalEx exercise${totalEx != 1 ? 's' : ''}',
                              style: const TextStyle(
                                  color: Color(0xFF8E8E93), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('~$totalCal kcal',
                              style: const TextStyle(
                                  color: Color(0xFF30D158),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                          const SizedBox(height: 2),
                          Icon(
                              isOpen
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              color: const Color(0xFF8E8E93),
                              size: 20),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── Expandable session details ──────────────────────────────
              if (isOpen) ...[
                const Divider(
                    color: Color(0xFF38383A),
                    height: 1,
                    indent: 14,
                    endIndent: 14),
                ...sessions.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final w = entry.value;
                  final cal = p.calculateWorkoutCalories(w);
                  return _SessionTile(
                    workout: w,
                    calories: cal,
                    sessionLabel: sessions.length > 1
                        ? 'Session ${idx + 1} of ${sessions.length}'
                        : null,
                  );
                }),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  final WorkoutLog workout;
  final int calories;
  final String? sessionLabel;
  const _SessionTile(
      {required this.workout, required this.calories, this.sessionLabel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sessionLabel != null
                      ? '${workout.name}  ($sessionLabel)'
                      : workout.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Text('$calories kcal',
                  style: const TextStyle(
                      color: Color(0xFFFF9F0A),
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 8),
          ...workout.exercises.map((ex) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child:
                          Icon(Icons.circle, size: 5, color: Color(0xFF8E8E93)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(ex.name,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white70)),
                    ),
                    if (ex.sets.isNotEmpty)
                      Text(
                        ExerciseDatabase.isCardio(ex.name)
                            ? '${ExerciseDatabase.cardioMinutes(ex.sets)} min'
                            : '${ex.sets.length} set${ex.sets.length > 1 ? 's' : ''}'
                                '${ex.sets.first.reps > 0 ? '  ×${ex.sets.first.reps}' : ''}'
                                '${ex.sets.first.weight > 0 ? '  @${ex.sets.first.weight.toStringAsFixed(1)}kg' : ''}',
                        style: const TextStyle(
                            color: Color(0xFF8E8E93), fontSize: 12),
                      ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

// ── Nutrition History ─────────────────────────────────────────────────────────

class _NutritionHistory extends StatefulWidget {
  const _NutritionHistory();
  @override
  State<_NutritionHistory> createState() => _NutritionHistoryState();
}

class _NutritionHistoryState extends State<_NutritionHistory> {
  // Returns a "YYYY-MM-DD" key for a DateTime — same logic as _WorkoutHistoryState.
  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Format a "YYYY-MM-DD" key as a readable label ("Today", "Yesterday", "14 Jun").
  String _displayDay(String dayKey) {
    try {
      final parts = dayKey.split('-');
      final date = DateTime(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final diff = today.difference(date).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Yesterday';
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${date.day} ${months[date.month - 1]}';
    } catch (_) {
      return dayKey;
    }
  }

  void _showDayDetail(BuildContext context, String dayKey) {
    final p = context.read<FitnessProvider>();
    final entries = p.foodHistory[dayKey] ?? [];
    final supp = p.supplementHistory[dayKey];
    final waterMl = p.waterHistory[dayKey] ?? 0;
    final suppCal = (supp?.whey == true) ? 120.0 : 0.0;
    final suppProt = (supp?.whey == true) ? 25.0 : 0.0;
    final totalCal = entries.fold(0.0, (s, e) => s + e.calories) + suppCal;
    final totalProt = entries.fold(0.0, (s, e) => s + e.protein) + suppProt;

    // Workouts for this day.
    final dayWorkouts =
        p.workoutHistory.where((w) => _dateKey(w.date) == dayKey).toList();

    // Group food entries by meal type in canonical order.
    const mealOrder = [
      MealType.breakfast,
      MealType.lunch,
      MealType.dinner,
      MealType.snack,
    ];
    final byMeal = <MealType, List<FoodEntry>>{};
    for (final e in entries) {
      byMeal.putIfAbsent(e.mealType, () => []).add(e);
    }

    IconData mealIcon(MealType m) => switch (m) {
          MealType.breakfast => Icons.wb_sunny_rounded,
          MealType.lunch => Icons.restaurant_rounded,
          MealType.dinner => Icons.nightlight_round,
          MealType.snack => Icons.cookie_rounded,
        };

    String mealLabel(MealType m) => switch (m) {
          MealType.breakfast => 'Breakfast',
          MealType.lunch => 'Lunch',
          MealType.dinner => 'Dinner',
          MealType.snack => 'Snack',
        };

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassSheet(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8E8E93).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // ── Header ──────────────────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _displayDay(dayKey),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          color: Colors.white),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${totalCal.round()} kcal',
                        style: const TextStyle(
                            color: Color(0xFFFF9F0A),
                            fontWeight: FontWeight.w700,
                            fontSize: 15),
                      ),
                      Text(
                        '${totalProt.round()}g protein',
                        style: const TextStyle(
                            color: Color(0xFF40C8E0), fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Food by meal ─────────────────────────────────────────────
              if (entries.isEmpty)
                const Text(
                  'No food logged',
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
                )
              else ...[
                for (final meal in mealOrder)
                  if (byMeal.containsKey(meal)) ...[
                    // Section label
                    Row(
                      children: [
                        Icon(mealIcon(meal),
                            color: const Color(0xFF8E8E93), size: 14),
                        const SizedBox(width: 6),
                        Text(
                          mealLabel(meal).toUpperCase(),
                          style: const TextStyle(
                              color: Color(0xFF8E8E93),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Food entries
                    for (final e in byMeal[meal]!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.name,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.white),
                              ),
                            ),
                            Text(
                              '${e.calories.round()} kcal · ${e.protein.round()}g',
                              style: const TextStyle(
                                  color: Color(0xFF8E8E93), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
              ],

              // ── Water ────────────────────────────────────────────────────
              const Divider(color: Color(0xFF38383A), height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.water_drop_rounded,
                      color: Color(0xFF40C8E0), size: 16),
                  const SizedBox(width: 8),
                  const Text('Water',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Text(
                    '$waterMl ml',
                    style: const TextStyle(
                        color: Color(0xFF40C8E0),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ── Supplements ──────────────────────────────────────────────
              if (supp != null) ...[
                const Divider(color: Color(0xFF38383A), height: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.medication_rounded,
                        color: Color(0xFF8E8E93), size: 16),
                    const SizedBox(width: 8),
                    const Text('Supplements',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    const Spacer(),
                    Text(
                      '${supp.takenCount}/3 taken',
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SuppChip(label: 'Whey', taken: supp.whey),
                const SizedBox(height: 4),
                _SuppChip(label: 'Creatine', taken: supp.creatine),
                const SizedBox(height: 4),
                _SuppChip(label: 'Multivitamin', taken: supp.multivitamin),
                const SizedBox(height: 12),
              ],

              // ── Workouts ─────────────────────────────────────────────────
              if (dayWorkouts.isNotEmpty) ...[
                const Divider(color: Color(0xFF38383A), height: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.fitness_center_rounded,
                        color: Color(0xFF30D158), size: 16),
                    const SizedBox(width: 8),
                    const Text('Workouts',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
                const SizedBox(height: 8),
                for (final w in dayWorkouts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            w.name,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.white),
                          ),
                        ),
                        Text(
                          '${w.exercises.length} exercise${w.exercises.length != 1 ? 's' : ''}',
                          style: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final history = p.foodHistory;
    final suppHistory = p.supplementHistory;
    final sortedDays = history.keys.toList()..sort((a, b) => b.compareTo(a));
    if (sortedDays.isEmpty) {
      return const AppEmptyState(
        icon: '🍽️',
        title: 'No food logged yet',
        subtitle: 'Tap the Nutrition tab to start logging meals',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      itemCount: sortedDays.length,
      itemBuilder: (ctx, i) {
        final day = sortedDays[i];
        final entries = history[day] ?? [];
        final supp = suppHistory[day];
        final suppCal = (supp?.whey == true) ? 120.0 : 0.0;
        final suppProt = (supp?.whey == true) ? 25.0 : 0.0;
        final totalCal = entries.fold(0.0, (s, e) => s + e.calories) + suppCal;
        final totalProt = entries.fold(0.0, (s, e) => s + e.protein) + suppProt;
        final suppLabel = supp != null ? ' · ${supp.takenCount}/3 supps' : '';
        return AppTappable(
          onTap: () => _showDayDetail(context, day),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(14),
                boxShadow: AppShadows.card),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(day,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    Text(
                      '${entries.length} item${entries.length != 1 ? 's' : ''}$suppLabel',
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 12),
                    ),
                  ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${totalCal.round()} kcal',
                    style: const TextStyle(
                        color: Color(0xFFFF9F0A), fontWeight: FontWeight.w600)),
                Text('${totalProt.round()}g protein',
                    style: const TextStyle(
                        color: Color(0xFF40C8E0), fontSize: 12)),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

// Small read-only supplement chip used in the day-detail sheet.
class _SuppChip extends StatelessWidget {
  final String label;
  final bool taken;
  const _SuppChip({required this.label, required this.taken});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          taken
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: taken ? const Color(0xFF30D158) : const Color(0xFF8E8E93),
          size: 16,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: taken ? Colors.white : const Color(0xFF8E8E93),
          ),
        ),
      ],
    );
  }
}

// ── Weight History — improved chart ──────────────────────────────────────────

class _WeightHistory extends StatelessWidget {
  const _WeightHistory();

  String _shortDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final entries = p.getRecentBodyEntries(days: 60);
    if (entries.length < 2) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
              'Log at least 2 weight entries\nto see your progress chart',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF8E8E93), height: 1.6)),
        ),
      );
    }

    final spots = entries
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.weightKg))
        .toList();

    final weights = entries.map((e) => e.weightKg).toList();
    final minW = weights.reduce((a, b) => a < b ? a : b);
    final maxW = weights.reduce((a, b) => a > b ? a : b);
    final padding = (maxW - minW) < 1.0 ? 1.0 : (maxW - minW) * 0.2;
    final yMin = (minW - padding).floorToDouble();
    final yMax = (maxW + padding).ceilToDouble();

    final change = entries.last.weightKg - entries.first.weightKg;
    final isLoss = change <= 0;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Stats row ──────────────────────────────────────────────────
          Row(
            children: [
              _StatBadge(
                label: 'Current',
                value: '${entries.last.weightKg.toStringAsFixed(1)} kg',
                color: const Color(0xFF30D158),
              ),
              const SizedBox(width: 10),
              _StatBadge(
                label: 'Total change',
                value:
                    '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)} kg',
                color:
                    isLoss ? const Color(0xFF30D158) : const Color(0xFFFF9F0A),
              ),
              const SizedBox(width: 10),
              _StatBadge(
                label: 'Goal',
                value: '${p.goalWeightKg.toStringAsFixed(1)} kg',
                color: const Color(0xFF40C8E0),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Chart ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(14),
              boxShadow: AppShadows.card,
            ),
            height: 220,
            child: ChartEntrance(
              builder: (context, t) => ClipRect(
                clipper: RevealClipper(t),
                child: LineChart(
                  duration: reduceMotion(context)
                      ? Duration.zero
                      : AppDurations.normal,
                  curve: AppCurves.emphasized,
                  LineChartData(
                    minY: yMin,
                    maxY: yMax,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: padding.clamp(0.5, 2.0),
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: const Color(0xFF38383A),
                        strokeWidth: 0.8,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 42,
                          interval: padding.clamp(0.5, 2.0),
                          getTitlesWidget: (v, _) => Text(
                            v.toStringAsFixed(1),
                            style: const TextStyle(
                                color: Color(0xFF8E8E93), fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          interval: (entries.length / 4)
                              .ceilToDouble()
                              .clamp(1.0, 20.0),
                          getTitlesWidget: (v, _) {
                            final idx = v.toInt();
                            if (idx < 0 || idx >= entries.length) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _shortDate(entries[idx].date),
                                style: const TextStyle(
                                    color: Color(0xFF8E8E93), fontSize: 10),
                              ),
                            );
                          },
                        ),
                      ),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      // Goal line (dashed)
                      if (p.goalWeightKg >= yMin && p.goalWeightKg <= yMax)
                        LineChartBarData(
                          spots: [
                            FlSpot(0, p.goalWeightKg),
                            FlSpot((entries.length - 1).toDouble(),
                                p.goalWeightKg),
                          ],
                          color: const Color(0xFF40C8E0).withValues(alpha: 0.5),
                          barWidth: 1.5,
                          dotData: const FlDotData(show: false),
                          dashArray: [6, 4],
                        ),
                      // Weight trend line
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        curveSmoothness: 0.3,
                        color: const Color(0xFF30D158),
                        barWidth: 2.5,
                        dotData: FlDotData(
                          show: true,
                          getDotPainter: (spot, _, __, ___) =>
                              FlDotCirclePainter(
                            radius: 3,
                            color: const Color(0xFF30D158),
                            strokeColor: Colors.black,
                            strokeWidth: 1.5,
                          ),
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF30D158).withValues(alpha: 0.25),
                              const Color(0xFF30D158).withValues(alpha: 0.0),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(children: [
              Container(
                  width: 16,
                  height: 2,
                  color: const Color(0xFF40C8E0).withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              const Text('Goal weight',
                  style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11)),
            ]),
          ),
          const SizedBox(height: 20),

          // ── Log list ───────────────────────────────────────────────────
          ...entries.reversed.take(10).map((e) => Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E22),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: AppShadows.card,
                ),
                child: Row(
                  children: [
                    Text(_shortDate(e.date),
                        style: const TextStyle(
                            color: Color(0xFF8E8E93), fontSize: 13)),
                    const Spacer(),
                    Text('${e.weightKg.toStringAsFixed(1)} kg',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF30D158),
                            fontSize: 14)),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatBadge(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    color: color.withValues(alpha: 0.8), fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// ── Water History ─────────────────────────────────────────────────────────────

class _WaterHistory extends StatelessWidget {
  const _WaterHistory();
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final history = p.waterHistory;
    final sortedDays = history.keys.toList()..sort((a, b) => b.compareTo(a));
    if (sortedDays.isEmpty) {
      return const AppEmptyState(
        icon: '💧',
        title: 'No water logged yet',
        subtitle: 'Tap the Nutrition tab → Water to log intake',
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      itemCount: sortedDays.length,
      itemBuilder: (ctx, i) {
        final day = sortedDays[i];
        final ml = history[day] ?? 0;
        final goal = p.waterGoalMl;
        final progress = goal > 0 ? (ml / goal).clamp(0.0, 1.0) : 0.0;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(14),
              boxShadow: AppShadows.card),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(day,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14))),
              Text('$ml ml',
                  style: TextStyle(
                    color: ml >= goal
                        ? const Color(0xFF30D158)
                        : const Color(0xFF40C8E0),
                    fontWeight: FontWeight.w600,
                  )),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: const Color(0xFF2C2C2E),
                valueColor: AlwaysStoppedAnimation(ml >= goal
                    ? const Color(0xFF30D158)
                    : const Color(0xFF40C8E0)),
                minHeight: 5,
              ),
            ),
          ]),
        );
      },
    );
  }
}
