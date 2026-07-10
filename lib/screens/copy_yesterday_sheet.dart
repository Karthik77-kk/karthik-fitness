import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/fitness_provider.dart';
import '../services/haptics.dart';
import '../theme/app_tokens.dart';
import '../widgets/input_formatters.dart';
import '../widgets/kit/glass_sheet.dart';

/// Opens the "Copy yesterday's meals" review sheet in the shared glass style.
/// Shows every item logged yesterday as an editable row — rename, retune the
/// macros, or remove — then "Add to today" logs the survivors to today with a
/// fresh timestamp (meal type preserved).
Future<void> showCopyYesterdaySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const GlassSheet(child: _CopyYesterdaySheet()),
  );
}

String _yesterdayKey() {
  final y = DateTime.now().subtract(const Duration(days: 1));
  return '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
}

const Map<MealType, String> _mealLabels = {
  MealType.breakfast: 'Breakfast',
  MealType.lunch: 'Lunch',
  MealType.dinner: 'Dinner',
  MealType.snack: 'Snacks',
};

const Map<MealType, IconData> _mealIcons = {
  MealType.breakfast: Icons.wb_twilight_rounded,
  MealType.lunch: Icons.lunch_dining_rounded,
  MealType.dinner: Icons.dinner_dining_rounded,
  MealType.snack: Icons.cookie_rounded,
};

/// One editable copy of a yesterday entry. Holds its own controllers so the
/// user's edits don't touch the stored history until they hit "Add to today".
class _Row {
  final String key; // stable Dismissible key
  final MealType meal;
  final String servingNote;
  final TextEditingController name;
  final TextEditingController kcal;
  final TextEditingController protein;
  final TextEditingController carbs;
  final TextEditingController fat;

  _Row(FoodEntry e)
      : key = e.id.isNotEmpty
            ? e.id
            : '${e.name}-${e.timestamp.microsecondsSinceEpoch}',
        meal = e.mealType,
        servingNote = e.servingNote,
        name = TextEditingController(text: e.name),
        kcal = TextEditingController(text: e.calories.round().toString()),
        protein = TextEditingController(text: e.protein.round().toString()),
        // Show the effective (real-or-estimated) macros so a legacy entry still
        // arrives with sensible carb/fat values the user can accept or tweak.
        carbs = TextEditingController(text: e.effectiveCarbs.round().toString()),
        fat = TextEditingController(text: e.effectiveFat.round().toString());

  double get kcalValue => double.tryParse(kcal.text) ?? 0;

  void dispose() {
    name.dispose();
    kcal.dispose();
    protein.dispose();
    carbs.dispose();
    fat.dispose();
  }
}

class _CopyYesterdaySheet extends StatefulWidget {
  const _CopyYesterdaySheet();

  @override
  State<_CopyYesterdaySheet> createState() => _CopyYesterdaySheetState();
}

class _CopyYesterdaySheetState extends State<_CopyYesterdaySheet> {
  late final List<_Row> _rows;

  @override
  void initState() {
    super.initState();
    final p = context.read<FitnessProvider>();
    final entries = p.foodHistory[_yesterdayKey()] ?? const <FoodEntry>[];
    _rows = entries.map((e) => _Row(e)).toList();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  int get _totalKcal =>
      _rows.fold(0, (s, r) => s + (int.tryParse(r.kcal.text) ?? 0));

  int get _validCount =>
      _rows.where((r) => r.name.text.trim().isNotEmpty && r.kcalValue > 0).length;

  void _removeAt(int i) {
    Haptics.tap();
    setState(() => _rows.removeAt(i).dispose());
  }

  Future<void> _addToToday() async {
    final p = context.read<FitnessProvider>();
    var added = 0;
    for (final r in _rows) {
      final name = r.name.text.trim();
      final kcal = r.kcalValue;
      if (name.isEmpty || kcal <= 0) continue;
      await p.addFoodEntry(FoodEntry(
        id: p.newId(),
        name: name,
        calories: kcal,
        protein: double.tryParse(r.protein.text) ?? 0,
        carbs: double.tryParse(r.carbs.text) ?? 0,
        fat: double.tryParse(r.fat.text) ?? 0,
        macrosKnown: true, // the user has reviewed/confirmed these macros
        mealType: r.meal,
        timestamp: DateTime.now(),
        servingNote: r.servingNote,
      ));
      added++;
    }
    if (!mounted) return;
    Haptics.success();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('Added $added item${added == 1 ? '' : 's'} to today'),
        backgroundColor: AppColors.green,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              // Grabber
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _header(),
              const Divider(height: 1, color: AppColors.border),
              Flexible(
                child: _rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Text('Nothing left to copy.',
                            style:
                                TextStyle(color: AppColors.muted, fontSize: 14)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        itemCount: _rows.length,
                        itemBuilder: (_, i) => _rowCard(_rows[i], i),
                      ),
              ),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          const Icon(Icons.copy_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Copy yesterday\'s meals', style: AppText.title),
                SizedBox(height: 2),
                Text('Review, edit or remove — then add to today',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
          ),
          Text('$_totalKcal kcal',
              style: const TextStyle(
                  color: AppColors.green,
                  fontWeight: FontWeight.w700,
                  fontSize: 15)),
        ],
      ),
    );
  }

  Widget _rowCard(_Row r, int i) {
    return Dismissible(
      key: ValueKey(r.key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.15),
          borderRadius: AppRadii.rMd,
        ),
        child: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
      ),
      onDismissed: (_) => _removeAt(i),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: AppRadii.rMd,
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_mealIcons[r.meal], size: 15, color: AppColors.muted),
                const SizedBox(width: 6),
                Text(_mealLabels[r.meal]!,
                    style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: AppColors.red),
                  tooltip: 'Remove',
                  onPressed: () => _removeAt(i),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                controller: r.name,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  hintText: 'Food name',
                  hintStyle: const TextStyle(color: AppColors.muted),
                  border: OutlineInputBorder(
                      borderRadius: AppRadii.rSm, borderSide: BorderSide.none),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _macroField(r.kcal, 'KCAL', AppColors.red),
                _macroField(r.protein, 'PROTEIN', AppColors.green),
                _macroField(r.carbs, 'CARBS', AppColors.orange),
                _macroField(r.fat, 'FAT', AppColors.blue),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _macroField(TextEditingController c, String label, Color color) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.muted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
          const SizedBox(height: 4),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: positiveIntInput,
            onChanged: (_) => setState(() {}), // refresh the running total
            textAlign: TextAlign.center,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                  borderRadius: AppRadii.rSm, borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    final n = _validCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.black,
            disabledBackgroundColor: AppColors.green.withValues(alpha: 0.25),
            disabledForegroundColor: Colors.black45,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: AppRadii.rMd),
          ),
          onPressed: n == 0 ? null : _addToToday,
          child: Text(
            n == 0
                ? 'Nothing to add'
                : 'Add $n item${n == 1 ? '' : 's'} to today · $_totalKcal kcal',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
