import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/haptics.dart';
import '../widgets/input_formatters.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../widgets/date_picker_chip.dart';
import '../widgets/kit/kit.dart';
import '../theme/app_tokens.dart';

const _kGreen = Color(0xFF30D158);
const _kBlue = Color(0xFF40C8E0);
const _kOrange = Color(0xFFFF9F0A);
const _kRed = Color(0xFFFF453A);
const _kCard = Color(0xFF1E1E22);
const _kSecond = Color(0xFF8E8E93);

class StatsScreen extends StatefulWidget {
  final bool embedded;
  const StatsScreen({super.key, this.embedded = false});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _weightCtrl = TextEditingController();
  final _stepsCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _goalWtCtrl = TextEditingController();
  DateTime _logDate = DateTime.now(); // backdate target for weigh-ins

  // Prevents re-populating fields after user edits them
  bool _fieldsPopulated = false;

  @override
  void initState() {
    super.initState();
    // Post-frame so provider is available; also handles IndexedStack pre-build
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryPopulateFields());
  }

  /// Populate text controllers from provider once data is loaded.
  /// Safe to call multiple times — only runs once (_fieldsPopulated guard).
  void _tryPopulateFields() {
    if (_fieldsPopulated || !mounted) return;
    final p = context.read<FitnessProvider>();
    if (!p.isLoaded) {
      // Data not ready yet — listen for the next change
      p.addListener(_onProviderChange);
      return;
    }
    _applyProviderValues(p);
  }

  void _onProviderChange() {
    if (!mounted) return;
    final p = context.read<FitnessProvider>();
    if (p.isLoaded) {
      p.removeListener(_onProviderChange);
      _applyProviderValues(p);
    }
  }

  void _applyProviderValues(FitnessProvider p) {
    if (_fieldsPopulated) return;
    _fieldsPopulated = true;
    _heightCtrl.text = p.heightCm.toStringAsFixed(0);
    _ageCtrl.text = p.age.toString();
    _goalWtCtrl.text = p.goalWeightKg.toStringAsFixed(1);
    if (p.latestWeightKg != null) {
      _weightCtrl.text = p.latestWeightKg!.toStringAsFixed(1);
    }
    if (p.todaySteps > 0) {
      _stepsCtrl.text = p.todaySteps.toString();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // Remove listener if it was added but never fired
    try {
      context.read<FitnessProvider>().removeListener(_onProviderChange);
    } catch (_) {}
    _weightCtrl.dispose();
    _stepsCtrl.dispose();
    _heightCtrl.dispose();
    _ageCtrl.dispose();
    _goalWtCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveEntries() async {
    FocusScope.of(context).unfocus();
    Haptics.impact();
    final p = context.read<FitnessProvider>();

    final weight = double.tryParse(_weightCtrl.text.trim());
    final stepsText = _stepsCtrl.text.trim();
    final stepsRaw = stepsText.isEmpty ? 0 : int.tryParse(stepsText);
    final height = double.tryParse(_heightCtrl.text.trim());
    final age = int.tryParse(_ageCtrl.text.trim());
    final goalWt = double.tryParse(_goalWtCtrl.text.trim());

    // Validate
    if (weight == null || weight <= 10 || weight >= 500) {
      _showError('Enter a valid weight (10–500 kg)');
      return;
    }
    if (stepsRaw == null) {
      _showError('Steps must be a whole number (e.g. 6000)');
      return;
    }
    final steps = stepsRaw;

    final futures = <Future>[];
    final skipped = <String>[];
    futures.add(p.logBodyEntry(
        weightKg: weight, steps: steps.clamp(0, 100000), date: _logDate));

    // Each optional field: save if valid, flag if the user typed something invalid.
    if (_heightCtrl.text.trim().isNotEmpty) {
      if (height != null && height > 50 && height < 300) {
        futures.add(p.saveHeight(height));
      } else {
        skipped.add('height (50–300 cm)');
      }
    }
    if (_ageCtrl.text.trim().isNotEmpty) {
      if (age != null && age >= 10 && age <= 100) {
        futures.add(p.saveAge(age));
      } else {
        skipped.add('age (10–100)');
      }
    }
    if (_goalWtCtrl.text.trim().isNotEmpty) {
      if (goalWt != null && goalWt > 10 && goalWt < 500) {
        futures.add(p.saveGoalWeight(goalWt));
      } else {
        skipped.add('goal weight (10–500 kg)');
      }
    }

    await Future.wait(futures);
    if (!mounted) return;
    if (skipped.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stats saved ✓'),
          backgroundColor: _kGreen,
          duration: Duration(seconds: 1),
        ),
      );
    } else {
      // Honest feedback: weight saved, but flag what was out of range.
      _showError('Weight saved. Skipped invalid: ${skipped.join(', ')}');
    }
  }

  void _showError(String msg) {
    Haptics.warning();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚠️ $msg'),
        backgroundColor: _kRed,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required for AutomaticKeepAliveClientMixin
    final p = context.watch<FitnessProvider>();
    final recent = p.getRecentBodyEntries(days: 30);
    final bottom = MediaQuery.of(context).padding.bottom;

    final scrollView = GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: CustomScrollView(
        slivers: [
          if (!widget.embedded)
            SliverAppBar(
              pinned: true,
              backgroundColor: Colors.black,
              surfaceTintColor: Colors.transparent,
              title: const Text('Stats'),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 32 + bottom),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Log Today ──────────────────────────────────────────
                const _SectionLabel('LOG TODAY'),
                _Card(
                  child: Column(
                    children: [
                      // Backdate: which day this weigh-in is logged to.
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: DatePickerChip(
                            date: _logDate,
                            onChanged: (d) => setState(() => _logDate = d),
                          ),
                        ),
                      ),
                      _FieldRow(
                        label: 'Weight',
                        icon: Icons.monitor_weight_outlined,
                        iconColor: _kGreen,
                        unit: 'kg',
                        ctrl: _weightCtrl,
                      ),
                      _HDivider(),
                      _FieldRow(
                        label: 'Steps',
                        icon: Icons.directions_walk_outlined,
                        iconColor: _kGreen,
                        unit: 'steps',
                        ctrl: _stepsCtrl,
                        keyboard: TextInputType.number,
                      ),
                      _HDivider(),
                      _FieldRow(
                        label: 'Height',
                        icon: Icons.height_outlined,
                        iconColor: _kBlue,
                        unit: 'cm',
                        ctrl: _heightCtrl,
                      ),
                      _HDivider(),
                      _FieldRow(
                        label: 'Age',
                        icon: Icons.cake_outlined,
                        iconColor: _kBlue,
                        unit: 'yrs',
                        ctrl: _ageCtrl,
                        keyboard: TextInputType.number,
                      ),
                      _HDivider(),
                      // Sex toggle — affects BMR formula (male +5 / female −161)
                      _SexToggleRow(),
                      _HDivider(),
                      _FieldRow(
                        label: 'Goal Weight',
                        icon: Icons.flag_outlined,
                        iconColor: _kOrange,
                        unit: 'kg',
                        ctrl: _goalWtCtrl,
                        isLast: true,
                      ),
                      const SizedBox(height: 14),
                      _SaveBtn(onPressed: _saveEntries),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Body Measurements ──────────────────────────────────
                const _SectionLabel('BODY MEASUREMENTS (cm)'),
                _MeasurementsSection(provider: p),
                const SizedBox(height: 24),

                // ── Overview ───────────────────────────────────────────
                const _SectionLabel('OVERVIEW'),
                _Grid2x2(children: [
                  _StatCard(
                    label: 'Current Weight',
                    value: p.latestWeightKg != null
                        ? '${p.latestWeightKg!.toStringAsFixed(1)} kg'
                        : '—',
                    sub: _weightChangeLine(p),
                    color: _kGreen,
                    icon: Icons.monitor_weight_outlined,
                  ),
                  _StatCard(
                    label: 'BMI',
                    value: p.bmi?.toStringAsFixed(1) ?? '—',
                    sub: p.bmiCategory,
                    color: p.bmi != null ? p.bmiColor(context) : _kSecond,
                    icon: Icons.accessibility_new_outlined,
                  ),
                  _StatCard(
                    label: 'Today\'s Steps',
                    value: p.todaySteps > 0 ? _fmtNum(p.todaySteps) : '—',
                    sub: p.todaySteps > 0
                        ? '${p.stepGoal > 0 ? (p.todaySteps / p.stepGoal * 100).round() : 0}% of ${(p.stepGoal / 1000).round()}k'
                        : '${p.stepGoal} goal',
                    color: _kBlue,
                    icon: Icons.directions_walk_outlined,
                  ),
                  _StatCard(
                    label: 'Workout Streak',
                    value: '${p.workoutStreak}d',
                    sub: p.workoutStreak > 0 ? 'Keep going! 🔥' : 'Start today',
                    color: _kOrange,
                    icon: Icons.local_fire_department_outlined,
                  ),
                  _StatCard(
                    label: 'Diet Streak',
                    value: '${p.calorieStreak}d',
                    sub: p.calorieStreak > 0
                        ? 'On target! 🥗'
                        : 'Log meals daily',
                    color: _kBlue,
                    icon: Icons.restaurant_menu_outlined,
                  ),
                  _StatCard(
                    label: 'Water Today',
                    value: p.todayWaterMl >= 1000
                        ? '${(p.todayWaterMl / 1000).toStringAsFixed(1)}L'
                        : '${p.todayWaterMl}ml',
                    sub: '/ ${(p.waterGoalMl / 1000).toStringAsFixed(1)}L goal',
                    color: _kBlue,
                    icon: Icons.water_drop_outlined,
                  ),
                ]),
                const SizedBox(height: 12),
                _Grid2x2(children: [
                  _StatCard(
                    label: 'Cal Burned Today',
                    value: p.todayCaloriesBurned > 0
                        ? '${p.todayCaloriesBurned} kcal'
                        : '—',
                    sub: 'From workout',
                    color: _kRed,
                    icon: Icons.whatshot_outlined,
                  ),
                  _StatCard(
                    label: 'Weekly Burned',
                    value: p.weeklyCaloriesBurned > 0
                        ? '${p.weeklyCaloriesBurned} kcal'
                        : '—',
                    sub: 'Last 7 days',
                    color: _kRed,
                    icon: Icons.bar_chart_outlined,
                  ),
                  _StatCard(
                    // "so far": resting burn is prorated to the current time,
                    // so this number legitimately grows through the day.
                    label: 'Net So Far Today',
                    value: p.todayCaloriesTotal > 0
                        ? '${p.netCalories} kcal'
                        : '—',
                    // Verdict uses the END-OF-DAY projection (projectedInDeficit)
                    // so it stays stable through the day, instead of the raw net
                    // sign that flips "surplus → deficit" as resting burn accrues.
                    // null = not enough signal yet → neutral "keep logging".
                    sub: p.projectedInDeficit == null
                        ? 'Keep logging'
                        : p.projectedInDeficit!
                            ? '🎯 On track: deficit'
                            : '⚠️ Heading for surplus',
                    color: p.projectedInDeficit == null
                        ? _kSecond
                        : p.projectedInDeficit!
                            ? _kGreen
                            : _kRed,
                    icon: Icons.balance_outlined,
                  ),
                  _StatCard(
                    label: 'Protein Today',
                    value: p.todayProteinTotal > 0
                        ? '${p.todayProteinTotal.round()}g'
                        : '—',
                    sub: '/ ${p.proteinGoal}g goal',
                    color: _kGreen,
                    icon: Icons.egg_alt_outlined,
                  ),
                ]),
                const SizedBox(height: 24),

                // ── BMR / TDEE ─────────────────────────────────────────
                _SectionLabel(p.latestScaleEntry?.bmr != null
                    ? 'METABOLISM (SMART SCALE)'
                    : 'METABOLISM (MIFFLIN–ST JEOR)'),
                _BmrTdeeCard(provider: p),
                const SizedBox(height: 24),

                // ── Body Composition ───────────────────────────────────
                const _SectionLabel('BODY COMPOSITION'),
                _BodyCompositionCard(provider: p),
                const SizedBox(height: 24),

                // ── Goal Progress ──────────────────────────────────────
                if (p.latestWeightKg != null && p.kgToGoal != null) ...[
                  const _SectionLabel('GOAL PROGRESS'),
                  _GoalCard(provider: p),
                  const SizedBox(height: 24),
                ],

                // ── Weight History ─────────────────────────────────────
                if (recent.length >= 2) ...[
                  const _SectionLabel('WEIGHT TREND (30 DAYS)'),
                  _Card(
                    child: Column(
                      children: [
                        _MiniWeightChart(
                            entries: recent, goalWeightKg: p.goalWeightKg),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _ChartStat('Low',
                                '${recent.map((e) => e.weightKg).reduce((a, b) => a < b ? a : b).toStringAsFixed(1)} kg'),
                            _ChartStat('High',
                                '${recent.map((e) => e.weightKg).reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} kg'),
                            _ChartStat('Avg',
                                '${(recent.map((e) => e.weightKg).reduce((a, b) => a + b) / recent.length).toStringAsFixed(1)} kg'),
                            _ChartStat('Entries', '${recent.length}d'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // ── BMI Scale ──────────────────────────────────────────
                const _SectionLabel('BMI SCALE'),
                _Card(
                  child: Column(
                    children: [
                      _BmiBar(bmi: p.bmi),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          _BmiLabel('Under', '< 18.5', _kBlue),
                          _BmiLabel('Normal', '18.5–24.9', _kGreen),
                          _BmiLabel('Over', '25–29.9', _kOrange),
                          _BmiLabel('Obese', '≥ 30', _kRed),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── AI Predictions ────────────────────────────────────
                const _SectionLabel('AI PREDICTIONS'),
                _AiPredictionsCard(provider: p),
                const SizedBox(height: 24),

                // ── 1RM Estimator from history ─────────────────────────
                const _SectionLabel('1RM ESTIMATOR (FROM YOUR LOGS)'),
                const _OneRMSection(),
                const SizedBox(height: 16),
              ]),
            ),
          ),
        ],
      ),
    );

    if (widget.embedded) return scrollView;
    return Scaffold(backgroundColor: Colors.black, body: scrollView);
  }

  String _weightChangeLine(FitnessProvider p) {
    final change = p.weightChangeKg;
    if (change == null) return 'Log daily to track';
    final sign = change > 0 ? '+' : '';
    return '$sign${change.toStringAsFixed(1)} kg last 30 days';
  }
}

String _fmtNum(int n) {
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
  return '$n';
}

// ─── AI Predictions Card ───────────────────────────────────────────────────────
class _AiPredictionsCard extends StatelessWidget {
  final FitnessProvider provider;
  const _AiPredictionsCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final entries = p.getRecentBodyEntries(days: 90);

    if (entries.length < 3) {
      return _Card(
        child: Row(children: const [
          Text('🤖', style: TextStyle(fontSize: 22)),
          SizedBox(width: 12),
          Expanded(
              child: Text(
            'Log your weight for at least 3 days to unlock AI predictions.',
            style: TextStyle(color: _kSecond, fontSize: 13, height: 1.4),
          )),
        ]),
      );
    }

    final weekly = p.weeklyWeightChange;
    final pred30 = p.predictedWeightInDays(30);
    final pred90 = p.predictedWeightInDays(90);
    final goalDate = p.estimatedGoalDate;
    final tdee = p.bestTdee;
    final target = p.fatLossCalorieTarget;

    // Smart calorie suggestion based on weight trend
    String calSuggestion;
    Color calColor = _kGreen;
    if (weekly == null || tdee == null) {
      calSuggestion = 'Log weight + height for calorie suggestion';
      calColor = _kSecond;
    } else if (weekly < -0.8) {
      calSuggestion =
          'Losing ${weekly.abs().toStringAsFixed(2)} kg/wk — too fast! '
          'Eat ~${((weekly.abs() - 0.5) * 7700 / 7).round()} kcal more/day.';
      calColor = _kOrange;
    } else if (weekly < -0.1) {
      calSuggestion =
          'Losing ${weekly.abs().toStringAsFixed(2)} kg/wk — perfect pace! '
          'Stay at ~${target?.round() ?? p.calorieGoal} kcal/day.';
      calColor = _kGreen;
    } else if (weekly > 0.2) {
      calSuggestion = 'Gaining ${weekly.toStringAsFixed(2)} kg/wk. '
          'Cut ~${((weekly - 0.1) * 7700 / 7).round()} kcal/day to reverse trend.';
      calColor = _kRed;
    } else {
      calSuggestion =
          'Weight is stable. Reduce by 200–300 kcal/day for fat loss.';
      calColor = _kBlue;
    }

    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Row(children: [
          const Text('🤖', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Text('AI Weight Forecast',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (weekly != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (weekly < 0 ? _kGreen : _kRed).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${weekly >= 0 ? '+' : ''}${weekly.toStringAsFixed(2)} kg/wk',
                style: TextStyle(
                    color: weekly < 0 ? _kGreen : _kRed,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
        ]),
        const SizedBox(height: 14),

        // Prediction row
        Row(children: [
          _PredChip('Now', '${p.latestWeightKg?.toStringAsFixed(1) ?? '—'} kg',
              Colors.white),
          const SizedBox(width: 8),
          _PredChip(
              '30 days',
              pred30 != null ? '${pred30.toStringAsFixed(1)} kg' : '—',
              weekly != null && weekly < 0 ? _kGreen : _kRed),
          const SizedBox(width: 8),
          _PredChip('90 days',
              pred90 != null ? '${pred90.toStringAsFixed(1)} kg' : '—', _kBlue),
          const SizedBox(width: 8),
          _PredChip(
              'Goal by',
              goalDate != null
                  ? '${goalDate.day}/${goalDate.month}/${goalDate.year % 100}'
                  : '—',
              _kOrange),
        ]),
        const SizedBox(height: 14),

        // Smart calorie suggestion
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: calColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: calColor.withValues(alpha: 0.25)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.tips_and_updates_outlined,
                size: 16, color: Color(0xFFFF9F0A)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(calSuggestion,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, height: 1.4))),
          ]),
        ),

        if (tdee != null && target != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            _MetaChip2(p.isTdeeCalibrated ? 'TDEE ✓' : 'TDEE',
                '${tdee.round()} kcal', _kOrange),
            const SizedBox(width: 8),
            _MetaChip2('Fat Loss Target', '${target.round()} kcal', _kGreen),
            const SizedBox(width: 8),
            _MetaChip2('Current Goal', '${p.calorieGoal} kcal', _kBlue),
          ]),
          if (p.isTdeeCalibrated) ...[
            const SizedBox(height: 6),
            const Text('✓ TDEE calibrated from your real weight trend + intake',
                style: TextStyle(color: _kGreen, fontSize: 11)),
          ],
        ],
      ]),
    );
  }
}

