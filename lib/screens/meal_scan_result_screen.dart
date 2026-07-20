import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/fitness_provider.dart';
import '../services/food_repository.dart';
import '../services/gemini_vision_service.dart';
import '../services/haptics.dart';
import '../theme/app_tokens.dart';
import '../widgets/input_formatters.dart';

/// Full-screen review of an AI meal scan. Every detected food is editable —
/// rename (free text or pick from the food DB + IFCT), edit the portion in
/// grams (which proportionally rescales the macros), tweak macros, remove —
/// then "Add all" logs them to the chosen meal.
class MealScanResultScreen extends StatefulWidget {
  final List<ScannedFood> foods;
  const MealScanResultScreen({super.key, required this.foods});

  @override
  State<MealScanResultScreen> createState() => _MealScanResultScreenState();
}

class _EditRow {
  /// The current baseline for proportional rescaling — the original scan, or the
  /// last DB pick, captured at its own gram weight. Editing the grams field
  /// scales macros from this via [rescaleScannedFood].
  ScannedFood base;

  /// The AI's original portion estimate (grams), frozen at construction. Backs
  /// the quick portion chips (½× … 2×) so the user can correct the one thing a
  /// flat photo can't reveal — depth/quantity — in one tap. 0 when the AI gave
  /// no weight, in which case the chips are hidden.
  final double originGrams;

  final TextEditingController name;
  final TextEditingController grams;
  final TextEditingController kcal;
  final TextEditingController protein;
  final TextEditingController carbs;
  final TextEditingController fat;
  double confidence;

  _EditRow(ScannedFood f)
      : base = f,
        originGrams = f.grams,
        name = TextEditingController(text: f.name),
        grams = TextEditingController(
            text: f.grams > 0 ? f.grams.round().toString() : ''),
        kcal = TextEditingController(text: f.kcal.round().toString()),
        protein = TextEditingController(text: f.protein.round().toString()),
        carbs = TextEditingController(text: f.carbs.round().toString()),
        fat = TextEditingController(text: f.fat.round().toString()),
        confidence = f.confidence;

  double get gramsValue => double.tryParse(grams.text) ?? 0;

  /// Rescale the macro fields to the current grams, from [base]. Guards grams=0
  /// (and an unknown original portion) by leaving the macros untouched.
  void applyGrams() {
    final g = gramsValue;
    if (g <= 0) return;
    final scaled = rescaleScannedFood(base, g);
    kcal.text = scaled.kcal.round().toString();
    protein.text = scaled.protein.round().toString();
    carbs.text = scaled.carbs.round().toString();
    fat.text = scaled.fat.round().toString();
  }

  /// Set the portion to [grams] and rescale macros to match. Used by the quick
  /// portion chips.
  void setGrams(double grams) {
    this.grams.text = grams.round().toString();
    applyGrams();
  }

  /// Replace name + macros from a picked food, and re-baseline so later grams
  /// edits scale from these new values at the current grams.
  void applyPick(FoodItem item) {
    name.text = item.name;
    kcal.text = item.calories.round().toString();
    protein.text = item.protein.round().toString();
    carbs.text = item.carbs.round().toString();
    fat.text = item.fat.round().toString();
    confidence = 1.0; // user-confirmed via DB
    base = ScannedFood(
      name: item.name,
      grams: gramsValue, // 0 when blank — rescale then no-ops, which is correct
      kcal: item.calories,
      protein: item.protein,
      carbs: item.carbs,
      fat: item.fat,
      confidence: 1.0,
    );
  }

  void dispose() {
    name.dispose();
    grams.dispose();
    kcal.dispose();
    protein.dispose();
    carbs.dispose();
    fat.dispose();
  }
}

class _MealScanResultScreenState extends State<MealScanResultScreen> {
  late final List<_EditRow> _rows;
  late MealType _meal;

