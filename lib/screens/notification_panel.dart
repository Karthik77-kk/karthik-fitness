import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../widgets/kit/kit.dart';

const _kCard = Color(0xFF1E1E22);

// Maps InsightCategory.name → Material icon for notification tiles.
const _kInsightIcons = <String, IconData>{
  'weight': Icons.monitor_weight_rounded,
  'prediction': Icons.trending_down_rounded,
  'nutrition': Icons.restaurant_rounded,
  'hydration': Icons.water_drop_rounded,
  'activity': Icons.directions_walk_rounded,
  'workout': Icons.fitness_center_rounded,
  'bodyComp': Icons.accessibility_new_rounded,
  'measurements': Icons.straighten_rounded,
  'motivation': Icons.local_fire_department_rounded,
};
const _kGreen = Color(0xFF30D158);
const _kBlue = Color(0xFF40C8E0);
const _kRed = Color(0xFFFF453A);
const _kOrange = Color(0xFFFF9F0A);
const _kSecond = Color(0xFF8E8E93);

/// Opens the in-app notification center as a full page.
void openNotifications(BuildContext context) {
  context.read<FitnessProvider>().markNotificationsRead();
  Navigator.push(context, sharedAxisRoute(const NotificationsScreen()));
}

class NotificationsScreen extends StatelessWidget {
  /// Test-only clock override so the time-gated sections (Morning Brief / Night
  /// Check-In / reminders) are deterministically renderable. Null in production.
  final DateTime? clockOverride;
  const NotificationsScreen({super.key, this.clockOverride});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final insights = p.liveInsightFeed;
    final milestones = p.milestoneFeed;
    final hour = (clockOverride ?? DateTime.now()).hour;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (milestones.isNotEmpty)
            TextButton(
              onPressed: () => context.read<FitnessProvider>().clearNotifications(),
              child: const Text('Clear', style: TextStyle(color: _kSecond)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // ── Morning Brief (before 1 PM) ─────────────────────────────────────
          if (hour < 13) ...[
            _MorningBriefSection(p: p),
            const SizedBox(height: 20),
          ],

          // ── Daily Reminders (time-aware) ────────────────────────────────────
          ..._buildReminders(p, hour),

          // ── Live Insights ───────────────────────────────────────────────────
          if (insights.isNotEmpty) ...[
            _SectionLabel('RIGHT NOW', subtitle: 'Live — updates as your day changes'),
            ...insights.map((n) => _NotificationTile(n, showTime: false)),
            const SizedBox(height: 18),
          ],

          // ── Night Check-In (after 8 PM) ─────────────────────────────────────
          if (hour >= 20) ...[
            _NightCheckSection(p: p),
            const SizedBox(height: 20),
          ],

          // ── Achievements ────────────────────────────────────────────────────
          if (milestones.isNotEmpty) ...[
            const _SectionLabel('ACHIEVEMENTS'),
            ...milestones.map((n) => _NotificationTile(n, showTime: true)),
          ],

          if (insights.isEmpty && milestones.isEmpty)
            const _EmptyState(),
        ],
      ),
    );
  }

  List<Widget> _buildReminders(FitnessProvider p, int hour) {
    final reminders = <_ReminderItem>[];

    // Water reminder: after 10 AM if under 40%
    if (hour >= 10 && p.todayWaterMl < p.waterGoalMl * 0.4) {
      reminders.add(_ReminderItem(
        emoji: '💧',
        color: _kBlue,
        title: 'Hydration check',
        body: 'Only ${p.todayWaterMl} ml logged — ${p.waterGoalMl - p.todayWaterMl} ml to go. '
            'A 500 ml glass now before you forget.',
      ));
    }

    // Food reminder: after 2 PM if nothing logged today
    if (hour >= 14 && p.todayCaloriesTotal < 200) {
      reminders.add(_ReminderItem(
        emoji: '🍽️',
        color: _kOrange,
        title: 'No meals logged today',
        body: 'Log your food — even rough estimates keep you on track and '
            'feed the AI coach with better patterns.',
      ));
    }

    // Workout reminder: after 4 PM. For a user who has trained before, nudge
    // when it's been 2+ days; for one who never has, invite a first session
    // (never render "999 days since your last workout").
    if (hour >= 16) {
      if (!p.hasEverLoggedWorkout) {
        reminders.add(_ReminderItem(
          emoji: '🏋️',
          color: _kOrange,
          title: 'Log your first workout',
          body: 'Start your streak tonight — even 20 min of push-ups, squats '
              'and planks counts.',
        ));
      } else if (p.daysSinceLastWorkout >= 2) {
        reminders.add(_ReminderItem(
          emoji: '🏋️',
          color: _kOrange,
          title: '${p.daysSinceLastWorkout} days since last workout',
          body: 'Even 20 min of push-ups, squats and planks counts. '
              'Log a session tonight to keep your streak alive.',
        ));
      }
    }

    // Walk reminder: after noon if under 50% steps
    if (hour >= 12 && p.todaySteps < p.stepGoal * 0.5) {
      final stepPct = p.stepGoal > 0
          ? (p.todaySteps / p.stepGoal * 100).round()
          : 0;
      final stepsLeft = (p.stepGoal - p.todaySteps).clamp(0, p.stepGoal);
      reminders.add(_ReminderItem(
        emoji: '🚶',
        color: _kBlue,
        title: '${_fmtK(p.todaySteps)} of ${_fmtK(p.stepGoal)} steps ($stepPct%)',
        body: '${_fmtK(stepsLeft)} to go. A 20-min walk after lunch adds ~2,000 steps, '
            'burns ~${_walkKcal(p.latestWeightKg)} kcal, and lowers post-meal blood sugar.',
      ));
    }

    if (reminders.isEmpty) return [];
    return [
      _SectionLabel('REMINDERS', subtitle: 'Based on today\'s patterns'),
      for (final r in reminders) _ReminderCard(r),
      const SizedBox(height: 18),
    ];
  }
}

