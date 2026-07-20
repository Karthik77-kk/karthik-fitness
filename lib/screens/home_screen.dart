import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:confetti/confetti.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../services/haptics.dart';
import '../theme/app_tokens.dart';
import '../widgets/kit/kit.dart';
import 'settings_screen.dart';
import 'notification_panel.dart';
import 'chat_screen.dart';
import 'weekly_recap_screen.dart';

// ─── Design tokens ─────────────────────────────────────────────────────────────
// These local aliases now point at the single source of truth in app_tokens.dart
// so the palette is defined in exactly one place (call sites stay unchanged).
const _kGreen = AppColors.green;
const _kBlue = AppColors.blue;
const _kRed = AppColors.red;
const _kOrange = AppColors.orange;
const _kCard = AppColors.card;
const _kSecond = AppColors.muted;

// ─── Home Screen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Timer _refreshTimer;
  bool _showEmptySections = false;
  final ConfettiController _confetti =
      ConfettiController(duration: const Duration(seconds: 2));

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    _confetti.dispose();
    super.dispose();
  }

  int _hiddenCount(FitnessProvider p) {
    int n = 0;
    if (p.weeklyAvgCalories == 0) n++; // 7-day chart
    if (p.todayFood.isEmpty) n++; // macro donut
    return n;
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 6) return 'night';
    if (h < 12) return 'morning';
    if (h < 17) return 'afternoon';
    if (h < 21) return 'evening';
    return 'evening';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final today = DateFormat('EEEE, MMMM d').format(DateTime.now());
    final bottomPad = MediaQuery.of(context).padding.bottom;

    // Fire a one-shot confetti burst when a new milestone (streak / goal) lands.
    if (p.hasPendingCelebration && !reduceMotion(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<FitnessProvider>().consumeCelebration();
        Haptics.heavy(); // milestone lands — make it felt
        _confetti.play();
      });
    } else if (p.hasPendingCelebration) {
      // Reduced motion: acknowledge without animating so it doesn't re-trigger.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => context.read<FitnessProvider>().consumeCelebration());
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        RefreshIndicator(
          color: _kGreen,
          backgroundColor: _kCard,
          onRefresh: () async {
            await context.read<FitnessProvider>().loadData();
          },
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 84,
                pinned: true,
                // Translucent + a backdrop blur so the scrolled feed frosts under
                // the pinned header (content already scrolls beneath a pinned
                // SliverAppBar, so no extendBodyBehindAppBar / top-inset audit).
                backgroundColor: Colors.black.withValues(alpha: 0.55),
                surfaceTintColor: Colors.transparent,
                // Greeting + streak live in the collapsing background so they fade
                // out on scroll and never overlap the pinned action icons.
                flexibleSpace: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: FlexibleSpaceBar(
                      background: SafeArea(
                        child: Padding(
                          // right padding clears the pinned bell + settings icons
                          padding: const EdgeInsets.fromLTRB(20, 6, 96, 0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(today,
                                  style: const TextStyle(
                                      color: _kSecond,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w400)),
                              const SizedBox(height: 2),
                              Row(children: [
                                Flexible(
                                  child: Text(
                                    'Good ${_greeting()}, ${context.watch<FitnessProvider>().userName}! 👋',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                ),
                                if (p.workoutStreak > 0) ...[
                                  const SizedBox(width: 8),
                                  _StreakBadge(streak: p.workoutStreak),
                                ],
                              ]),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                actions: [
                  _NotificationBell(unread: p.unreadNotifications),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 22),
                    onPressed: () => Navigator.push(
                        context, sharedAxisRoute(const SettingsScreen())),
                  ),
                ],
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 32 + bottomPad),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(_staggerIn(context, [
                    // ── AI Coach (top) — hidden when disabled in Settings ─────
                    if (p.aiCoachEnabled) ...[
                      const _SectionHdr('AI COACH'),
                      const SizedBox(height: 8),
                      AppCard(
                        onTap: () => openChat(context),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        radius: 14,
                        gradient: LinearGradient(
                          colors: [
                            _kGreen.withValues(alpha: 0.14),
                            _kBlue.withValues(alpha: 0.07),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        border:
                            Border.all(color: _kGreen.withValues(alpha: 0.3)),
                        child: Row(children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: _kGreen.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.smart_toy_rounded,
                                color: _kGreen, size: 22),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                              child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Ask AI Coach',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 2),
                              Text('Ask about your diet, workouts & progress',
                                  style:
                                      TextStyle(color: _kSecond, fontSize: 12)),
                            ],
                          )),
                          Icon(Icons.chevron_right_rounded,
                              color: _kGreen.withValues(alpha: 0.7), size: 22),
                        ]),
                      ),
                      const SizedBox(height: 20),
                      // Once-a-day cloud AI "daily brief" (only when generated).
                      if (p.dailyBrief?.isNotEmpty ?? false) ...[
                        _DailyBriefCard(text: p.dailyBrief!),
                        const SizedBox(height: 20),
                      ],
                    ],

                    // ── Getting-started card (shows until user logs weight, food, or workout) ─
                    if (p.latestWeightKg == null &&
                        p.todayFood.isEmpty &&
                        p.workoutHistory.isEmpty)
                      const _GettingStartedCard(),
                    if (p.latestWeightKg == null &&
                        p.todayFood.isEmpty &&
                        p.workoutHistory.isEmpty)
                      const SizedBox(height: 20),

                    // ── Backup reminder (data is on-device only) ──────────────
                    if (p.needsBackupReminder) ...[
                      const _BackupReminderCard(),
                      const SizedBox(height: 20),
                    ],

                    // ── Activity rings ────────────────────────────────────────
                    const _SectionHdr('TODAY\'S ACTIVITY'),
                    const SizedBox(height: 10),
                    _ActivityRingsCard(provider: p),
                    const SizedBox(height: 20),

                    // ── Calorie balance hero (eaten vs burned + burn breakdown) ─
                    const _SectionHdr('CALORIE BALANCE'),
                    const SizedBox(height: 10),
                    const _CalorieRingTile(),
                    const SizedBox(height: 20),

                    // ── Weekly calorie bar chart (hidden when no data logged yet) ──
                    if (_showEmptySections || p.weeklyAvgCalories > 0) ...[
                      const _SectionHdr('7-DAY CALORIES'),
                      const SizedBox(height: 10),
                      // Has touch tooltips — leave pointer events enabled.
                      RepaintBoundary(child: _WeeklyCalorieChart(provider: p)),
                      const SizedBox(height: 20),
                    ],

                    // ── Macro donut (shown when there's any intake — food OR a
                    // checked whey supplement, which adds 25g protein) ────────
                    if (_showEmptySections ||
                        p.todayFood.isNotEmpty ||
                        p.supplementCalories > 0) ...[
                      const _SectionHdr('TODAY\'S MACROS'),
                      const SizedBox(height: 10),
                      // Display-only donut — no tap handlers, so exclude from hit-test
                      // tree to avoid intercepting scroll events.
                      RepaintBoundary(
                          child: IgnorePointer(
                              child: _MacroDonutCard(provider: p))),
                      const SizedBox(height: 20),
                    ],

                    // ── Steps + Water ─────────────────────────────────────────
                    const _SectionHdr('MOVE & HYDRATE'),
                    const SizedBox(height: 10),
                    const _StepsWaterRow(),
                    const SizedBox(height: 20),

                    // ── Body stats ────────────────────────────────────────────
                    const _BodyStatsTile(),
                    const SizedBox(height: 20),

                    // ── Weight prediction chart ───────────────────────────────
                    if (p.getRecentBodyEntries(days: 90).length >= 3) ...[
                      const _SectionHdr('WEIGHT PREDICTION (AI TREND)'),
                      const SizedBox(height: 10),
                      // CustomPaint chart with no touch interaction.
                      RepaintBoundary(
                          child: IgnorePointer(
                              child: _WeightPredictionCard(provider: p))),
                      const SizedBox(height: 20),
                    ],

                    // ── Workout ───────────────────────────────────────────────
                    const _SectionHdr('WORKOUT'),
                    const SizedBox(height: 10),
                    _WorkoutCard(workouts: p.todayWorkouts),
                    const SizedBox(height: 20),

                    // ── Supplements ───────────────────────────────────────────
                    const _SectionHdr('SUPPLEMENTS'),
                    const SizedBox(height: 10),
                    _SupplementsCard(supp: p.supplements),
                    const SizedBox(height: 20),

                    // ── Weekly report ─────────────────────────────────────────
                    Row(children: [
                      const _SectionHdr('LAST 7 DAYS'),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.push(context,
                            sharedAxisRoute(const WeeklyRecapScreen())),
                        child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Recap',
                                  style: TextStyle(
                                      color: _kGreen,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                              SizedBox(width: 2),
                              Icon(Icons.auto_awesome_rounded,
                                  color: _kGreen, size: 14),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    _WeeklyReportCard(provider: p),
                    const SizedBox(height: 20),

                    // ── Progressive-disclosure toggle ─────────────────────────
                    Builder(builder: (ctx) {
                      final hidden = _hiddenCount(p); // computed once per build
                      if (hidden == 0) return const SizedBox.shrink();
                      return _ShowMoreSections(
                        count: _showEmptySections ? 0 : hidden,
                        onTap: () => setState(
                            () => _showEmptySections = !_showEmptySections),
                      );
                    }),
                    const SizedBox(height: 8),
                  ])),
                ),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confetti,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 18,
            maxBlastForce: 18,
            minBlastForce: 6,
            gravity: 0.25,
            emissionFrequency: 0.04,
            colors: const [_kGreen, _kBlue, _kOrange, _kRed],
          ),
        ),
      ]),
    );
  }

  /// Wraps each non-spacer section in a fade-in + slide-up with a cumulative
  /// stagger so the feed assembles itself on screen entry. Returns the list
  /// unchanged when the OS "reduce motion" setting is on. Spacers are passed
  /// through untouched so the stagger reads as one section after another.
  List<Widget> _staggerIn(BuildContext context, List<Widget> items) {
    if (reduceMotion(context)) return items;
    // Only the first few (above-the-fold) sections animate, and they stay wrapped
    // for the screen's lifetime. We must NOT unwrap them after an entrance window:
    // swapping `Animate(child: x)` back to `x` changes the widget type at that
    // slot, so Flutter remounts the section and its inner TweenAnimationBuilder
    // replays its 0→value sweep — that was the cold-start "double animation"
    // (the unwrap fired at 700ms, exactly when the 700ms ring sweep finished).
    // flutter_animate plays each entry once on mount and never again on a plain
    // rebuild (it only replays on a duration/target change — see Animate
    // .didUpdateWidget), so leaving the wrappers in place is cheap and correct.
    // Sections past the cap are never wrapped, so a fast scroll can't leave them
    // blank waiting behind a delay.
    const cap = 6;
    final out = <Widget>[];
    var step = 0;
    for (final w in items) {
      if (w is SizedBox || step >= cap) {
        out.add(w);
      } else {
        out.add(w
            .animate(delay: (AppDurations.stagger.inMilliseconds * step).ms)
            .fadeIn(duration: 250.ms)
            .slideY(begin: 0.08, end: 0, curve: AppCurves.emphasized));
        step++;
      }
    }
    return out;
  }
}

