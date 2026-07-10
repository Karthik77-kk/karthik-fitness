import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../services/haptics.dart';
import '../theme/app_tokens.dart';
import '../widgets/date_picker_chip.dart';
import '../widgets/kit/kit.dart';

class WaterScreen extends StatefulWidget {
  final bool embedded;
  const WaterScreen({super.key, this.embedded = false});

  @override
  State<WaterScreen> createState() => _WaterScreenState();
}

class _WaterScreenState extends State<WaterScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  DateTime _logDate = DateTime.now(); // backdate target for water intake

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _removeWater(BuildContext context, int ml) {
    Haptics.selection();
    context.read<FitnessProvider>().removeWater(ml);
  }

  void _addWater(BuildContext context, int ml) async {
    Haptics.tap();
    _animController.forward().then((_) => _animController.reverse());
    await context.read<FitnessProvider>().addWater(ml, date: _logDate);
    if (!mounted) return;
    final onPast = _logDate.day != DateTime.now().day ||
        _logDate.month != DateTime.now().month ||
        _logDate.year != DateTime.now().year;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(onPast
            ? '+$ml ml added to ${_logDate.day}/${_logDate.month}'
            : '+$ml ml added'),
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF40C8E0),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final pct = p.waterGoalMl > 0
        ? (p.todayWaterMl / p.waterGoalMl).clamp(0.0, 1.0)
        : 0.0;
    final remaining = (p.waterGoalMl - p.todayWaterMl).clamp(0, 99999);
    final goalMet = p.todayWaterMl >= p.waterGoalMl;

    final body = Column(
      children: [
        // Backdate chip — logs intake to the chosen day (ring shows today).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: DatePickerChip(
              date: _logDate,
              onChanged: (d) => setState(() => _logDate = d),
            ),
          ),
        ),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Circular water indicator ─────────────────────────────
              AnimatedBuilder(
                animation: _scaleAnim,
                builder: (_, child) =>
                    Transform.scale(scale: _scaleAnim.value, child: child),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: AppShadows.glow(const Color(0xFF40C8E0)),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      height: 200,
                      child: CircularProgressIndicator(
                        value: pct,
                        strokeWidth: 14,
                        backgroundColor:
                            const Color(0xFF40C8E0).withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          goalMet
                              ? const Color(0xFF30D158)
                              : const Color(0xFF40C8E0),
                        ),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          goalMet ? '🎉' : '💧',
                          style: const TextStyle(fontSize: 36),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${p.todayWaterMl}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'ml',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Goal info ────────────────────────────────────────────
              goalMet
                  ? const Text(
                      '🎉 Goal reached! Great job!',
                      style: TextStyle(
                        color: Color(0xFF30D158),
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : Text(
                      '${remaining}ml left to reach goal',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 16,
                      ),
                    ),
              const SizedBox(height: 6),
              Text(
                'Goal: ${p.waterGoalMl}ml · ${(pct * 100).toInt()}% done',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35), fontSize: 13),
              ),
            ],
          ),
        ),

        // ── Add buttons ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _WaterButton(
                      label: '+150ml',
                      sublabel: '½ glass',
                      color: const Color(0xFF40C8E0),
                      onTap: () => _addWater(context, 150),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _WaterButton(
                      label: '+250ml',
                      sublabel: '1 glass',
                      color: const Color(0xFF3A8BC8),
                      onTap: () => _addWater(context, 250),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _WaterButton(
                      label: '+500ml',
                      sublabel: '1 bottle',
                      color: const Color(0xFF1A6BAA),
                      onTap: () => _addWater(context, 500),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: p.todayWaterMl > 0
                        ? () => _removeWater(context, 150)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline,
                        size: 16, color: Colors.white54),
                    label: const Text('-150ml',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: p.todayWaterMl > 0
                        ? () => _removeWater(context, 250)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline,
                        size: 16, color: Colors.white54),
                    label: const Text('-250ml',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: p.todayWaterMl > 0
                        ? () => _removeWater(context, 500)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline,
                        size: 16, color: Colors.white54),
                    label: const Text('-500ml',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Progress bar at bottom ───────────────────────────────────────
        Padding(
          // +nav inset so the −/+ buttons & tip clear the glass nav.
          padding: EdgeInsets.fromLTRB(
              24, 0, 24, 36 + MediaQuery.of(context).padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.tips_and_updates_outlined,
                      size: 14, color: Colors.white70),
                  const SizedBox(width: 4),
                  const Text('Tip:',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Drinking water before meals helps control hunger and reduces calorie intake.',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Tracker 💧'),
      ),
      body: body,
    );
  }
}

class _WaterButton extends StatelessWidget {
  final String label;
  final String sublabel;
  final Color color;
  final VoidCallback onTap;

  const _WaterButton({
    required this.label,
    required this.sublabel,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppTappable(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sublabel,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
          ),
        ],
      ),
    );
  }
}