// ── Morning Brief ─────────────────────────────────────────────────────────────

class _MorningBriefSection extends StatelessWidget {
  final FitnessProvider p;
  const _MorningBriefSection({required this.p});

  @override
  Widget build(BuildContext context) {
    final yesterday = p.yesterdayCal > 0 || p.yesterdayProtein > 0 || p.yesterdayWater > 0;
    final now = DateTime.now();
    final greeting = _greeting(now.hour);
    final dateStr = _fmtDate(now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('MORNING BRIEF', subtitle: dateStr),
        // Greeting card
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _kGreen.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kGreen.withValues(alpha: 0.25)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$greeting ${p.userName}!',
                style: const TextStyle(color: _kGreen, fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_focusTip(p),
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
          ]),
        ),
        // Goals card
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("TODAY'S TARGETS",
                style: TextStyle(color: _kSecond, fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 0.7)),
            const SizedBox(height: 10),
            _GoalRow(Icons.local_fire_department_rounded, 'Calories', '${p.calorieGoal} kcal', _kRed),
            const SizedBox(height: 6),
            _GoalRow(Icons.fitness_center_rounded, 'Protein', '${p.proteinGoal} g', _kGreen),
            const SizedBox(height: 6),
            _GoalRow(Icons.water_drop_rounded, 'Water', '${(p.waterGoalMl / 1000).toStringAsFixed(1)} L', _kBlue),
            const SizedBox(height: 6),
            _GoalRow(Icons.directions_walk_rounded, 'Steps', '${_fmtK(p.stepGoal)}', _kOrange),
          ]),
        ),
        // Yesterday recap
        if (yesterday)
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text("YESTERDAY",
                  style: TextStyle(color: _kSecond, fontSize: 11, fontWeight: FontWeight.w700,
                      letterSpacing: 0.7)),
              const SizedBox(height: 10),
              _YesterdayRow(p),
            ]),
          ),
      ],
    );
  }

  String _greeting(int hour) {
    if (hour < 12) return 'Good morning,';
    return 'Hey,';
  }

  String _focusTip(FitnessProvider p) {
    // Find weakest category and give a tip
    final calAdh = p.calorieAdherenceRate;
    final protAdh = p.proteinAdherenceRate;
    final watAdh = p.waterAdherenceRate;
    final wkWorkouts = p.weeklyWorkoutDays;

    if (protAdh > 0 && protAdh < 0.5) {
      return 'Today\'s focus: protein. You hit ${p.proteinGoal}g on only ${(protAdh * 100).round()}% of recent days. '
          'Start with eggs or a whey shake at breakfast.';
    }
    if (watAdh > 0 && watAdh < 0.5) {
      return 'Today\'s focus: hydration. You\'ve been under your water goal most days. '
          'Keep a bottle on your desk — drink before each meal.';
    }
    if (wkWorkouts == 0) {
      return 'No workouts logged this week yet. Even one session today makes a difference '
          'for muscle retention and strength.';
    }
    if (calAdh > 0 && calAdh < 0.5) {
      return 'Today\'s focus: calories. You\'re hitting your ${p.calorieGoal} kcal target about '
          '${(calAdh * 100).round()}% of days. Log meals early so the AI can guide you.';
    }
    if (p.wantsDeficit && p.deficitStreak >= 3) {
      return '${p.deficitStreak}-day deficit streak — great momentum. Stay consistent and protect that protein.';
    }
    return 'Hit ${p.calorieGoal} kcal, ${p.proteinGoal}g protein and ${(p.waterGoalMl / 1000).toStringAsFixed(1)} L water. '
        'Log everything — your data makes the AI coaching smarter.';
  }

  String _fmtDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}

