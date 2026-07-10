import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/models.dart' show GoalDirection;
import '../services/haptics.dart';
import '../widgets/input_formatters.dart';
import '../providers/fitness_provider.dart';
import '../main.dart' show MainNavigationScreen;

// ─── Design tokens (mirrors app palette) ───────────────────────────────────────
const _kGreen  = Color(0xFF30D158);
const _kCard   = Color(0xFF1E1E22);
const _kSecond = Color(0xFF8E8E93);

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();
  final TextEditingController _goalController = TextEditingController();
  // null until the user actively picks — avoids the old silent male default that
  // gave every woman a male BMR/TDEE (~165 kcal/day too high) until she found
  // the toggle buried in Stats.
  bool? _sexIsMale;
  // Goal direction — defaults to the app's fat-loss focus; the user can change
  // it here (and later in Settings). Saved explicitly on finish.
  GoalDirection _goalDir = GoalDirection.lose;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    // Rebuild so the Continue button can gently react to the name field.
    _nameController.addListener(_onNameChanged);
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  bool get _nameEntered => _nameController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _pageController.dispose();
    _nameController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _ageController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
    setState(() => _currentPage = page);
  }

  Future<void> _finish() async {
    final provider = context.read<FitnessProvider>();
    final name = _nameController.text.trim();
    if (name.isNotEmpty) {
      await provider.saveUserName(name);
    }
    // Persist whatever profile fields the user provided so BMI/BMR/TDEE/forecast
    // light up on day one instead of showing "—" until they hunt down Stats.
    // Every field is optional; sex is only saved when explicitly chosen.
    if (_sexIsMale != null) {
      await provider.saveSex(_sexIsMale!);
    }
    final height = double.tryParse(_heightController.text.trim());
    if (height != null && height > 0) await provider.saveHeight(height);
    final age = int.tryParse(_ageController.text.trim());
    if (age != null && age > 0) await provider.saveAge(age);
    final goal = double.tryParse(_goalController.text.trim());
    if (goal != null && goal > 0) await provider.saveGoalWeight(goal);
    await provider.saveGoalDirection(_goalDir);
    final weight = double.tryParse(_weightController.text.trim());
    if (weight != null && weight > 0) {
      await provider.logBodyEntry(weightKg: weight);
    }
    await provider.markOnboardingDone();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Page content
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _WelcomePage(nameController: _nameController),
                  _ProfilePage(
                    weightController: _weightController,
                    heightController: _heightController,
                    ageController: _ageController,
                    goalController: _goalController,
                    sexIsMale: _sexIsMale,
                    onSexChanged: (v) {
                      Haptics.selection();
                      setState(() => _sexIsMale = v);
                    },
                    goalDir: _goalDir,
                    onGoalDirChanged: (d) {
                      Haptics.selection();
                      setState(() => _goalDir = d);
                    },
                  ),
                  _ActivityPermissionPage(onFinish: _finish),
                ],
              ),
            ),

            // Page dots + navigation
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Page dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (i) {
                      final active = i == _currentPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active ? _kGreen : _kSecond.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 20),

                  // Navigation button — shown on the Welcome (0) and Profile (1)
                  // pages. The Activity page (2) carries its own Allow/Skip buttons.
                  if (_currentPage == 0 || _currentPage == 1) ...[
                    // Gentle hint on the name page — encourages without blocking.
                    if (_currentPage == 0)
                      AnimatedOpacity(
                        opacity: _nameEntered ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                            'Add your name so we can make this yours 🙂',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _kSecond,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    // Sex hint on the profile page — this one BLOCKS: without it
                    // every calorie/BMR figure silently assumes male (~165
                    // kcal/day off for women). One tap, materially changes math.
                    if (_currentPage == 1)
                      AnimatedOpacity(
                        opacity: _sexIsMale == null ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                            'Select your biological sex — it drives your calorie math',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _kSecond,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        // Profile page requires an explicit sex choice; the
                        // rest of its fields stay optional.
                        onPressed: (_currentPage == 1 && _sexIsMale == null)
                            ? null
                            : () {
                                Haptics.tap();
                                _goToPage(_currentPage + 1);
                              },
                        style: ElevatedButton.styleFrom(
                          // Soften (not disable) the Welcome button until a name
                          // is entered.
                          backgroundColor: (_currentPage == 0 && !_nameEntered)
                              ? _kGreen.withValues(alpha: 0.45)
                              : _kGreen,
                          disabledBackgroundColor:
                              _kGreen.withValues(alpha: 0.25),
                          disabledForegroundColor: Colors.black45,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Continue',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Page 1: Welcome ────────────────────────────────────────────────────────────
class _WelcomePage extends StatelessWidget {
  final TextEditingController nameController;
  const _WelcomePage({required this.nameController});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF30D158), Color(0xFF40C8E0)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Icon(Icons.fitness_center_rounded, size: 48, color: Colors.black),
          ),
          const SizedBox(height: 24),
          const Text(
            'Welcome to K Fitness',
            style: TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your personal fat-loss & muscle-retention tracker. Built for Indian lifestyles.',
            style: TextStyle(
              color: _kSecond,
              fontSize: 15,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _kGreen.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'What should we call you?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  autofocus: false,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Enter your name',
                    hintStyle: const TextStyle(color: _kSecond),
                    filled: true,
                    fillColor: const Color(0xFF2C2C2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: _kGreen, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    prefixIcon: const Icon(
                      Icons.person_outline_rounded,
                      color: _kSecond,
                      size: 20,
                    ),
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

// ─── Page 2: Profile ────────────────────────────────────────────────────────────
class _ProfilePage extends StatelessWidget {
  final TextEditingController weightController;
  final TextEditingController heightController;
  final TextEditingController ageController;
  final TextEditingController goalController;
  final bool? sexIsMale;
  final ValueChanged<bool> onSexChanged;
  final GoalDirection goalDir;
  final ValueChanged<GoalDirection> onGoalDirChanged;

  const _ProfilePage({
    required this.weightController,
    required this.heightController,
    required this.ageController,
    required this.goalController,
    required this.sexIsMale,
    required this.onSexChanged,
    required this.goalDir,
    required this.onGoalDirChanged,
  });

  static String _goalLabel(GoalDirection d) => switch (d) {
        GoalDirection.lose => 'Lose',
        GoalDirection.maintain => 'Maintain',
        GoalDirection.gain => 'Gain',
      };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF30D158), Color(0xFF40C8E0)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Icon(Icons.insights_rounded, size: 48, color: Colors.black),
          ),
          const SizedBox(height: 16),
          const Text(
            'A bit about you',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Sex is required — it changes your calorie math. The rest is '
            'optional, but unlocks your calorie targets, BMI, body-composition '
            'read and weight forecast right away. Change anytime in Stats.',
            style: TextStyle(color: _kSecond, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 24),

          // Biological sex — drives BMR/TDEE and sex-specific body-fat/FFMI ranges.
          const Text(
            'BIOLOGICAL SEX',
            style: TextStyle(
              color: _kSecond,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SexButton(
                  label: 'Male',
                  selected: sexIsMale == true,
                  onTap: () => onSexChanged(true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SexButton(
                  label: 'Female',
                  selected: sexIsMale == false,
                  onTap: () => onSexChanged(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: _NumField(
                  controller: weightController,
                  label: 'Weight',
                  unit: 'kg',
                  icon: Icons.monitor_weight_outlined,
                  fieldKey: 'ob_weight',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumField(
                  controller: heightController,
                  label: 'Height',
                  unit: 'cm',
                  icon: Icons.height_rounded,
                  allowDecimal: false,
                  fieldKey: 'ob_height',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _NumField(
                  controller: ageController,
                  label: 'Age',
                  unit: 'yrs',
                  icon: Icons.cake_outlined,
                  allowDecimal: false,
                  fieldKey: 'ob_age',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumField(
                  controller: goalController,
                  label: 'Goal weight',
                  unit: 'kg',
                  icon: Icons.flag_outlined,
                  fieldKey: 'ob_goal',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Goal direction — drives the calorie target & coaching tone.
          const Text(
            'YOUR GOAL',
            style: TextStyle(
              color: _kSecond,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final d in GoalDirection.values)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        right: d == GoalDirection.values.last ? 0 : 10),
                    child: _GoalDirButton(
                      label: _goalLabel(d),
                      selected: d == goalDir,
                      onTap: () => onGoalDirChanged(d),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GoalDirButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _GoalDirButton(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _kGreen.withValues(alpha: 0.18) : _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? _kGreen : _kSecond.withValues(alpha: 0.25),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _kGreen : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SexButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SexButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _kGreen.withValues(alpha: 0.18) : _kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? _kGreen : _kSecond.withValues(alpha: 0.25),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _kGreen : Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _NumField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String unit;
  final IconData icon;
  final bool allowDecimal;
  final String fieldKey;
  const _NumField({
    required this.controller,
    required this.label,
    required this.unit,
    required this.icon,
    required this.fieldKey,
    this.allowDecimal = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: _kSecond,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey(fieldKey),
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
          inputFormatters: allowDecimal ? positiveDecimalInput : positiveIntInput,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: InputDecoration(
            hintText: '—',
            hintStyle: const TextStyle(color: _kSecond),
            suffixText: unit,
            suffixStyle: const TextStyle(color: _kSecond, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF2C2C2E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: _kGreen, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            prefixIcon: Icon(icon, color: _kSecond, size: 18),
          ),
        ),
      ],
    );
  }
}

// ─── Page 3: Activity Permission ────────────────────────────────────────────────
class _ActivityPermissionPage extends StatelessWidget {
  final Future<void> Function() onFinish;
  const _ActivityPermissionPage({required this.onFinish});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFF30D158), Color(0xFF40C8E0)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Icon(Icons.directions_walk_rounded, size: 48, color: Colors.black),
          ),
          const SizedBox(height: 28),
          const Text(
            'Track your steps automatically',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'K Fitness uses your phone\'s pedometer to count steps and estimate walking calories throughout the day.',
            style: TextStyle(
              color: _kSecond,
              fontSize: 15,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              children: [
                _PermBullet(
                  icon: '📱',
                  text: 'Steps counted live from your phone sensor',
                ),
                SizedBox(height: 10),
                _PermBullet(
                  icon: '🔥',
                  text: 'Walking calories added to your daily burn',
                ),
                SizedBox(height: 10),
                _PermBullet(
                  icon: '🔒',
                  text: 'Data stays on your device — never uploaded',
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () async {
                await Permission.activityRecognition.request();
                await onFinish();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Allow & Get Started',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: TextButton(
              onPressed: onFinish,
              style: TextButton.styleFrom(
                foregroundColor: _kSecond,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Skip for now',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermBullet extends StatelessWidget {
  final String icon, text;
  const _PermBullet({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(icon, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