class _PredChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _PredChip(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
          ]),
        ),
      );
}

class _MetaChip2 extends StatelessWidget {
  final String label, value;
  final Color color;
  const _MetaChip2(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Expanded(
          child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
        ]),
      ));
}

// ─── BMR / TDEE Card ───────────────────────────────────────────────────────────
class _BmrTdeeCard extends StatelessWidget {
  final FitnessProvider provider;
  const _BmrTdeeCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final bmr = p.bmr;
    final tdee = p.bestTdee; // calibrated when data allows
    final estTdee = p.tdee; // raw BMR×activity estimate
    final target = p.fatLossCalorieTarget;
    final calibrated = p.isTdeeCalibrated;

    if (bmr == null) {
      return _Card(
        child: Row(
          children: const [
            Icon(Icons.info_outline, color: _kSecond, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Log your weight to see BMR & TDEE',
                style: TextStyle(color: _kSecond, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return _Card(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: _MetaChip(
                label: 'BMR',
                value: '${bmr.round()}',
                unit: 'kcal/day',
                color: _kBlue,
                tooltip: 'Calories burned at complete rest',
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: _MetaChip(
                label: calibrated ? 'TDEE ✓' : 'TDEE',
                value: '${tdee?.round() ?? '—'}',
                unit: 'kcal/day',
                color: _kOrange,
                tooltip: calibrated
                    ? 'Calibrated from your real weight trend + intake'
                    : 'Estimated from BMR × activity level',
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: _MetaChip(
                label: 'Cut Target',
                value: '${target?.round() ?? '—'}',
                unit: 'kcal/day',
                color: _kGreen,
                tooltip: '500 kcal below maintenance for fat loss',
              )),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (calibrated ? _kGreen : _kOrange).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Text(calibrated ? '🎯' : '💡',
                    style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    target == null
                        ? 'Enter weight, height and age to compute your targets.'
                        : calibrated
                            ? 'Calibrated from YOUR data: you actually maintain at '
                                '~${tdee!.round()} kcal/day (the BMR estimate was '
                                '${estTdee?.round() ?? '—'}). For steady fat loss aim '
                                '~${target.round()} kcal — your goal is ${p.calorieGoal} kcal.'
                            : 'Estimated fat-loss target ~${target.round()} kcal/day '
                                '(goal: ${p.calorieGoal} kcal). Keep logging weight + food '
                                'for ~2 weeks and this calibrates to your real metabolism.',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Body Composition Card ─────────────────────────────────────────────────────
class _BodyCompositionCard extends StatelessWidget {
  final FitnessProvider provider;
  const _BodyCompositionCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final status = p.bodyCompositionStatus;
    final whr = p.waistToHipRatio;
    final whtr = p.waistToHeightRatio;
    final ffmi = p.ffmi;
    final fat = p.fatMassKg;
    final lean = p.leanMassKg;
    final traj = p.bodyCompTrajectory;
    final bioDelta = p.bioAgeDelta;
    final hydration = p.hydrationStatus;

    final hasAny = whr != null ||
        whtr != null ||
        ffmi != null ||
        fat != null ||
        traj != null ||
        bioDelta != null;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Headline status
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: status.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(status.label,
                  style: TextStyle(
                      color: status.color,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(status.detail,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, height: 1.4)),

          if (!hasAny) ...[
            const SizedBox(height: 10),
            const Text(
                'Log waist + hips in Measurements and a smart-scale reading to unlock '
                'WHR, waist-to-height, FFMI and your fat-vs-muscle trajectory.',
                style: TextStyle(color: _kSecond, fontSize: 12, height: 1.4)),
          ] else ...[
            const SizedBox(height: 14),
            // Metric grid
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (whr != null)
                _BcChip('Waist:Hip', whr.toStringAsFixed(2),
                    p.whrRisk?.label ?? '', p.whrRisk?.color ?? _kSecond),
              if (whtr != null)
                _BcChip('Waist:Height', whtr.toStringAsFixed(2),
                    p.whtrStatus.label, p.whtrStatus.color),
              if (ffmi != null)
                _BcChip('FFMI', ffmi.toStringAsFixed(1), p.ffmiStatus.label,
                    p.ffmiStatus.color),
              if (fat != null)
                _BcChip('Fat mass', '${fat.toStringAsFixed(1)} kg', 'body fat',
                    _kOrange),
              if (lean != null)
                _BcChip('Lean mass', '${lean.toStringAsFixed(1)} kg',
                    'fat-free', _kGreen),
              if (hydration != null)
                _BcChip('Body water', hydration.label, 'hydration',
                    hydration.color),
              if (bioDelta != null)
                _BcChip(
                    'Body age',
                    bioDelta == 0
                        ? 'On par'
                        : bioDelta < 0
                            ? '${bioDelta.abs()}y younger'
                            : '$bioDelta y older',
                    'vs real age',
                    bioDelta <= 0 ? _kGreen : _kOrange),
            ]),
            // Trajectory banner
            if (traj != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: traj.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: traj.color.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Icon(Icons.swap_vert_rounded, color: traj.color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(traj.verdict,
                            style: TextStyle(
                                color: traj.color,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                        Text(
                            'Fat ${traj.fatChange >= 0 ? '+' : ''}${traj.fatChange.toStringAsFixed(1)} kg · '
                            'Muscle ${traj.leanChange >= 0 ? '+' : ''}${traj.leanChange.toStringAsFixed(1)} kg since first scan',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ])),
                ]),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _BcChip extends StatelessWidget {
  final String label, value, sub;
  final Color color;
  const _BcChip(this.label, this.value, this.sub, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 15, fontWeight: FontWeight.w700)),
        Text(sub,
            style:
                TextStyle(color: color.withValues(alpha: 0.8), fontSize: 11)),
      ]),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  final String tooltip;
  const _MetaChip({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 20, fontWeight: FontWeight.bold)),
          Text(unit, style: const TextStyle(color: _kSecond, fontSize: 11)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─── Goal Progress Card ────────────────────────────────────────────────────────
class _GoalCard extends StatelessWidget {
  final FitnessProvider provider;
  const _GoalCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    // Guard: parent checks non-null but provider can update mid-frame
    final current = p.latestWeightKg ?? 0.0;
    final goal = p.goalWeightKg;
    final kg = p.kgToGoal ?? 0.0;
    final isLosing = kg > 0;
    final color = isLosing ? _kOrange : _kGreen;
    final weeks = p.weeksToGoal;

    // Real progress along the start→goal journey (start = earliest logged weight).
    final progress = p.goalProgress;
    final start = p.startWeightKg;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  isLosing
                      ? Icons.trending_down_rounded
                      : Icons.check_circle_rounded,
                  color: color,
                  size: 20),
              const SizedBox(width: 8),
              Text(
                isLosing
                    ? '${kg.toStringAsFixed(1)} kg to goal'
                    : 'Goal weight reached! 🎉',
                style: TextStyle(
                    color: color, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text('${(progress * 100).round()}%',
                  style: TextStyle(
                      color: color, fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                  start != null
                      ? 'Start ${start.toStringAsFixed(1)}'
                      : 'Start —',
                  style: const TextStyle(color: _kSecond, fontSize: 11)),
              Text('Now ${current.toStringAsFixed(1)} kg',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
              Text('Goal ${goal.toStringAsFixed(1)}',
                  style: const TextStyle(color: _kSecond, fontSize: 11)),
            ],
          ),
          if (weeks != null && weeks > 0) ...[
            const SizedBox(height: 8),
            Text(
              p.weeklyWeightChange != null
                  ? '⏱ At your current trend: ~${weeks.toStringAsFixed(0)} weeks to reach goal'
                  : '⏱ At a sustainable pace: ~${weeks.toStringAsFixed(0)} weeks to reach goal',
              style: const TextStyle(color: _kSecond, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── 1RM Section (from logged history) ────────────────────────────────────────
class _OneRMSection extends StatelessWidget {
  const _OneRMSection();

  double _epley(double weight, int reps) {
    if (weight <= 0 || reps <= 0) return 0;
    if (reps == 1) return weight;
    return weight * (1 + reps / 30.0);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final bigLifts = [
      'Deadlift',
      'Squats',
      'Bench Press',
      'Overhead Press',
      'Barbell Rows',
      'Pull-ups',
      'Romanian Deadlift'
    ];

    final Map<String, ({double weight, int reps, double oneRM})> liftData = {};
    for (final lift in bigLifts) {
      double bestOneRM = 0;
      double bestWeight = 0;
      int bestReps = 0;
      for (final w in p.workoutHistory) {
        for (final ex in w.exercises) {
          if (ex.name == lift) {
            for (final s in ex.sets) {
              final estimated = _epley(s.weight, s.reps);
              if (estimated > bestOneRM) {
                bestOneRM = estimated;
                bestWeight = s.weight;
                bestReps = s.reps;
              }
            }
          }
        }
      }
      if (bestOneRM > 0) {
        liftData[lift] = (weight: bestWeight, reps: bestReps, oneRM: bestOneRM);
      }
    }

    if (liftData.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Column(children: [
          Text('1RM Estimator',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          SizedBox(height: 12),
          Text(
              'Log compound lifts (Deadlift, Squats, Bench Press, etc.) in the Workout tab to see your estimated 1-rep maxes here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _kSecond, fontSize: 13)),
        ]),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('1RM Estimator',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: _kOrange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('Epley Formula',
                  style: TextStyle(color: _kOrange, fontSize: 11)),
            ),
          ]),
          const SizedBox(height: 4),
          const Text('Estimated from your best logged sets',
              style: TextStyle(color: _kSecond, fontSize: 12)),
          const SizedBox(height: 14),
          ...liftData.entries.map((e) {
            final name = e.key;
            final d = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500)),
                        Text(
                            'Best: ${d.weight.toStringAsFixed(1)} kg × ${d.reps} reps',
                            style:
                                const TextStyle(color: _kSecond, fontSize: 11)),
                      ]),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _kGreen.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _kGreen.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '${d.oneRM.toStringAsFixed(1)} kg',
                    style: const TextStyle(
                        color: _kGreen,
                        fontWeight: FontWeight.w700,
                        fontSize: 14),
                  ),
                ),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

// ─── Reusable widgets ──────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(
              color: _kSecond,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            )),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
        ),
        child: child,
      );
}

class _Grid2x2 extends StatelessWidget {
  final List<Widget> children;
  const _Grid2x2({required this.children});
  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (int i = 0; i < children.length; i += 2) {
      rows.add(Row(
        children: [
          Expanded(child: children[i]),
          const SizedBox(width: 12),
          Expanded(
              child:
                  i + 1 < children.length ? children[i + 1] : const SizedBox()),
        ],
      ));
      if (i + 2 < children.length) rows.add(const SizedBox(height: 12));
    }
    return Column(children: rows);
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String unit;
  final TextEditingController ctrl;
  final TextInputType keyboard;
  final bool isLast;

  const _FieldRow({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.unit,
    required this.ctrl,
    this.keyboard = const TextInputType.numberWithOptions(decimal: true),
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          const Spacer(),
          SizedBox(
            width: 90,
            child: TextField(
              controller: ctrl,
              keyboardType: keyboard,
              inputFormatters: keyboard == TextInputType.number
                  ? positiveIntInput
                  : positiveDecimalInput,
              textAlign: TextAlign.right,
              textInputAction:
                  isLast ? TextInputAction.done : TextInputAction.next,
              onSubmitted: isLast
                  ? (_) => FocusScope.of(context).unfocus()
                  : (_) => FocusScope.of(context).nextFocus(),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: InputBorder.none,
                hintText: '—',
                hintStyle: const TextStyle(color: _kSecond),
                suffix: Text(' $unit',
                    style: const TextStyle(color: _kSecond, fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        height: 0.5,
        color: const Color(0xFF3A3A3C),
        margin: const EdgeInsets.symmetric(vertical: 2),
      );
}

/// Sex toggle — sets Mifflin-St Jeor constant (male: +5, female: −161).
/// Affects BMR → TDEE → recommended calorie goal.
class _SexToggleRow extends StatelessWidget {
  static const _kCard = Color(0xFF2C2C2E);

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final isMale = p.isMale;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(children: [
        const Icon(Icons.person_outline, color: Color(0xFF40C8E0), size: 20),
        const SizedBox(width: 12),
        const Expanded(
          child: Text('Biological Sex',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500)),
        ),
        // Toggle between Male / Female
        Container(
          decoration: BoxDecoration(
              color: _kCard, borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _SexBtn(
                label: '♂ Male',
                selected: isMale,
                onTap: () => context.read<FitnessProvider>().saveSex(true)),
            _SexBtn(
                label: '♀ Female',
                selected: !isMale,
                onTap: () => context.read<FitnessProvider>().saveSex(false)),
          ]),
        ),
      ]),
    );
  }
}

class _SexBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SexBtn(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => AppTappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF30D158) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.black : const Color(0xFF8E8E93),
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      );
}

class _SaveBtn extends StatelessWidget {
  final VoidCallback onPressed;
  const _SaveBtn({required this.onPressed});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _kGreen,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          child: const Text('Save',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      );
}

class _StatCard extends StatelessWidget {
  final String label, value, sub;
  final Color color;
  final IconData icon;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.sub,
      required this.color,
      required this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: _kSecond, size: 20),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500)),
          Text(sub, style: const TextStyle(color: _kSecond, fontSize: 11)),
        ]),
      );
}

class _ChartStat extends StatelessWidget {
  final String label, value;
  const _ChartStat(this.label, this.value);
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ]);
}