// ─── Show-more toggle ─────────────────────────────────────────────────────────
class _ShowMoreSections extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ShowMoreSections({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isCollapsed = count > 0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF38383A)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
            isCollapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
            color: const Color(0xFF8E8E93),
            size: 18,
          ),
          const SizedBox(width: 6),
          Text(
            isCollapsed
                ? '$count section${count == 1 ? '' : 's'} hidden — no data yet'
                : 'Collapse empty sections',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
          ),
        ]),
      ),
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────────
String _fmtInt(int n) {
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
  return '$n';
}

// ─── Section header ────────────────────────────────────────────────────────────
class _SectionHdr extends StatelessWidget {
  final String text;
  const _SectionHdr(this.text);
  @override
  Widget build(BuildContext context) => SectionHeader(text);
}

// ─── Notification bell ─────────────────────────────────────────────────────────
class _NotificationBell extends StatelessWidget {
  final int unread;
  const _NotificationBell({required this.unread});
  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            icon: const Icon(Icons.notifications_none_rounded, size: 27),
            onPressed: () => openNotifications(context),
          ),
        ),
        if (unread > 0)
          Positioned(
            top: 8,
            right: 7,
            child: Container(
              padding: const EdgeInsets.all(2),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              decoration: BoxDecoration(
                color: _kRed,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black, width: 1.5),
              ),
              child: Text(
                unread > 9 ? '9+' : '$unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Streak badge ──────────────────────────────────────────────────────────────
class _StreakBadge extends StatelessWidget {
  final int streak;
  const _StreakBadge({required this.streak});
  @override
  Widget build(BuildContext context) {
    if (streak == 0) return const SizedBox.shrink();
    return Semantics(
      label: '$streak-day workout streak',
      // The Row's icon + text are decorative once the label reads the value.
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _kOrange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kOrange.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.local_fire_department_rounded,
              size: 14, color: _kOrange),
          const SizedBox(width: 4),
          Text('$streak day${streak == 1 ? '' : 's'}',
              style: const TextStyle(
                color: _kOrange,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              )),
        ]),
      ),
    );
  }
}

