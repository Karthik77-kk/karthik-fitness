import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../services/haptics.dart';

class SupplementsScreen extends StatelessWidget {
  final bool embedded;
  const SupplementsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();

    final body = ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      children: [
        // ── Progress summary ──────────────────────────────────────────────
        _ProgressHeader(
            taken: p.supplements.takenCount, streak: p.supplementStreak),
        const SizedBox(height: 20),

        // ── Supplement cards ──────────────────────────────────────────────
        _SupplementCard(
          icon: Icons.fitness_center_rounded,
          name: 'Whey Protein',
          brand: 'Nutrabay Gold 100% Whey',
          amount: '1 scoop (25g protein)',
          timing: 'Post-workout · or anytime',
          tip:
              'Mix with 200ml water or milk. 2 scoops only if dietary protein is low.',
          color: const Color(0xFF30D158),
          taken: p.supplements.whey,
          nutritionSubtitle: p.supplements.whey
              ? '120 kcal · 25g protein counted ✓'
              : '120 kcal · 25g protein',
          nutritionColor: p.supplements.whey
              ? const Color(0xFF30D158)
              : const Color(0xFF8E8E93),
          onToggle: (val) {
            Haptics.selection();
            p.updateSupplement('whey', val);
          },
        ),
        const SizedBox(height: 12),

        _SupplementCard(
          icon: Icons.bolt_rounded,
          name: 'Creatine Monohydrate',
          brand: 'Nutrabay Pure Micronised',
          amount: '3–5g daily',
          timing: 'Any time · Every day (incl. rest days)',
          tip:
              'No loading phase needed. Can mix with whey or plain water. Take it consistently.',
          color: const Color(0xFF40C8E0),
          taken: p.supplements.creatine,
          nutritionSubtitle: '3–5g · 0 kcal · performance',
          nutritionColor: const Color(0xFF8E8E93),
          onToggle: (val) {
            Haptics.selection();
            p.updateSupplement('creatine', val);
          },
        ),
        const SizedBox(height: 12),

        _SupplementCard(
          icon: Icons.eco_rounded,
          name: 'Multivitamin',
          brand: 'MuscleBlaze MB-Vite',
          amount: '1 tablet daily',
          timing: 'After breakfast — always with food',
          tip:
              'Covers micronutrient gaps. Not a substitute for a good diet, but great as backup.',
          color: const Color(0xFF40C8E0),
          taken: p.supplements.multivitamin,
          nutritionSubtitle: 'Micronutrients · 0 kcal',
          nutritionColor: const Color(0xFF8E8E93),
          onToggle: (val) {
            Haptics.selection();
            p.updateSupplement('multivitamin', val);
          },
        ),
        const SizedBox(height: 24),

        // ── Reminder tip ──────────────────────────────────────────────────
        _ReminderTip(),
        const SizedBox(height: 16),

        // ── Avoid section ─────────────────────────────────────────────────
        _AvoidSection(),
      ],
    );

    if (embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Supplements 💊'),
      ),
      body: body,
    );
  }
}

// ── Progress header ────────────────────────────────────────────────────────────

class _ProgressHeader extends StatelessWidget {
  final int taken;
  final int streak; // consecutive days all 3 taken
  const _ProgressHeader({required this.taken, this.streak = 0});

  @override
  Widget build(BuildContext context) {
    final messages = [
      'Nothing taken yet today',
      '1 of 3 supplements done',
      '2 of 3 done — almost there!',
      '🎉 All 3 supplements taken today!',
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: taken == 3
              ? [
                  const Color(0xFF30D158).withValues(alpha: 0.25),
                  const Color(0xFF30D158).withValues(alpha: 0.10)
                ]
              : [
                  const Color(0xFF40C8E0).withValues(alpha: 0.2),
                  const Color(0xFF40C8E0).withValues(alpha: 0.08)
                ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: taken == 3
              ? const Color(0xFF30D158).withValues(alpha: 0.4)
              : const Color(0xFF40C8E0).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: taken / 3,
                  strokeWidth: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    taken == 3
                        ? const Color(0xFF30D158)
                        : const Color(0xFF40C8E0),
                  ),
                ),
                Text(
                  '$taken/3',
                  style: TextStyle(
                    color: taken == 3 ? const Color(0xFF30D158) : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  messages[taken],
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  streak >= 7
                      ? '🔥 $streak-day supplement streak! Keep it going.'
                      : streak >= 2
                          ? 'On a $streak-day streak — consistency builds results!'
                          : 'Consistency is key — take these daily for best results.',
                  style:
                      const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Supplement card ────────────────────────────────────────────────────────────

class _SupplementCard extends StatelessWidget {
  final IconData icon;
  final String name, brand, amount, timing, tip;
  final Color color;
  final bool taken;
  final String nutritionSubtitle;
  final Color nutritionColor;
  final ValueChanged<bool> onToggle;

  const _SupplementCard({
    required this.icon,
    required this.name,
    required this.brand,
    required this.amount,
    required this.timing,
    required this.tip,
    required this.color,
    required this.taken,
    required this.nutritionSubtitle,
    required this.nutritionColor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: taken ? color.withValues(alpha: 0.12) : const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: taken
              ? color.withValues(alpha: 0.5)
              : color.withValues(alpha: 0.2),
          width: taken ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 26, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: taken ? color : Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      brand,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      nutritionSubtitle,
                      style: TextStyle(color: nutritionColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 1.2,
                child: Checkbox(
                  value: taken,
                  onChanged: (v) => onToggle(v ?? false),
                  activeColor: color,
                  checkColor: Colors.white,
                  side: BorderSide(
                      color: color.withValues(alpha: 0.5), width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoRow(icon: Icons.scale_outlined, label: amount, color: color),
          const SizedBox(height: 4),
          _InfoRow(icon: Icons.access_time, label: timing, color: color),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.tips_and_updates_outlined,
                    size: 13, color: Color(0xFFFF9F0A)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tip,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                        height: 1.4),
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

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _InfoRow(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color.withValues(alpha: 0.7)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
      ],
    );
  }
}

// ── Reminder tip ───────────────────────────────────────────────────────────────

class _ReminderTip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tips_and_updates_outlined,
              color: Colors.white54, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Build the daily habit',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
                Text(
                  'Tick these off after breakfast each day — your streak and the in-app '
                  'coach keep you consistent. (The app sends no phone notifications.)',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                      height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Avoid section ──────────────────────────────────────────────────────────────

class _AvoidSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const avoid = [
      'Fat burners — waste of money, side effects',
      'Mass gainers — adds unwanted fat',
      'BCAAs — not needed if you have whey',
      'Testosterone boosters — not for your age/goal',
      'Fancy creatine types (HCl, Kre-Alkalyn) — pure monohydrate is best',
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(Icons.block_rounded, size: 13, color: Colors.redAccent),
            SizedBox(width: 6),
            Text(
              'Supplements to avoid',
              style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ]),
          const SizedBox(height: 8),
          ...avoid.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  children: [
                    const Icon(Icons.cancel_rounded,
                        size: 14, color: Colors.redAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 12,
                            height: 1.3),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