class _BmiLabel extends StatelessWidget {
  final String label, range;
  final Color color;
  const _BmiLabel(this.label, this.range, this.color);
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        Text(range, style: const TextStyle(color: _kSecond, fontSize: 11)),
      ]);
}

// ─── Mini weight chart ─────────────────────────────────────────────────────────
/// Interactive weight-over-time trend rendered with fl_chart's [LineChart],
/// for visual consistency with the app's other charts. Entries are expected
/// in chronological order. Gracefully handles 0- or 1-point series.
class _MiniWeightChart extends StatelessWidget {
  final List<BodyEntry> entries;
  final double goalWeightKg;
  const _MiniWeightChart({required this.entries, required this.goalWeightKg});

  @override
  Widget build(BuildContext context) {
    // Need at least 2 points to draw a meaningful line.
    if (entries.length < 2) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text('Not enough data yet',
              style: TextStyle(color: _kSecond, fontSize: 12)),
        ),
      );
    }

    final weights = entries.map((e) => e.weightKg).toList();
    final minW = weights.reduce((a, b) => a < b ? a : b);
    final maxW = weights.reduce((a, b) => a > b ? a : b);

    // Y padding: at least ±0.5 kg so a flat line isn't pinned to the edges.
    final span = (maxW - minW);
    final pad = (span * 0.15).clamp(0.5, double.infinity);
    double minY = minW - pad;
    double maxY = maxW + pad;

    // Include the goal line in range when it sits close to the data.
    final goalVisible =
        goalWeightKg >= minW - span - 2 && goalWeightKg <= maxW + span + 2;
    if (goalVisible) {
      if (goalWeightKg < minY) minY = goalWeightKg - 0.5;
      if (goalWeightKg > maxY) maxY = goalWeightKg + 0.5;
    }

    final spots = <FlSpot>[
      for (int i = 0; i < entries.length; i++)
        FlSpot(i.toDouble(), entries[i].weightKg),
    ];

    // 7-point trailing moving average — smooths daily water-weight noise so the
    // real trend is readable. Only shown once there's enough data to be useful.
    const avgWindow = 7;
    final showTrend = entries.length >= 5;
    final avgSpots = <FlSpot>[
      for (int i = 0; i < entries.length; i++)
        FlSpot(i.toDouble(), () {
          final start = (i - avgWindow + 1) < 0 ? 0 : i - avgWindow + 1;
          double sum = 0;
          for (int j = start; j <= i; j++) {
            sum += entries[j].weightKg;
          }
          return sum / (i - start + 1);
        }()),
    ];

    // Show ~4 date labels across the X axis.
    final n = entries.length;
    final labelStep = (n / 4).ceil().clamp(1, n);

    return SizedBox(
      height: 120,
      child: ChartEntrance(
        builder: (context, t) => ClipRect(
          clipper: RevealClipper(t),
          child: LineChart(
            duration:
                reduceMotion(context) ? Duration.zero : AppDurations.normal,
            curve: AppCurves.emphasized,
            LineChartData(
              minX: 0,
              maxX: (n - 1).toDouble(),
              minY: minY,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) =>
                    const FlLine(color: Color(0xFF38383A), strokeWidth: 0.5),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (v, meta) {
                      if (v == meta.min || v == meta.max) {
                        return const SizedBox.shrink();
                      }
                      return Text(v.toStringAsFixed(0),
                          style:
                              const TextStyle(color: _kSecond, fontSize: 11));
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: 1,
                    getTitlesWidget: (v, _) {
                      final idx = v.round();
                      if (idx < 0 || idx >= n) return const SizedBox.shrink();
                      // Always label the last point; otherwise space them out.
                      final isLast = idx == n - 1;
                      if (!isLast && idx % labelStep != 0) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          DateFormat('d MMM').format(entries[idx].date),
                          style: TextStyle(
                            color: isLast ? _kGreen : _kSecond,
                            fontSize: 11,
                            fontWeight:
                                isLast ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => const Color(0xFF2C2C2E),
                  getTooltipItems: (spots) => spots.map((s) {
                    // The 7-day trend line (barIndex 1) shows its own value.
                    if (s.barIndex == 1) {
                      return LineTooltipItem(
                        '${s.y.toStringAsFixed(1)} kg',
                        const TextStyle(
                            color: _kBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                        children: const [
                          TextSpan(
                            text: '\n7-day avg',
                            style: TextStyle(
                                color: _kSecond,
                                fontSize: 10,
                                fontWeight: FontWeight.w400),
                          ),
                        ],
                      );
                    }
                    final e = entries[s.x.round().clamp(0, n - 1)];
                    return LineTooltipItem(
                      '${e.weightKg.toStringAsFixed(1)} kg\n',
                      const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                      children: [
                        TextSpan(
                          text: DateFormat('d MMM yyyy').format(e.date),
                          style: const TextStyle(
                              color: _kSecond,
                              fontSize: 11,
                              fontWeight: FontWeight.w400),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  curveSmoothness: 0.25,
                  preventCurveOverShooting: true,
                  color: _kGreen,
                  barWidth: 2.5,
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, _, __, ___) {
                      final isLast = spot.x.round() == n - 1;
                      return FlDotCirclePainter(
                        radius: isLast ? 4 : 2.5,
                        color: _kGreen,
                        strokeWidth: isLast ? 2 : 0,
                        strokeColor: _kGreen.withValues(alpha: 0.3),
                      );
                    },
                  ),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _kGreen.withValues(alpha: 0.25),
                        _kGreen.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
                // 7-day trend overlay (drawn on top of the raw line).
                if (showTrend)
                  LineChartBarData(
                    spots: avgSpots,
                    isCurved: true,
                    curveSmoothness: 0.3,
                    preventCurveOverShooting: true,
                    color: _kBlue.withValues(alpha: 0.9),
                    barWidth: 2,
                    dashArray: const [6, 4],
                    dotData: const FlDotData(show: false),
                  ),
              ],
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (goalVisible)
                    HorizontalLine(
                      y: goalWeightKg,
                      color: _kOrange.withValues(alpha: 0.7),
                      strokeWidth: 1.5,
                      dashArray: [6, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.topRight,
                        padding: const EdgeInsets.only(right: 4, bottom: 2),
                        style: const TextStyle(
                            color: _kOrange,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                        labelResolver: (_) =>
                            'Goal ${goalWeightKg.toStringAsFixed(0)} kg',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── BMI Bar ───────────────────────────────────────────────────────────────────
class _BmiBar extends StatelessWidget {
  final double? bmi;
  const _BmiBar({this.bmi});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 18,
        child: LayoutBuilder(builder: (_, c) {
          const segs = [_kBlue, _kGreen, _kOrange, _kRed];
          return Stack(children: [
            Row(children: [
              for (int i = 0; i < 4; i++)
                Expanded(
                    child: Container(
                  decoration: BoxDecoration(
                    color: segs[i],
                    borderRadius: BorderRadius.horizontal(
                      left: i == 0 ? const Radius.circular(8) : Radius.zero,
                      right: i == 3 ? const Radius.circular(8) : Radius.zero,
                    ),
                  ),
                )),
            ]),
            if (bmi != null)
              Positioned(
                left: (((bmi! - 15) / 25).clamp(0.0, 1.0) * (c.maxWidth - 12)),
                top: 1,
                child: Container(
                  width: 12,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ],
                  ),
                ),
              ),
          ]);
        }),
      );
}

// ─── Body Measurements Section ────────────────────────────────────────────────
class _MeasurementsSection extends StatefulWidget {
  final FitnessProvider provider;
  const _MeasurementsSection({required this.provider});
  @override
  State<_MeasurementsSection> createState() => _MeasurementsSectionState();
}

class _MeasurementsSectionState extends State<_MeasurementsSection> {
  final _chestCtrl = TextEditingController();
  final _waistCtrl = TextEditingController();
  final _hipsCtrl = TextEditingController();
  final _armCtrl = TextEditingController();
  final _thighCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefill());
  }

  void _prefill() {
    final m = widget.provider.latestMeasurements;
    if (m == null) {
      if (mounted) setState(() {}); // force label update
      return;
    }
    if (_chestCtrl.text.isEmpty && m.chestCm != null)
      _chestCtrl.text = m.chestCm!.toStringAsFixed(1);
    if (_waistCtrl.text.isEmpty && m.waistCm != null)
      _waistCtrl.text = m.waistCm!.toStringAsFixed(1);
    if (_hipsCtrl.text.isEmpty && m.hipsCm != null)
      _hipsCtrl.text = m.hipsCm!.toStringAsFixed(1);
    if (_armCtrl.text.isEmpty && m.leftArmCm != null)
      _armCtrl.text = m.leftArmCm!.toStringAsFixed(1);
    if (_thighCtrl.text.isEmpty && m.leftThighCm != null)
      _thighCtrl.text = m.leftThighCm!.toStringAsFixed(1);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_chestCtrl, _waistCtrl, _hipsCtrl, _armCtrl, _thighCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final p = context.read<FitnessProvider>();
    final entry = MeasurementEntry(
      id: const Uuid().v4(),
      date: DateTime.now(),
      chestCm: double.tryParse(_chestCtrl.text.trim()),
      waistCm: double.tryParse(_waistCtrl.text.trim()),
      hipsCm: double.tryParse(_hipsCtrl.text.trim()),
      leftArmCm: double.tryParse(_armCtrl.text.trim()),
      leftThighCm: double.tryParse(_thighCtrl.text.trim()),
    );
    if (entry.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Enter at least one measurement'),
        backgroundColor: _kRed,
      ));
      return;
    }
    await p.logMeasurement(entry);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Measurements saved ✓'),
        backgroundColor: _kGreen,
        duration: Duration(seconds: 1),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final recent = p.getRecentMeasurements(days: 90);
    final latest = widget.provider.latestMeasurements;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (latest != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Pre-filled from ${latest.date.day}/${latest.date.month}/${latest.date.year} — update changed values only',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
          ),
        ),
      _Card(
          child: Column(children: [
        _FieldRow(
            label: 'Chest',
            icon: Icons.straighten_outlined,
            iconColor: _kGreen,
            unit: 'cm',
            ctrl: _chestCtrl),
        _HDivider(),
        _FieldRow(
            label: 'Waist',
            icon: Icons.straighten_outlined,
            iconColor: _kGreen,
            unit: 'cm',
            ctrl: _waistCtrl),
        _HDivider(),
        _FieldRow(
            label: 'Hips',
            icon: Icons.straighten_outlined,
            iconColor: _kBlue,
            unit: 'cm',
            ctrl: _hipsCtrl),
        _HDivider(),
        _FieldRow(
            label: 'Left Arm',
            icon: Icons.fitness_center_outlined,
            iconColor: _kBlue,
            unit: 'cm',
            ctrl: _armCtrl),
        _HDivider(),
        _FieldRow(
            label: 'Left Thigh',
            icon: Icons.directions_run_outlined,
            iconColor: _kOrange,
            unit: 'cm',
            ctrl: _thighCtrl,
            isLast: true),
        const SizedBox(height: 14),
        _SaveBtn(onPressed: _save),
      ])),
      if (recent.length >= 2) ...[
        const SizedBox(height: 12),
        _Card(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Trend (last 5 logs)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _MeasurementTrendRow(
                'Chest', recent.map((e) => e.chestCm).toList()),
            _MeasurementTrendRow(
                'Waist', recent.map((e) => e.waistCm).toList()),
            _MeasurementTrendRow('Hips', recent.map((e) => e.hipsCm).toList()),
            _MeasurementTrendRow(
                'Arm', recent.map((e) => e.leftArmCm).toList()),
            _MeasurementTrendRow(
                'Thigh', recent.map((e) => e.leftThighCm).toList()),
          ],
        )),
      ],
    ]);
  }
}

class _MeasurementTrendRow extends StatelessWidget {
  final String label;
  final List<double?> values;
  const _MeasurementTrendRow(this.label, this.values);

  @override
  Widget build(BuildContext context) {
    final nonNull = values.where((v) => v != null).cast<double>().toList();
    if (nonNull.isEmpty) return const SizedBox.shrink();
    final latest = nonNull.last;
    final prev = nonNull.length >= 2 ? nonNull[nonNull.length - 2] : null;
    final delta = prev != null ? latest - prev : null;
    final deltaStr = delta == null
        ? ''
        : delta < 0
            ? '  ▼ ${delta.abs().toStringAsFixed(1)} cm'
            : delta > 0
                ? '  ▲ +${delta.toStringAsFixed(1)} cm'
                : '  — no change';
    final deltaColor = delta == null
        ? _kSecond
        : label == 'Chest' || label == 'Arm' || label == 'Thigh'
            ? (delta < 0 ? _kSecond : _kGreen)
            : (delta < 0 ? _kGreen : _kRed);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        SizedBox(
            width: 52,
            child: Text(label,
                style: const TextStyle(color: _kSecond, fontSize: 12))),
        Text('${latest.toStringAsFixed(1)} cm',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        if (delta != null)
          Text(deltaStr, style: TextStyle(color: deltaColor, fontSize: 11)),
        const Spacer(),
        // Sparkline: show last 5 values as a mini line chart
        if (nonNull.length >= 2)
          SizedBox(
            width: 60,
            height: 24,
            child: CustomPaint(
                painter: _SparklinePainter(nonNull.takeLast(5), deltaColor)),
          ),
      ]),
    );
  }
}

extension _TakeLast<T> on List<T> {
  List<T> takeLast(int n) => length > n ? sublist(length - n) : this;
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const _SparklinePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs();

    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final norm = range < 0.01 ? 0.5 : (values[i] - minV) / range;
      // Invert: lower value = lower on chart (naturally for waist = good going down)
      final y = size.height - norm * size.height;
      if (i == 0)
        path.moveTo(x, y);
      else
        path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);

    // Dot at latest value
    final lx = size.width;
    final ln = range < 0.01 ? 0.5 : (values.last - minV) / range;
    final ly = size.height - ln * size.height;
    canvas.drawCircle(
        Offset(lx, ly),
        3,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}