class _GoalRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _GoalRow(this.icon, this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 13)),
        const Spacer(),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
      ]);
}

class _YesterdayRow extends StatelessWidget {
  final FitnessProvider p;
  const _YesterdayRow(this.p);

  @override
  Widget build(BuildContext context) {
    final calOk = p.yesterdayCal >= p.calorieGoal * 0.85 && p.yesterdayCal <= p.calorieGoal * 1.15;
    final protOk = p.yesterdayProtein >= p.proteinGoal * 0.9;
    final waterOk = p.yesterdayWater >= p.waterGoalMl * 0.9;
    final workoutOk = p.workedOutYesterday;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _YesterdayStat('🔥', '${p.yesterdayCal.round()}', 'kcal', calOk),
        _YesterdayStat('💪', '${p.yesterdayProtein.round()}g', 'protein', protOk),
        _YesterdayStat('💧', '${(p.yesterdayWater / 1000).toStringAsFixed(1)}L', 'water', waterOk),
        _YesterdayStat('🏋️', workoutOk ? 'Done' : 'Rest', 'workout', workoutOk),
      ],
    );
  }
}

class _YesterdayStat extends StatelessWidget {
  final String emoji;
  final String value;
  final String label;
  final bool ok;
  const _YesterdayStat(this.emoji, this.value, this.label, this.ok);

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                color: ok ? _kGreen : _kOrange,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 10)),
      ]);
}

// ── Night Check-In ────────────────────────────────────────────────────────────

class _NightCheckSection extends StatelessWidget {
  final FitnessProvider p;
  const _NightCheckSection({required this.p});

  @override
  Widget build(BuildContext context) {
    final calPct = p.calorieGoal > 0 ? p.todayCaloriesTotal / p.calorieGoal : 0.0;
    final protPct = p.proteinGoal > 0 ? p.todayProteinTotal / p.proteinGoal : 0.0;
    final waterPct = p.waterGoalMl > 0 ? p.todayWaterMl / p.waterGoalMl : 0.0;
    final stepPct = p.stepGoal > 0 ? p.todaySteps / p.stepGoal : 0.0;

    final goodDay = calPct >= 0.85 && calPct <= 1.15 && protPct >= 0.9;
    final accentColor = goodDay ? _kGreen : _kOrange;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _SectionLabel('TONIGHT', subtitle: 'How today is shaping up'),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accentColor.withValues(alpha: 0.22)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(goodDay ? '✅ Solid day, ${p.userName}' : '📋 Not done yet — finish strong',
              style: TextStyle(
                  color: accentColor, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          _NightStatRow('Calories', p.todayCaloriesTotal.round(), p.calorieGoal, 'kcal', _kRed, calPct),
          const SizedBox(height: 6),
          _NightStatRow('Protein', p.todayProteinTotal.round(), p.proteinGoal, 'g', _kGreen, protPct),
          const SizedBox(height: 6),
          _NightStatRow('Water', p.todayWaterMl, p.waterGoalMl, 'ml', _kBlue, waterPct),
          const SizedBox(height: 6),
          _NightStatRow('Steps', p.todaySteps, p.stepGoal, '', _kOrange, stepPct),
          const SizedBox(height: 12),
          Text(_tomorrowTip(p),
              style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.5)),
        ]),
      ),
    ]);
  }

  String _tomorrowTip(FitnessProvider p) {
    final calPct = p.calorieGoal > 0 ? p.todayCaloriesTotal / p.calorieGoal : 0.0;
    final protPct = p.proteinGoal > 0 ? p.todayProteinTotal / p.proteinGoal : 0.0;
    if (protPct < 0.8) {
      return 'Tomorrow: start with a high-protein breakfast — 3 eggs or a whey shake '
          'gets you to 25–30g before 10 AM.';
    }
    // Calorie framing flips with the goal: for a gain goal, finishing under the
    // target is the problem; for lose/maintain, finishing well over is.
    if (p.wantsSurplus) {
      if (calPct < 0.9) {
        return 'Tomorrow: add a calorie-dense snack — you came in under your goal, '
            'and a steady surplus is what builds size.';
      }
    } else if (calPct > 1.2) {
      return p.wantsDeficit
          ? 'Tomorrow: skip the evening snack. Plan dinner by 8 PM and close the kitchen.'
          : 'Tomorrow: ease back at dinner to land near your maintenance goal.';
    }
    if (p.hasEverLoggedWorkout && p.daysSinceLastWorkout >= 2) {
      return 'Tomorrow: log a workout session, even a short one. Consistent training '
          '${p.wantsSurplus ? 'drives the muscle growth you\'re after.' : 'keeps your metabolism up and protects muscle.'}';
    }
    return 'Tomorrow: stay consistent. Log meals early so the coach can guide you '
        'before you go off track.';
  }
}