// ─── Activity Rings ────────────────────────────────────────────────────────────
class _ActivityRingsCard extends StatelessWidget {
  final FitnessProvider provider;
  const _ActivityRingsCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    // Raw unclamped ratios so the painter and rows can show overflow > 100%.
    final calRaw =
        p.calorieGoal > 0 ? p.todayCaloriesTotal / p.calorieGoal : 0.0;
    final protRaw =
        p.proteinGoal > 0 ? p.todayProteinTotal / p.proteinGoal : 0.0;
    final watRaw = p.waterGoalMl > 0 ? p.todayWaterMl / p.waterGoalMl : 0.0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShadows.card,
        border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
      ),
      child: Row(children: [
        SizedBox(
          width: 110,
          height: 110,
          child: Semantics(
            label:
                'Activity rings: calories ${(calRaw * 100).round()} percent, '
                'protein ${(protRaw * 100).round()} percent, '
                'water ${(watRaw * 100).round()} percent of goal',
            child: _AnimatedRings(values: [calRaw, protRaw, watRaw]),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
            child: Column(children: [
          _RingRow(
              color: _kRed,
              label: 'Calories',
              value: '${p.todayCaloriesTotal.round()} / ${p.calorieGoal} kcal',
              progress: calRaw),
          const SizedBox(height: 10),
          _RingRow(
              color: _kGreen,
              label: 'Protein',
              value: '${p.todayProteinTotal.round()} / ${p.proteinGoal}g',
              progress: protRaw),
          const SizedBox(height: 10),
          _RingRow(
              color: _kBlue,
              label: 'Water',
              value: '${p.todayWaterMl} / ${p.waterGoalMl} ml',
              progress: watRaw),
        ])),
      ]),
    );
  }
}

class _RingRow extends StatelessWidget {
  final Color color;
  final String label, value;
  final double progress; // unclamped — can be > 1.0
  const _RingRow(
      {required this.color,
      required this.label,
      required this.value,
      required this.progress});

  @override
  Widget build(BuildContext context) {
    final isOver = progress > 1.0;
    // When over goal, shift colour toward white so it visually pops.
    final displayColor =
        isOver ? Color.lerp(color, Colors.white, 0.45)! : color;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: displayColor, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
        const Spacer(),
        CountUpText(progress * 100,
            suffix: '%',
            style: TextStyle(
                color: displayColor,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: isOver ? 1.0 : progress),
          duration: reduceMotion(context) ? Duration.zero : AppDurations.ring,
          curve: AppCurves.emphasized,
          builder: (_, v, __) => LinearProgressIndicator(
            value: v,
            backgroundColor: color.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation<Color>(displayColor),
            minHeight: 5,
          ),
        ),
      ),
      const SizedBox(height: 2),
      Text(value,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6), fontSize: 11)),
    ]);
  }
}

/// Drives [_RingsPainter] so each ring both sweeps on from zero (entry) AND
/// animates the delta when a value changes mid-session — TweenAnimationBuilder
/// animates from the current value to the new `end`, so logging food now glides
/// the ring to its new fill instead of snapping.
class _AnimatedRings extends StatelessWidget {
  final List<double>
      values; // [calories, protein, water] raw ratios (unclamped)
  const _AnimatedRings({required this.values});

  @override
  Widget build(BuildContext context) {
    final dur = reduceMotion(context) ? Duration.zero : AppDurations.ring;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: values[0]),
      duration: dur,
      curve: AppCurves.emphasized,
      builder: (_, cal, __) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: values[1]),
        duration: dur,
        curve: AppCurves.emphasized,
        builder: (_, prot, __) => TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: values[2]),
          duration: dur,
          curve: AppCurves.emphasized,
          builder: (_, wat, __) => CustomPaint(
            painter: _RingsPainter(
              values: [cal, prot, wat],
              colors: const [_kRed, _kGreen, _kBlue],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  final List<double> values; // unclamped — can be > 1.0
  final List<Color> colors;
  const _RingsPainter({required this.values, required this.colors});

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.values[0] != values[0] ||
      old.values[1] != values[1] ||
      old.values[2] != values[2];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const stroke = 10.0;
    const gap = 14.0;
    const startAngle = -math.pi / 2;
    const fullSweep = 2 * math.pi;

    for (int i = 0; i < values.length; i++) {
      final r = size.width / 2 - stroke / 2 - i * gap;
      if (r <= 0) continue;
      final v = values[i];

      // Background track
      canvas.drawCircle(
          center,
          r,
          Paint()
            ..color = colors[i].withValues(alpha: 0.15)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);

      if (v <= 0) continue;

      if (v <= 1.0) {
        // Normal fill
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: r),
          startAngle,
          fullSweep * v,
          false,
          Paint()
            ..color = colors[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round,
        );
      } else {
        // Over goal: fill the full ring with a flat join so the overflow sits cleanly on top.
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: r),
          startAngle,
          fullSweep,
          false,
          Paint()
            ..color = colors[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.butt,
        );
        // Overflow lap: draw from the top again in a lighter shade — creates the
        // Apple Watch "lapping" effect showing exactly how much over goal you are.
        final overflowSweep = fullSweep * (v - 1.0).clamp(0.0, 1.0);
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: r),
          startAngle,
          overflowSweep,
          false,
          Paint()
            ..color = Color.lerp(colors[i], Colors.white, 0.45)!
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }
}

// ─── Calorie Ring Tile ─────────────────────────────────────────────────────────
/// The single energy-balance hero: eaten-vs-burned ring + an expandable
/// resting/walking/workout split. The old standalone "Burn Breakdown" card is
/// now this drill-down, so eaten/burned aren't shown twice on the Summary.
class _CalorieRingTile extends StatefulWidget {
  const _CalorieRingTile();
  @override
  State<_CalorieRingTile> createState() => _CalorieRingTileState();
}