  @override
  void initState() {
    super.initState();
    _rows = widget.foods.map((f) => _EditRow(f)).toList();
    final h = DateTime.now().hour;
    _meal = h < 11
        ? MealType.breakfast
        : h < 16
            ? MealType.lunch
            : h < 21
                ? MealType.dinner
                : MealType.snack;
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

  String _mealLabel(MealType m) =>
      {'breakfast': 'Breakfast', 'lunch': 'Lunch', 'dinner': 'Dinner', 'snack': 'Snacks'}[
          m.name]!;

  Future<void> _pickFromDb(_EditRow row) async {
    final picked = await showModalBottomSheet<FoodItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg))),
      builder: (_) => const _FoodDbPicker(),
    );
    if (picked == null) return;
    Haptics.selection();
    setState(() => row.applyPick(picked));
  }

  Future<void> _addAll() async {
    final p = context.read<FitnessProvider>();
    var added = 0;
    for (final r in _rows) {
      final name = r.name.text.trim();
      final kcal = double.tryParse(r.kcal.text) ?? 0;
      if (name.isEmpty || kcal <= 0) continue;
      final grams = r.gramsValue;
      await p.addFoodEntry(FoodEntry(
        id: p.newId(),
        name: name,
        calories: kcal,
        protein: double.tryParse(r.protein.text) ?? 0,
        carbs: double.tryParse(r.carbs.text) ?? 0,
        fat: double.tryParse(r.fat.text) ?? 0,
        macrosKnown: true,
        mealType: _meal,
        timestamp: DateTime.now(),
        servingNote: grams > 0 ? '~${grams.round()} g · AI scan' : 'AI scan',
      ));
      added++;
    }
    if (!mounted) return;
    Haptics.success();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(
            'Added $added item${added == 1 ? '' : 's'} to ${_mealLabel(_meal)}'),
        backgroundColor: AppColors.green,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review scan'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text('$_totalKcal kcal',
                  style: const TextStyle(
                      color: AppColors.green,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _mealSelector(),
          const Divider(height: 1, color: AppColors.surface2),
          Expanded(
            child: _rows.isEmpty
                ? const Center(
                    child: Text('No items — go back and rescan.',
                        style: TextStyle(color: AppColors.muted)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: _rows.length,
                    itemBuilder: (_, i) => _rowCard(_rows[i], i),
                  ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _mealSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: MealType.values.map((m) {
          final sel = m == _meal;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(_mealLabel(m)),
              selected: sel,
              onSelected: (_) {
                Haptics.selection();
                setState(() => _meal = m);
              },
              selectedColor: AppColors.green.withValues(alpha: 0.2),
              backgroundColor: AppColors.surface2,
              labelStyle: TextStyle(
                  color: sel ? AppColors.green : AppColors.muted,
                  fontSize: 13,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.normal),
              side: BorderSide(color: sel ? AppColors.green : AppColors.border),
              shape:
                  RoundedRectangleBorder(borderRadius: AppRadii.rLg),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _rowCard(_EditRow r, int i) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: AppRadii.rMd,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                // Name sits in its own filled box so it reads as an editable
                // field, not floating text over the card.
                Expanded(
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
                          borderRadius: AppRadii.rSm,
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                    ),
                  ),
                ),
                if (r.confidence > 0 && r.confidence < 0.6)
                  const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(Icons.help_outline_rounded,
                        size: 16, color: AppColors.orange),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.search_rounded,
                      size: 20, color: AppColors.muted),
                  tooltip: 'Replace from food database',
                  onPressed: () => _pickFromDb(r),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: AppColors.red),
                  tooltip: 'Remove',
                  onPressed: () {
                    Haptics.tap();
                    setState(() => _rows.removeAt(i).dispose());
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Editable portion — rescales macros proportionally on change.
          _gramsField(r),
          const SizedBox(height: 8),
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
    );
  }

  Widget _gramsField(_EditRow r) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.scale_outlined, size: 15, color: AppColors.muted),
              const SizedBox(width: 6),
              const Text('Portion',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              SizedBox(
                width: 78,
                child: TextField(
                  controller: r.grams,
                  keyboardType: TextInputType.number,
                  inputFormatters: positiveIntInput,
                  onChanged: (_) => setState(() => r.applyGrams()),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    hintText: '—',
                    hintStyle: const TextStyle(color: AppColors.muted),
                    border: OutlineInputBorder(
                        borderRadius: AppRadii.rSm, borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text('g',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
          // Quick portion correction — the photo can't reveal depth, so let the
          // user say "actually I had 1½× that" in one tap. Scales from the AI's
          // original estimate. Hidden when the AI gave no weight to scale from.
          if (r.originGrams > 0) _portionChips(r),
        ],
      ),
    );
  }

  Widget _portionChips(_EditRow r) {
    const factors = <(double, String)>[
      (0.5, '½×'),
      (0.75, '¾×'),
      (1.0, '1×'),
      (1.5, '1½×'),
      (2.0, '2×'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        children: factors.map((e) {
          final target = (r.originGrams * e.$1).roundToDouble();
          final selected = r.gramsValue.round() == target.round();
          return GestureDetector(
            onTap: () {
              Haptics.selection();
              setState(() => r.setGrams(target));
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.green.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: AppRadii.rSm,
                border: Border.all(
                    color: selected
                        ? AppColors.green
                        : Colors.white.withValues(alpha: 0.08)),
              ),
              child: Text(e.$2,
                  style: TextStyle(
                      color: selected ? AppColors.green : AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
          );
        }).toList(),
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
            onChanged: (_) => setState(() {}), // refresh total
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
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.black,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: AppRadii.rMd),
          ),
          onPressed: _rows.isEmpty ? null : _addAll,
          child: Text(
            _rows.isEmpty
                ? 'Nothing to add'
                : 'Add ${_rows.length} item${_rows.length == 1 ? '' : 's'} · $_totalKcal kcal',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// Searchable picker over the local food DB + IFCT (offline), returns the chosen
/// item. Uses [FoodRepository.searchLocal] — the same curated + 500+ IFCT source
/// the Add-Food sheet uses — so IFCT-only foods are reachable here too.
class _FoodDbPicker extends StatefulWidget {
  const _FoodDbPicker();
  @override
  State<_FoodDbPicker> createState() => _FoodDbPickerState();
}

class _FoodDbPickerState extends State<_FoodDbPicker> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<FoodItem> get _results {
    final q = _q.trim();
    if (q.isEmpty) {
      // Empty query: browse the curated head (searchLocal returns [] for '').
      return kFoodDatabase.take(30).toList();
    }
    return FoodRepository.instance.searchLocal(q);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (_, scroll) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(
                  hintText: 'Search food database…',
                  prefixIcon:
                      Icon(Icons.search, size: 20, color: AppColors.muted),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final f = _results[i];
                  return ListTile(
                    dense: true,
                    title: Text(f.name),
                    subtitle: Text(
                      '${f.calories.round()} kcal · ${f.protein.round()}g P · ${f.serving}',
                      style:
                          const TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, f),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