class _NightStatRow extends StatelessWidget {
  final String label;
  final int value;
  final int goal;
  final String unit;
  final Color color;
  final double pct;
  const _NightStatRow(this.label, this.value, this.goal, this.unit, this.color, this.pct);

  @override
  Widget build(BuildContext context) {
    final achieved = pct >= 0.9;
    return Row(children: [
      SizedBox(
        width: 68,
        child: Text(label, style: const TextStyle(color: _kSecond, fontSize: 12)),
      ),
      Text('$value / $goal$unit',
          style: TextStyle(
              color: achieved ? color : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
      const Spacer(),
      Text(achieved ? '✓' : '${(pct * 100).round()}%',
          style: TextStyle(color: achieved ? _kGreen : _kSecond, fontSize: 12)),
    ]);
  }
}

// ── Reminders ─────────────────────────────────────────────────────────────────

class _ReminderItem {
  final String emoji;
  final Color color;
  final String title;
  final String body;
  const _ReminderItem({required this.emoji, required this.color,
      required this.title, required this.body});
}

class _ReminderCard extends StatelessWidget {
  final _ReminderItem r;
  const _ReminderCard(this.r);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: r.color.withValues(alpha: 0.18)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: r.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(r.emoji, style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title,
                style: TextStyle(color: r.color, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(r.body,
                style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.45)),
          ])),
        ]),
      );
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('🔔', style: TextStyle(fontSize: 52)),
            SizedBox(height: 16),
            Text('Nothing right now',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text('Live coaching tips and your milestones will appear here as you log.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _kSecond, fontSize: 13, height: 1.5)),
          ]),
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? subtitle;
  const _SectionLabel(this.text, {this.subtitle});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text,
              style: const TextStyle(
                  color: _kSecond, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle!,
                  style: TextStyle(color: _kSecond.withValues(alpha: 0.7), fontSize: 11)),
            ),
        ]),
      );
}

class _NotificationTile extends StatelessWidget {
  final AppNotification n;
  final bool showTime;
  const _NotificationTile(this.n, {required this.showTime});

  String _relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final accent = Color(n.accent);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: n.insightCategory != null && _kInsightIcons.containsKey(n.insightCategory)
              ? Icon(_kInsightIcons[n.insightCategory]!, size: 18, color: accent)
              : Text(n.emoji, style: const TextStyle(fontSize: 18)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(n.title,
                    style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              if (showTime) ...[
                const SizedBox(width: 6),
                Text(_relative(n.timestamp),
                    style: const TextStyle(color: _kSecond, fontSize: 10)),
              ],
            ]),
            const SizedBox(height: 4),
            Text(n.body,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtK(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k' : '$n';

// Uses the shared walk-burn helper (MET 3.5) so this matches the AI-coach
// insight card exactly — they previously disagreed (5.0 here vs 3.5 there).
int _walkKcal(double? weightKg) =>
    walkCaloriesForMinutes(weightKg, minutes: 20);