class _CalorieRingTileState extends State<_CalorieRingTile> {
  bool _burnExpanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final eaten = p.todayCaloriesTotal;
    final burned = p.totalCaloriesBurned;
    final goal = p.calorieGoal.toDouble();
    final net = eaten - burned;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShadows.card,
        border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
      ),
      child: Column(
        children: [
          const Text('Calorie Balance',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          SizedBox(
            height: 180,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Soft ambient glow behind the hero ring.
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: AppShadows.glow(_kGreen),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: eaten),
                  duration:
                      reduceMotion(context) ? Duration.zero : AppDurations.ring,
                  curve: AppCurves.emphasized,
                  builder: (_, e, __) => TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: burned),
                    duration: reduceMotion(context)
                        ? Duration.zero
                        : AppDurations.ring,
                    curve: AppCurves.emphasized,
                    builder: (_, b, __) => CustomPaint(
                      size: const Size(180, 180),
                      painter:
                          _CalorieRingPainter(eaten: e, burned: b, goal: goal),
                    ),
                  ),
                ),
                Semantics(
                  // Announce status in words so it doesn't rely on colour alone.
                  label:
                      'Net ${net >= 0 ? '+' : ''}${net.round()} kilocalories, '
                      '${net >= 0 ? 'surplus' : 'deficit'}',
                  child: CountUpText(
                    net,
                    signed: true,
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: net > 200
                          ? _kRed
                          : net < -200
                              ? _kGreen
                              : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RingLegend(
                  color: _kOrange,
                  label: 'Eaten',
                  value: '${eaten.round()} kcal'),
              _RingLegend(
                  color: _kGreen,
                  label: 'Burned',
                  value: '${burned.round()} kcal'),
              _RingLegend(
                  color: _kBlue, label: 'Goal', value: '${goal.round()} kcal'),
            ],
          ),

          // ── Burn breakdown (expandable drill-down of the "Burned" total) ──
          const SizedBox(height: 14),
          const Divider(color: AppColors.border, thickness: 0.5, height: 1),
          InkWell(
            onTap: () => setState(() => _burnExpanded = !_burnExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                const Icon(Icons.local_fire_department_rounded,
                    size: 16, color: _kGreen),
                const SizedBox(width: 6),
                const Text('Burn breakdown',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                GestureDetector(
                  onTap: () => _showBurnInfo(context),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.info_outline_rounded,
                        color: _kSecond, size: 16),
                  ),
                ),
                const Spacer(),
                Text('${burned.round()} kcal',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _kGreen)),
                const SizedBox(width: 4),
                Icon(
                  _burnExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: _kSecond,
                  size: 20,
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: reduceMotion(context) ? Duration.zero : AppDurations.fast,
            curve: AppCurves.emphasized,
            alignment: Alignment.topCenter,
            child: _burnExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(children: [
                      Expanded(
                          child: _BurnChip(
                              icon: Icons.bedtime_rounded,
                              label: 'Resting',
                              value: p.restingCaloriesBurned.round(),
                              color: _kBlue)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _BurnChip(
                              icon: Icons.directions_walk_rounded,
                              label: 'Walking',
                              value: p.walkingCaloriesBurned.round(),
                              color: _kBlue)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _BurnChip(
                              icon: Icons.fitness_center_rounded,
                              label: 'Workout',
                              value: p.todayCaloriesBurned,
                              color: _kGreen)),
                    ]),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// The "how calories burned is calculated" explainer (moved here from the
  /// former Burn Breakdown card so the info is still reachable).
  void _showBurnInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        title: const Text('How calories burned is calculated'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.bedtime_rounded, size: 16, color: Color(0xFF40C8E0)),
              SizedBox(width: 6),
              Text('Resting (BMR)',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            SizedBox(height: 4),
            Text(
                'Your body burns calories just to stay alive — breathing, heart beating, organs working. This is called your Basal Metabolic Rate (BMR). It\'s prorated based on how many hours of the day have passed.',
                style: TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13, height: 1.5)),
            SizedBox(height: 14),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.directions_walk_rounded,
                  size: 16, color: Color(0xFF40C8E0)),
              SizedBox(width: 6),
              Text('Walking',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            SizedBox(height: 4),
            Text(
                'Calculated from your step count using a formula that scales with your body weight. Heavier = more calories per step.',
                style: TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13, height: 1.5)),
            SizedBox(height: 14),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.fitness_center_rounded,
                  size: 16, color: Color(0xFF30D158)),
              SizedBox(width: 6),
              Text('Workout',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            SizedBox(height: 4),
            Text(
                'Calculated from each exercise\'s MET value × your weight × duration. Log your exercises in the Workout tab to see this update.',
                style: TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13, height: 1.5)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it',
                style: TextStyle(color: Color(0xFF30D158))),
          ),
        ],
      ),
    );
  }
}

class _RingLegend extends StatelessWidget {
  final Color color;
  final String label, value;
  const _RingLegend(
      {required this.color, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
      ]),
      const SizedBox(height: 2),
      Text(value,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    ]);
  }
}

class _CalorieRingPainter extends CustomPainter {
  final double eaten, burned, goal;
  const _CalorieRingPainter(
      {required this.eaten, required this.burned, required this.goal});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2 - 8;
    final innerRadius = outerRadius - 22;

    final bgPaint = Paint()
      ..color = const Color(0xFF2C2C2E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round;

    final eatenPaint = Paint()
      ..color = _kOrange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round;

    final burnedPaint = Paint()
      ..color = _kGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;

    const startAngle = -90 * (3.14159 / 180);
    const fullCircle = 2 * 3.14159;

    canvas.drawArc(Rect.fromCircle(center: center, radius: outerRadius),
        startAngle, fullCircle, false, bgPaint);
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: innerRadius),
        startAngle,
        fullCircle,
        false,
        bgPaint..color = const Color(0xFF2C2C2E));

    // Eaten ring — shows overflow lap when calories exceed goal.
    final eatenRatio = goal > 0 ? eaten / goal : 0.0;
    if (eatenRatio > 0) {
      if (eatenRatio <= 1.0) {
        canvas.drawArc(Rect.fromCircle(center: center, radius: outerRadius),
            startAngle, fullCircle * eatenRatio, false, eatenPaint);
      } else {
        // Full ring with flat join, then overflow lap in lighter orange.
        canvas.drawArc(
            Rect.fromCircle(center: center, radius: outerRadius),
            startAngle,
            fullCircle,
            false,
            eatenPaint..strokeCap = StrokeCap.butt);
        final overflowSweep = fullCircle * (eatenRatio - 1.0).clamp(0.0, 1.0);
        canvas.drawArc(
            Rect.fromCircle(center: center, radius: outerRadius),
            startAngle,
            overflowSweep,
            false,
            Paint()
              ..color = _kOrange.withValues(alpha: 0.6)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 22
              ..strokeCap = StrokeCap.round);
      }
    }

    // Both rings share the same scale (goal) so eaten vs burned is directly
    // comparable at a glance — the gap between the two arcs IS the net balance.
    final burnedSweep = (burned / goal * fullCircle).clamp(0.0, fullCircle);
    if (burnedSweep > 0) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: innerRadius),
          startAngle, burnedSweep, false, burnedPaint);
    }
  }

  @override
  bool shouldRepaint(_CalorieRingPainter old) =>
      old.eaten != eaten || old.burned != burned || old.goal != goal;
}

// ─── Burn chip ─────────────────────────────────────────────────────────────────
class _BurnChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  const _BurnChip(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 4),
        Text('$value kcal',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(fontSize: 11, color: _kSecond)),
      ]),
    );
  }
}

// ─── Steps + Water Row ────────────────────────────────────────────────────────
class _StepsWaterRow extends StatelessWidget {
  const _StepsWaterRow();
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    return Row(children: [
      Expanded(
          child: _MiniRingCard(
        icon: Icons.directions_walk_rounded,
        label: 'Steps',
        current: p.todaySteps.toDouble(),
        goal: p.stepGoal.toDouble(),
        valueText: _fmtInt(p.todaySteps),
        goalText: '/ ${_fmtInt(p.stepGoal)}',
        color: _kBlue,
      )),
      const SizedBox(width: 10),
      Expanded(
          child: _MiniRingCard(
        icon: Icons.water_drop_rounded,
        label: 'Water',
        current: p.todayWaterMl.toDouble(),
        goal: p.waterGoalMl.toDouble(),
        valueText: '${p.todayWaterMl} ml',
        goalText: '/ ${p.waterGoalMl} ml',
        color: const Color(0xFF0A84FF),
      )),
    ]);
  }
}

class _MiniRingCard extends StatelessWidget {
  final IconData icon;
  final String label, valueText, goalText;
  final double current, goal;
  final Color color;
  const _MiniRingCard(
      {required this.icon,
      required this.label,
      required this.current,
      required this.goal,
      required this.valueText,
      required this.goalText,
      required this.color});

  @override
  Widget build(BuildContext context) {
    final progress = (current / goal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border:
              const Border(top: BorderSide(color: AppColors.rim, width: 1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
        const SizedBox(height: 10),
        Text(valueText,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800, color: color)),
        Text(goalText, style: const TextStyle(color: _kSecond, fontSize: 11)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: const Color(0xFF2C2C2E),
            valueColor: AlwaysStoppedAnimation(color),
            minHeight: 6,
          ),
        ),
      ]),
    );
  }
}

// ─── Body Stats Tile ───────────────────────────────────────────────────────────
class _BodyStatsTile extends StatelessWidget {
  const _BodyStatsTile();
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final scale = p.latestScaleEntry;
    final bmi = p.bmi;
    if (scale == null && bmi == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border:
              const Border(top: BorderSide(color: AppColors.rim, width: 1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Body Stats',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (scale != null)
            Text(
              '${scale.date.day}/${scale.date.month}',
              style: const TextStyle(color: _kSecond, fontSize: 12),
            ),
        ]),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (p.latestWeightKg != null)
              _StatChip(Icons.monitor_weight_rounded, 'Weight',
                  '${p.latestWeightKg!.toStringAsFixed(1)} kg', Colors.white),
            if (bmi != null)
              _StatChip(Icons.straighten_rounded, 'BMI', bmi.toStringAsFixed(1),
                  p.bmiColor(context)),
            if (scale != null) ...[
              _StatChip(Icons.local_fire_department_rounded, 'Body Fat',
                  '${scale.bodyFatPercent.toStringAsFixed(1)}%', _kOrange),
              _StatChip(Icons.fitness_center_rounded, 'Muscle',
                  '${scale.muscleMassKg.toStringAsFixed(1)} kg', _kGreen),
              _StatChip(Icons.water_drop_rounded, 'Water',
                  '${scale.bodyWaterPercent.toStringAsFixed(1)}%', _kBlue),
              _StatChip(Icons.science_rounded, 'Bio Age',
                  '${scale.biologicalAge} yr', _kBlue),
            ],
          ],
        ),
      ]),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final Color color;
  const _StatChip(this.icon, this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: _kSecond),
        const SizedBox(width: 5),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }
}

// ─── Weight Prediction Card ────────────────────────────────────────────────────
class _WeightPredictionCard extends StatelessWidget {
  final FitnessProvider provider;
  const _WeightPredictionCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    // Compute once — used both for the subtitle count and the painter (was 2 sorts).
    final recent90 = p.getRecentBodyEntries(days: 90);
    final cutoff30 = DateTime.now().subtract(const Duration(days: 30));
    final recent30 = recent90.where((e) => !e.date.isBefore(cutoff30)).toList();
    final forecast = p.weightForecast(days: 30);
    final current = p.latestWeightKg ?? 0.0;
    final weekly = p.weeklyWeightChange;
    final goalDate = p.estimatedGoalDate;
    final predicted30 = forecast.isNotEmpty ? forecast.last.$2 : null;

    final isLosing = weekly != null && weekly < 0;
    final trendColor = isLosing ? _kGreen : _kRed;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShadows.card,
        border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🤖', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('AI Weight Forecast',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                )),
            Text('Linear trend from your last ${recent90.length} logs',
                style: const TextStyle(color: _kSecond, fontSize: 11)),
          ]),
          const Spacer(),
          if (weekly != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: trendColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: trendColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                '${weekly >= 0 ? '+' : ''}${weekly.toStringAsFixed(2)} kg/wk',
                style: TextStyle(
                    color: trendColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 120,
          child: CustomPaint(
            painter: _PredictionPainter(
              history: recent30,
              forecast: forecast,
              goalWeight: p.goalWeightKg,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _PredStat('Now', '${current.toStringAsFixed(1)} kg', Colors.white),
          _PredStat(
              'In 30 days',
              predicted30 != null
                  ? '${predicted30.toStringAsFixed(1)} kg'
                  : '—',
              trendColor),
          _PredStat(
              'Goal', '${p.goalWeightKg.toStringAsFixed(1)} kg', _kOrange),
          _PredStat(
              'ETA',
              goalDate != null ? DateFormat('d MMM').format(goalDate) : '—',
              _kBlue),
        ]),
        if (goalDate != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _kGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              const Icon(Icons.flag_rounded, size: 15, color: _kGreen),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                'At this rate you\'ll reach ${p.goalWeightKg.toStringAsFixed(1)} kg by ${DateFormat('d MMMM yyyy').format(goalDate)}',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12, height: 1.4),
              )),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _PredStat extends StatelessWidget {
  final String l, v;
  final Color c;
  const _PredStat(this.l, this.v, this.c);
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(v,
            style:
                TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.bold)),
        Text(l, style: const TextStyle(color: _kSecond, fontSize: 11)),
      ]);
}

class _PredictionPainter extends CustomPainter {
  final List<BodyEntry> history;
  final List<(DateTime, double)> forecast;
  final double goalWeight;

  const _PredictionPainter({
    required this.history,
    required this.forecast,
    required this.goalWeight,
  });

  @override
  bool shouldRepaint(_PredictionPainter old) =>
      old.history != history ||
      old.forecast != forecast ||
      old.goalWeight != goalWeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty && forecast.isEmpty) return;

    final allWeights = [
      ...history.map((e) => e.weightKg),
      ...forecast.map((f) => f.$2),
      goalWeight,
    ];
    final minW = allWeights.reduce(math.min) - 1.0;
    final maxW = allWeights.reduce(math.max) + 1.0;
    final range = (maxW - minW).clamp(0.5, double.infinity);

    final allDates = [
      if (history.isNotEmpty) history.first.date,
      if (forecast.isNotEmpty) forecast.last.$1,
    ];
    if (allDates.length < 2) return;
    final minT = allDates.first.millisecondsSinceEpoch.toDouble();
    final maxT = allDates.last.millisecondsSinceEpoch.toDouble();
    final timeRange = (maxT - minT).clamp(1.0, double.infinity);

    Offset toOff(DateTime d, double w) {
      final x = ((d.millisecondsSinceEpoch - minT) / timeRange) * size.width;
      final y = size.height - ((w - minW) / range) * size.height;
      return Offset(x.clamp(0, size.width), y.clamp(0, size.height));
    }

    if (goalWeight >= minW && goalWeight <= maxW) {
      final goalY = size.height - ((goalWeight - minW) / range) * size.height;
      final dashPaint = Paint()
        ..color = _kOrange.withValues(alpha: 0.5)
        ..strokeWidth = 1.5;
      for (double x = 0; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, goalY),
            Offset((x + 6).clamp(0, size.width), goalY), dashPaint);
      }
    }

    if (history.length >= 2) {
      final histPath = Path();
      final histPts = history.map((e) => toOff(e.date, e.weightKg)).toList();
      histPath.moveTo(histPts.first.dx, histPts.first.dy);
      for (final pt in histPts.skip(1)) histPath.lineTo(pt.dx, pt.dy);
      canvas.drawPath(
          histPath,
          Paint()
            ..color = _kGreen
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round);
      for (final pt in histPts) {
        canvas.drawCircle(pt, 3, Paint()..color = _kGreen);
      }
    }

    if (forecast.isNotEmpty && history.isNotEmpty) {
      final startPt = toOff(history.last.date, history.last.weightKg);
      final forecastPts = [startPt, ...forecast.map((f) => toOff(f.$1, f.$2))];
      final dashPaint = Paint()
        ..color = _kBlue
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (int i = 0; i < forecastPts.length - 1; i++) {
        if (i % 3 == 0)
          canvas.drawLine(forecastPts[i], forecastPts[i + 1], dashPaint);
      }
      final shadePath = Path()
        ..moveTo(startPt.dx, size.height)
        ..lineTo(startPt.dx, startPt.dy);
      for (final pt in forecastPts.skip(1)) shadePath.lineTo(pt.dx, pt.dy);
      shadePath.lineTo(forecastPts.last.dx, size.height);
      shadePath.close();
      canvas.drawPath(
          shadePath,
          Paint()
            ..color = _kBlue.withValues(alpha: 0.07)
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          forecastPts.last,
          4,
          Paint()
            ..color = _kBlue
            ..style = PaintingStyle.fill);
    }
  }
}

// ─── Workout Card ──────────────────────────────────────────────────────────────
class _WorkoutCard extends StatelessWidget {
  final List<WorkoutLog> workouts;
  const _WorkoutCard({required this.workouts});

  @override
  Widget build(BuildContext context) {
    if (workouts.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadows.card,
            border:
                const Border(top: BorderSide(color: AppColors.rim, width: 1))),
        child: Row(children: [
          Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: _kGreen.withValues(alpha: 0.1),
                  shape: BoxShape.circle),
              child: const Icon(Icons.fitness_center_rounded,
                  color: _kGreen, size: 20)),
          const SizedBox(width: 14),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No workout logged yet',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            Text('Tap Workout tab to start',
                style: TextStyle(color: _kSecond, fontSize: 12)),
          ]),
        ]),
      );
    }
    final totalExercises = workouts.fold(0, (s, w) => s + w.exercises.length);
    final displayName = workouts.length == 1
        ? workouts.first.name
        : '${workouts.length} sessions done';
    final sessionLabel = workouts.length == 1
        ? '$totalExercises exercises logged today'
        : '$totalExercises exercises across ${workouts.length} sessions';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kGreen.withValues(alpha: 0.3))),
      child: Row(children: [
        const Icon(Icons.check_circle_rounded, color: _kGreen, size: 26),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(displayName,
              style: const TextStyle(
                  color: _kGreen, fontWeight: FontWeight.bold, fontSize: 14)),
          Text(sessionLabel,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
        ])),
      ]),
    );
  }
}

// ─── Supplements Card ──────────────────────────────────────────────────────────
class _SupplementsCard extends StatelessWidget {
  final SupplementStatus supp;
  const _SupplementsCard({required this.supp});

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Whey', supp.whey, '🥛'),
      ('Creatine', supp.creatine, '⚡'),
      ('Multivitamin', supp.multivitamin, '💊')
    ];
    final done = items.where((e) => e.$2).length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border:
              const Border(top: BorderSide(color: AppColors.rim, width: 1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('$done/${items.length} taken',
              style: const TextStyle(color: _kSecond, fontSize: 12)),
          const Spacer(),
          if (done == items.length)
            const Text('✅ All done!',
                style: TextStyle(
                    color: _kGreen, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 10),
        Row(
            children: items
                .map((item) => Expanded(
                        child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: item.$2
                              ? _kGreen.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: item.$2
                                  ? _kGreen.withValues(alpha: 0.4)
                                  : Colors.transparent),
                        ),
                        child: Column(children: [
                          Text(item.$3, style: const TextStyle(fontSize: 20)),
                          const SizedBox(height: 4),
                          Text(item.$1,
                              style: TextStyle(
                                  color: item.$2 ? _kGreen : _kSecond,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500)),
                        ]),
                      ),
                    )))
                .toList()),
      ]),
    );
  }
}

// ─── Weekly Report Card ────────────────────────────────────────────────────────
class _WeeklyReportCard extends StatelessWidget {
  final FitnessProvider provider;
  const _WeeklyReportCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    // Rolling last 7 days (oldest → today) so the grid matches the "X/7" stat
    // and the "LAST 7 DAYS" section title.
    final rolling = p.rolling7DayWorkouts;
    final weekly = p.weeklyWeightChange;
    final avgCal = p.weeklyAvgCalories;
    final avgCalColor = avgCal <= p.calorieGoal ? _kGreen : _kRed;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShadows.card,
        border: const Border(top: BorderSide(color: AppColors.rim, width: 1)),
      ),
      child: Column(children: [
        // ── 7-day workout grid (rolling, today = last) ──────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (i) {
            final done = rolling[i].done;
            final isToday = i == 6; // last cell is today
            return Column(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: done
                      ? _kGreen.withValues(alpha: 0.2)
                      : isToday
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.white.withValues(alpha: 0.04),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: done
                          ? _kGreen
                          : isToday
                              ? Colors.white38
                              : Colors.transparent,
                      width: 1.5),
                ),
                child: done
                    ? const Icon(Icons.check_rounded, color: _kGreen, size: 16)
                    : null,
              ),
              const SizedBox(height: 4),
              Text(rolling[i].label,
                  style: TextStyle(
                    color: done
                        ? _kGreen
                        : isToday
                            ? Colors.white
                            : _kSecond,
                    fontSize: 11,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  )),
            ]);
          }),
        ),
        const SizedBox(height: 12),
        const Divider(color: Color(0xFF38383A), thickness: 0.5, height: 1),
        const SizedBox(height: 12),

        // ── Row 1: workouts / burned / streaks ──────────────────────────
        Row(children: [
          _WeekStat('Workouts', '${p.weeklyWorkoutDays}/7', _kGreen,
              Icons.fitness_center_rounded),
          const SizedBox(width: 8),
          _WeekStat('Kcal Burned', '${p.weeklyCaloriesBurned}', _kRed,
              Icons.local_fire_department_rounded),
          const SizedBox(width: 8),
          _WeekStat('Workout', '${p.workoutStreak}d', _kOrange,
              Icons.local_fire_department_rounded),
          const SizedBox(width: 8),
          _WeekStat('Diet', '${p.calorieStreak}d', const Color(0xFF40C8E0),
              Icons.restaurant_rounded),
        ]),
        const SizedBox(height: 8),

        // ── Row 2: nutrition averages ───────────────────────────────────
        Row(children: [
          _WeekStat('Avg Cal', '${avgCal.round()}', avgCalColor, null),
          const SizedBox(width: 8),
          _WeekStat(
              'Avg Protein', '${p.weeklyAvgProtein.round()}g', _kBlue, null),
          const SizedBox(width: 8),
          _WeekStat('Water Goal', '${p.weeklyWaterGoalHitDays}/7d',
              p.weeklyWaterGoalHitDays >= 4 ? _kGreen : _kSecond, null),
          const SizedBox(width: 8),
          _WeekStat('Prot Goal', '${p.weeklyProteinGoalHitDays}/7d',
              p.weeklyProteinGoalHitDays >= 4 ? _kGreen : _kSecond, null),
        ]),

        // ── Weight change line ──────────────────────────────────────────
        if (weekly != null) ...[
          const SizedBox(height: 10),
          const Divider(color: Color(0xFF38383A), thickness: 0.5, height: 1),
          const SizedBox(height: 8),
          Row(children: [
            Icon(
              weekly < 0
                  ? Icons.trending_down_rounded
                  : weekly > 0
                      ? Icons.trending_up_rounded
                      : Icons.trending_flat_rounded,
              color: weekly < 0
                  ? _kGreen
                  : weekly > 0
                      ? _kRed
                      : _kSecond,
              size: 16,
            ),
            const SizedBox(width: 6),
            Text(
              weekly < 0
                  ? '${weekly.abs().toStringAsFixed(2)} kg lost this week'
                  : weekly > 0
                      ? '${weekly.toStringAsFixed(2)} kg gained this week'
                      : 'Weight stable this week',
              style: TextStyle(
                color: weekly < 0
                    ? _kGreen
                    : weekly > 0
                        ? _kRed
                        : _kSecond,
                fontSize: 12,
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _WeekStat extends StatelessWidget {
  final String label, value;
  final Color color;
  final IconData? icon;
  const _WeekStat(this.label, this.value, this.color, this.icon);

  @override
  Widget build(BuildContext context) => Expanded(
          child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 14),
            const SizedBox(height: 4)
          ],
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: _kSecond, fontSize: 11)),
        ]),
      ));
}

// ─── Weekly Calorie Bar Chart ──────────────────────────────────────────────────
class _WeeklyCalorieChart extends StatelessWidget {
  final FitnessProvider provider;
  const _WeeklyCalorieChart({required this.provider});

  @override
  Widget build(BuildContext context) {
    final data = provider.weeklyCalorieData;
    final goal = provider.calorieGoal.toDouble();
    final maxCal =
        data.fold(goal, (m, d) => math.max(m, (d['calories'] as double)));
    final yMax = (maxCal * 1.15).ceilToDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
      ),
      height: 190,
      child: ChartEntrance(
        builder: (context, t) => BarChart(
          swapAnimationDuration: Duration.zero,
          BarChartData(
            maxY: yMax,
            alignment: BarChartAlignment.spaceAround,
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => const Color(0xFF2C2C2E),
                getTooltipItem: (group, _, rod, __) {
                  final cal = rod.toY.round();
                  return BarTooltipItem(
                    '$cal kcal',
                    const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  );
                },
              ),
            ),
            titlesData: FlTitlesData(
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 26,
                  getTitlesWidget: (v, _) {
                    final idx = v.toInt();
                    if (idx < 0 || idx >= data.length)
                      return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        data[idx]['label'] as String,
                        style: TextStyle(
                          color: idx == data.length - 1 ? _kGreen : _kSecond,
                          fontSize: 11,
                          fontWeight: idx == data.length - 1
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    );
                  },
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 30,
                  interval: goal,
                  getTitlesWidget: (v, _) {
                    if (v <= 0 || v > yMax) return const SizedBox.shrink();
                    final k = v / 1000;
                    return Text(
                      '${k.toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k',
                      style: const TextStyle(color: _kSecond, fontSize: 11),
                    );
                  },
                ),
              ),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: goal,
              getDrawingHorizontalLine: (v) {
                final isGoal = (v - goal).abs() < 1;
                return FlLine(
                  color: isGoal
                      ? _kOrange.withValues(alpha: 0.6)
                      : const Color(0xFF38383A),
                  strokeWidth: isGoal ? 1.5 : 0.5,
                  dashArray: isGoal ? [6, 4] : null,
                );
              },
            ),
            borderData: FlBorderData(show: false),
            barGroups: data.asMap().entries.map((entry) {
              final idx = entry.key;
              final cal = (entry.value['calories'] as double);
              final isToday = idx == data.length - 1;
              final atGoal = cal >= goal;
              Color barColor;
              if (isToday) {
                barColor = atGoal ? _kGreen : _kBlue;
              } else {
                barColor = atGoal
                    ? _kGreen.withValues(alpha: 0.55)
                    : _kBlue.withValues(alpha: 0.35);
              }
              return BarChartGroupData(
                x: idx,
                barRods: [
                  BarChartRodData(
                    toY: cal * t,
                    color: barColor,
                    width: 22,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                  ),
                ],
              );
            }).toList(),
            extraLinesData: ExtraLinesData(horizontalLines: [
              HorizontalLine(
                y: goal,
                color: _kOrange.withValues(alpha: 0.7),
                strokeWidth: 1.5,
                dashArray: [6, 4],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  labelResolver: (_) => '  goal',
                  style: TextStyle(
                    color: _kOrange.withValues(alpha: 0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Macro Donut Card ─────────────────────────────────────────────────────────
class _MacroDonutCard extends StatelessWidget {
  final FitnessProvider provider;
  const _MacroDonutCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final protein = provider.todayProteinTotal;
    final carbs = provider.todayCarbsEstimate;
    final fat = provider.todayFatEstimate;
    final total = protein + carbs + fat; // grams — used by the legend rows
    // Only flag carbs/fat as "estimated" when at least one logged item actually
    // lacked real macros (custom entry or a DB item with none). A day of foods
    // that all carry real carbs/fat shows no estimate footnote.
    final estimated = provider.todayMacrosEstimated;

    // Size donut slices by CALORIE contribution (4/4/9 kcal per g), not grams, so
    // each slice reflects its true share of energy (fat is 9 kcal/g vs 4 for the rest).
    final proteinCal = protein * 4.0;
    final carbsCal = carbs * 4.0;
    final fatCal = fat * 9.0;

    if (total < 1) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadows.card,
            border:
                const Border(top: BorderSide(color: AppColors.rim, width: 1))),
        child: const Center(
          child: Text('Log food to see macro breakdown',
              style: TextStyle(color: _kSecond, fontSize: 13)),
        ),
      );
    }

    final sections = [
      PieChartSectionData(
        value: proteinCal,
        color: _kBlue,
        radius: 30,
        showTitle: false,
      ),
      PieChartSectionData(
        value: carbsCal,
        color: _kOrange,
        radius: 30,
        showTitle: false,
      ),
      PieChartSectionData(
        value: fatCal,
        color: _kRed.withValues(alpha: 0.85),
        radius: 30,
        showTitle: false,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border:
              const Border(top: BorderSide(color: AppColors.rim, width: 1))),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            height: 110,
            child: Semantics(
              label: 'Macros${estimated ? ' (estimated)' : ''}: '
                  'protein ${protein.round()} grams, '
                  'carbs ${carbs.round()} grams, '
                  'fat ${fat.round()} grams. '
                  '${provider.todayCaloriesTotal.round()} kilocalories total.',
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Soft glow behind the macro donut.
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: AppShadows.glow(_kBlue),
                    ),
                  ),
                  PieChart(
                    PieChartData(
                      sections: sections,
                      sectionsSpace: 2,
                      centerSpaceRadius: 32,
                      startDegreeOffset: -90,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${provider.todayCaloriesTotal.round()}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16)),
                      const Text('kcal',
                          style: TextStyle(color: _kSecond, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MacroLegendRow(
                  color: _kBlue,
                  label: 'Protein',
                  grams: protein.round(),
                  total: total,
                  goal: provider.proteinGoal,
                ),
                const SizedBox(height: 10),
                _MacroLegendRow(
                  color: _kOrange,
                  label: 'Carbs',
                  grams: carbs.round(),
                  total: total,
                  goal: provider.carbGoal,
                  estimated: estimated,
                ),
                const SizedBox(height: 10),
                _MacroLegendRow(
                  color: _kRed.withValues(alpha: 0.85),
                  label: 'Fat',
                  grams: fat.round(),
                  total: total,
                  goal: provider.fatGoal,
                  estimated: estimated,
                ),
                if (estimated) ...[
                  const SizedBox(height: 8),
                  const Text('* carbs & fat are estimated',
                      style: TextStyle(color: _kSecond, fontSize: 11)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MacroLegendRow extends StatelessWidget {
  final Color color;
  final String label;
  final int grams;
  final double total;
  final int? goal;
  final bool estimated;
  const _MacroLegendRow({
    required this.color,
    required this.label,
    required this.grams,
    required this.total,
    this.goal,
    this.estimated = false,
  });

  @override
  Widget build(BuildContext context) {
    final progress =
        (goal != null && goal! > 0) ? (grams / goal!).clamp(0.0, 1.0) : null;
    return Row(
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(estimated ? '$label*' : label,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              if (progress != null) ...[
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(goal != null ? '$grams / ${goal}g' : '${grams}g',
            style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 13)),
      ],
    );
  }
}

// ─── Backup reminder card ──────────────────────────────────────────────────────
// Gentle nudge shown when data has never been backed up or it's >14 days stale.
// Taps through to Settings → Data & Backup (export lives there).
// ── Daily AI brief (once-a-day cloud summary) ─────────────────────────────────
class _DailyBriefCard extends StatelessWidget {
  final String text;
  const _DailyBriefCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => openChat(context),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      radius: 14,
      gradient: LinearGradient(
        colors: [
          _kBlue.withValues(alpha: 0.12),
          _kGreen.withValues(alpha: 0.06),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: _kBlue.withValues(alpha: 0.3)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('✨', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('TODAY\'S AI BRIEF',
                style: TextStyle(
                    color: _kSecond,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
          ),
          // Regenerate on demand — handy when today's data has moved on since
          // the brief was written this morning. Absorbs the tap so it doesn't
          // also open chat (the card's own onTap).
          InkWell(
            onTap: () {
              Haptics.tap();
              context.read<FitnessProvider>().forceRefreshDailyBrief();
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(
                    content: Text('Refreshing your brief…'),
                    duration: Duration(seconds: 2)));
            },
            borderRadius: BorderRadius.circular(20),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child:
                  Icon(Icons.refresh_rounded, size: 16, color: _kSecond),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text(text,
            style: const TextStyle(
                color: Colors.white, fontSize: 13.5, height: 1.4)),
      ]),
    );
  }
}

class _BackupReminderCard extends StatelessWidget {
  const _BackupReminderCard();

  @override
  Widget build(BuildContext context) {
    final days = context.watch<FitnessProvider>().daysSinceBackup;
    return GestureDetector(
      onTap: () =>
          Navigator.push(context, sharedAxisRoute(const SettingsScreen())),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFF9F0A).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border: Border.all(
              color: const Color(0xFFFF9F0A).withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.backup_outlined, color: Color(0xFFFF9F0A), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Back up your data',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  days == null
                      ? "It's only on this device — export it so an uninstall can't wipe it."
                      : 'Last backup $days days ago. Tap to export a fresh copy.',
                  style: const TextStyle(color: _kSecond, fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: _kSecond, size: 20),
        ]),
      ),
    );
  }
}

// ─── Getting-started card ──────────────────────────────────────────────────────
// Shown on day 1 until the user logs weight, food, or a workout.
class _GettingStartedCard extends StatelessWidget {
  const _GettingStartedCard();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (
        Icons.monitor_weight_rounded,
        'Log your weight',
        'Body tab → Stats → Log Today'
      ),
      (
        Icons.restaurant_rounded,
        'Log your first meal',
        'Nutrition tab → + Add Food'
      ),
      (
        Icons.fitness_center_rounded,
        'Log a workout',
        'Workout tab → pick an exercise'
      ),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kGreen.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.rocket_launch_rounded, size: 18, color: _kGreen),
          SizedBox(width: 8),
          Text('Get started',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        const Text('3 steps to unlock your personalised insights',
            style: TextStyle(color: _kSecond, fontSize: 12)),
        const SizedBox(height: 14),
        ...steps.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Icon(s.$1, size: 20, color: _kGreen),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(s.$2,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      Text(s.$3,
                          style:
                              const TextStyle(color: _kSecond, fontSize: 11)),
                    ])),
                const Icon(Icons.arrow_forward_ios_rounded,
                    color: _kSecond, size: 13),
              ]),
            )),
      ]),
    );
  }
}
