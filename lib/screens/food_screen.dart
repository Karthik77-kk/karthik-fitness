import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../widgets/input_formatters.dart';
import '../providers/fitness_provider.dart';
import '../models/models.dart';
import '../services/food_api_service.dart';
import '../services/food_repository.dart';
import '../widgets/app_empty_state.dart';
import '../widgets/date_picker_chip.dart';
import '../widgets/kit/kit.dart';
import '../theme/app_tokens.dart';
import 'barcode_scanner_screen.dart';
import 'copy_yesterday_sheet.dart';
import '../services/haptics.dart';
import '../services/meal_scan.dart';
import '../services/gemini_vision_service.dart';

/// Call this from any context (standalone or embedded) to open the Add Food sheet.
void showAddFoodSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const GlassSheet(child: _AddFoodSheet()),
  ).then((_) {
    if (context.mounted) FocusScope.of(context).unfocus();
  });
}

class FoodScreen extends StatelessWidget {
  final bool embedded;
  const FoodScreen({super.key, this.embedded = false});

  Widget _buildBody(BuildContext context, FitnessProvider p) {
    if (p.todayFood.isEmpty) return const _EmptyState();
    return ListView(
      // +nav inset so the last meal clears the glass nav and the Add-Food FAB.
      padding: EdgeInsets.only(
          bottom: 100 + MediaQuery.of(context).padding.bottom, top: 8),
      children: [
        _MealSection(
            icon: Icons.wb_sunny_rounded,
            title: 'Breakfast',
            entries: p.breakfastEntries),
        _MealSection(
            icon: Icons.restaurant_rounded,
            title: 'Lunch',
            entries: p.lunchEntries),
        _MealSection(
            icon: Icons.nightlight_round,
            title: 'Dinner',
            entries: p.dinnerEntries),
        _MealSection(
            icon: Icons.cookie_rounded,
            title: 'Snacks',
            entries: p.snackEntries),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();

    // When embedded inside NutritionScreen, just return the body
    if (embedded) return _buildBody(context, p);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Food Tracker'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Builder(builder: (_) {
                  final left = p.caloriesRemaining; // goal − eaten
                  final over = left < 0;
                  return Text(
                    over ? '${-left} kcal over' : '$left kcal left',
                    style: TextStyle(
                      color: over ? Colors.redAccent : const Color(0xFF30D158),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                }),
                Text(
                  p.proteinRemaining > 0
                      ? '${p.proteinRemaining}g protein left'
                      : 'protein goal ✓',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Scan Meal — AI photo → foods (only when the Gemini key is compiled in).
          if (GeminiVisionService.isConfigured) ...[
            FloatingActionButton(
              heroTag: 'scanMeal',
              onPressed: () => startMealScan(context),
              backgroundColor: const Color(0xFF2C2C2E),
              elevation: 2,
              tooltip: 'Scan meal',
              child: const Icon(Icons.photo_camera_rounded, color: Color(0xFF30D158)),
            ),
            const SizedBox(width: 12),
          ],
          FloatingActionButton.extended(
            heroTag: 'addFood',
            onPressed: () => showAddFoodSheet(context),
            backgroundColor: const Color(0xFF30D158),
            icon: const Icon(Icons.add, color: Colors.white),
            label: const Text('Add Food', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _buildBody(context, p),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final key =
        '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
    final hasYesterday = (p.foodHistory[key] ?? []).isNotEmpty;

    return AppEmptyState(
      icon: '🍽️',
      title: 'No food logged today',
      subtitle: 'Tap + Add Food to start logging',
      // Opens a glass review sheet so the user can edit/remove yesterday's items
      // before adding them to today, instead of copying everything blindly.
      action: hasYesterday
          ? OutlinedButton.icon(
              onPressed: () {
                Haptics.tap();
                showCopyYesterdaySheet(context);
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy yesterday\'s meals'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF30D158),
                side: const BorderSide(color: Color(0xFF30D158)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            )
          : null,
    );
  }
}

// ── Meal Section ──────────────────────────────────────────────────────────────

class _MealSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<FoodEntry> entries;

  const _MealSection(
      {required this.icon, required this.title, required this.entries});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Icon(icon, size: 17, color: Colors.white70),
              const SizedBox(width: 7),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              if (entries.isNotEmpty)
                Text(
                  '${entries.fold(0.0, (s, e) => s + e.calories).toInt()} kcal',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                ),
            ],
          ),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Nothing logged',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25), fontSize: 12)),
          )
        else
          // Tap a tile to edit / delete. Swipe-to-delete was removed so an
          // accidental horizontal drag while scrolling can't wipe an entry.
          ...entries.map((entry) => _FoodEntryTile(entry: entry)),
      ],
    );
  }
}

// ── Food Entry Tile ───────────────────────────────────────────────────────────

class _FoodEntryTile extends StatelessWidget {
  final FoodEntry entry;
  const _FoodEntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showEditFoodDialog(context, entry),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E22),
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppShadows.card,
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (entry.servingNote.isNotEmpty)
                    Text(entry.servingNote,
                        style: const TextStyle(
                            color: Color(0xFF8E8E93), fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${entry.calories.toInt()} kcal',
                    style: const TextStyle(
                        color: Color(0xFF30D158),
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
                Text('${entry.protein.toStringAsFixed(1)}g protein',
                    style: TextStyle(
                        color: const Color(0xFF40C8E0).withValues(alpha: 0.8),
                        fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a food confirmation toast, replacing any already-visible/queued one so
/// rapid add/remove taps don't stack a backlog of snackbars sliding in one
/// after another. Each new toast instantly supersedes the previous.
void _foodSnack(ScaffoldMessengerState messenger, String text,
    {Color color = const Color(0xFF30D158),
    Duration duration = const Duration(seconds: 1),
    SnackBarAction? action}) {
  messenger.clearSnackBars();
  messenger.showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: color,
    duration: duration,
    action: action,
  ));
}

/// Edit sheet for a logged food entry — adjust calories/protein/carbs/fat, or
/// delete (with an Undo). Operates on today's log (the only place tiles show).
void _showEditFoodDialog(BuildContext context, FoodEntry entry) {
  final provider = context.read<FitnessProvider>();
  final messenger = ScaffoldMessenger.of(context);
  showDialog(
    context: context,
    builder: (_) => _EditFoodDialog(
        entry: entry, provider: provider, messenger: messenger),
  );
}

/// Stateful so the four field controllers live in State and dispose only after
/// the route is fully removed — disposing them in showDialog's `.then` fires
/// mid-exit-animation and throws "controller used after dispose".
class _EditFoodDialog extends StatefulWidget {
  final FoodEntry entry;
  final FitnessProvider provider;
  final ScaffoldMessengerState messenger;
  const _EditFoodDialog(
      {required this.entry, required this.provider, required this.messenger});

  @override
  State<_EditFoodDialog> createState() => _EditFoodDialogState();
}

class _EditFoodDialogState extends State<_EditFoodDialog> {
  late final TextEditingController _calCtrl;
  late final TextEditingController _protCtrl;
  late final TextEditingController _carbCtrl;
  late final TextEditingController _fatCtrl;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _calCtrl = TextEditingController(text: e.calories.round().toString());
    _protCtrl = TextEditingController(text: e.protein.round().toString());
    // Pre-fill carbs/fat with the entry's effective values (real when known,
    // else the 65/35 estimate) so the user sees & can correct a starting number.
    _carbCtrl = TextEditingController(text: e.effectiveCarbs.round().toString());
    _fatCtrl = TextEditingController(text: e.effectiveFat.round().toString());
  }

  @override
  void dispose() {
    _calCtrl.dispose();
    _protCtrl.dispose();
    _carbCtrl.dispose();
    _fatCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final e = widget.entry;
    final cal = (double.tryParse(_calCtrl.text.trim()) ?? e.calories)
        .clamp(0.0, double.infinity);
    final prot = (double.tryParse(_protCtrl.text.trim()) ?? e.protein)
        .clamp(0.0, 100000.0);
    final carbs = (double.tryParse(_carbCtrl.text.trim()) ?? e.effectiveCarbs)
        .clamp(0.0, 100000.0);
    final fat = (double.tryParse(_fatCtrl.text.trim()) ?? e.effectiveFat)
        .clamp(0.0, 100000.0);
    widget.provider.updateFoodEntry(
      e.id,
      FoodEntry(
        id: e.id,
        name: e.name,
        calories: cal,
        protein: prot,
        carbs: carbs,
        fat: fat,
        // The user has now reviewed the macros, so record them as known
        // (stops the donut from re-estimating carbs/fat for this entry).
        macrosKnown: true,
        mealType: e.mealType,
        timestamp: e.timestamp,
        servingNote: e.servingNote,
      ),
    );
    Navigator.pop(context);
  }

  void _delete() {
    final e = widget.entry;
    widget.provider.removeFoodEntry(e.id);
    Navigator.pop(context);
    _foodSnack(widget.messenger, '${e.name} removed',
        color: const Color(0xFF2C2C2E),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          textColor: const Color(0xFF30D158),
          onPressed: () => widget.provider.addFoodEntry(e),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(e.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          if (e.servingNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(e.servingNote,
                  style:
                      const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
            ),
        ],
      ),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
              child: _EditMacroField(
                  ctrl: _calCtrl,
                  label: 'Calories',
                  unit: 'kcal',
                  color: const Color(0xFF30D158))),
          const SizedBox(width: 10),
          Expanded(
              child: _EditMacroField(
                  ctrl: _protCtrl,
                  label: 'Protein',
                  unit: 'g',
                  color: const Color(0xFF40C8E0))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: _EditMacroField(
                  ctrl: _carbCtrl,
                  label: 'Carbs',
                  unit: 'g',
                  color: const Color(0xFFFF9F0A))),
          const SizedBox(width: 10),
          Expanded(
              child: _EditMacroField(
                  ctrl: _fatCtrl,
                  label: 'Fat',
                  unit: 'g',
                  color: const Color(0xFF8E8E93))),
        ]),
      ]),
      actions: [
        TextButton(
          onPressed: _delete,
          child:
              const Text('Delete', style: TextStyle(color: Color(0xFFFF453A))),
        ),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF30D158),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text('Save',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

/// A labelled numeric field for the edit-food dialog: a small caption above a
/// filled box holding the coloured value + unit. Keeps the four macro editors
/// visually aligned instead of floating labels drifting over bare fields.
class _EditMacroField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String unit;
  final Color color;
  const _EditMacroField(
      {required this.ctrl,
      required this.label,
      required this.unit,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4)),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: positiveDecimalInput,
            style: TextStyle(
                color: color, fontSize: 18, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              suffixText: unit,
              suffixStyle: TextStyle(
                  color: color.withValues(alpha: 0.6), fontSize: 12),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        ]);
  }
}

// ── Add Food Bottom Sheet ─────────────────────────────────────────────────────

class _AddFoodSheet extends StatefulWidget {
  const _AddFoodSheet();
  @override
  State<_AddFoodSheet> createState() => _AddFoodSheetState();
}

class _AddFoodSheetState extends State<_AddFoodSheet> {
  final _searchCtrl = TextEditingController();
  MealType _selectedMeal = MealType.breakfast;
  String _search = '';
  String _selectedCategory = 'Popular';
  bool _showCustom = false;
  DateTime _selectedDate = DateTime.now(); // backdate target for logged items

  final _nameCtrl = TextEditingController();
  final _calCtrl = TextEditingController();
  final _protCtrl = TextEditingController();

  // Online search state
  List<FoodApiResult> _onlineResults = [];
  bool _searchingOnline = false;
  String? _onlineError;
  String _lastOnlineQuery = '';

  // Barcode awaiting a manual gap-fill (set when a scan resolves nothing).
  String? _pendingBarcode;

  // Recently-scanned products (quick re-log row when search is empty).
  List<FoodApiResult> _recentScans = [];

  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final h = DateTime.now().hour;
    if (h >= 5 && h < 11)
      _selectedMeal = MealType.breakfast;
    else if (h >= 11 && h < 16)
      _selectedMeal = MealType.lunch;
    else if (h >= 16 && h < 21)
      _selectedMeal = MealType.dinner;
    else
      _selectedMeal = MealType.snack;

    // Ensure the bundled IFCT source is in memory (usually already warmed at
    // startup); rebuild once loaded so offline Indian foods appear in search.
    if (!FoodRepository.instance.isLoaded) {
      FoodRepository.instance.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }

    FoodApiService.recentScans().then((s) {
      if (mounted) setState(() => _recentScans = s);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    _calCtrl.dispose();
    _protCtrl.dispose();
    super.dispose();
  }

  /// Category browse list (empty-search state). Dedupes by name within the
  /// category so a food curated more than once doesn't appear twice.
  /// Live text search now flows through [_unifiedResults] instead.
  List<FoodItem> get _browseItems {
    final seen = <String>{};
    final out = <FoodItem>[];
    for (final f in kFoodDatabase) {
      if (f.category != _selectedCategory) continue;
      if (seen.add(f.name.toLowerCase())) out.add(f);
    }
    return out;
  }

  /// Unified, ranked Add-Food search list: LOCAL (curated + IFCT, instant) +
  /// REMOTE (OpenFoodFacts + USDA, when fetched), deduped by name and ranked
  /// `exact > curated > IFCT > OFF > USDA`, capped at 8.
  List<UnifiedFoodResult> get _unifiedResults {
    final q = _search.trim();
    if (q.isEmpty) return const [];
    final local = FoodRepository.instance
        .searchLocal(q)
        .map(UnifiedFoodResult.fromLocal);
    final remote = _onlineResults.map(UnifiedFoodResult.fromRemote);
    return mergeFoodResults(q, [...local, ...remote], cap: 8);
  }

  /// Treats an IFCT [FoodItem] (per 100 g) as a [FoodApiResult] so it can reuse
  /// the per-100g gram picker / add path.
  FoodApiResult _ifctAsApi(FoodItem f) => FoodApiResult(
        name: f.name,
        calories100g: f.calories,
        protein100g: f.protein,
        carbs100g: f.carbs,
        fat100g: f.fat,
        source: 'IFCT',
      );

  // ── Online search ────────────────────────────────────────────────────────────

  Future<void> _searchOnline(BuildContext ctx) async {
    if (_searchingOnline) return;
    final query = _search.trim();
    if (query.length < 2) return;

    setState(() {
      _searchingOnline = true;
      _onlineError = null;
      _onlineResults = [];
      _lastOnlineQuery = query;
    });

    try {
      // Combined REMOTE half: OpenFoodFacts + USDA (USDA only when a key is set).
      final results = await FoodApiService.searchByText(query);
      if (!mounted) return;
      setState(() {
        _searchingOnline = false;
        _onlineResults = results;
        // No "no results" error here — remote rows just merge into the unified
        // list; an empty remote set is fine when local already has matches.
        _onlineError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchingOnline = false;
        _onlineError = 'No internet connection. Try again later.';
      });
    }
  }

  // ── Gram picker (for API results — per-100g basis) ───────────────────────────

  void _showGramPicker(BuildContext ctx, FoodApiResult item) {
    // Default to the last grams logged for this food (portion memory), else the
    // product's declared serving (e.g. a scanned 30 g biscuit pack), else 100 g.
    final hasServing = item.servingSizeG != null && item.servingSizeG! > 0;
    final remembered = context.read<FitnessProvider>().lastPortion(item.name);
    final gCtrl = TextEditingController(
        text: remembered != null
            ? remembered.round().toString()
            : hasServing
                ? item.servingSizeG!.round().toString()
                : '100');

    showDialog(
      context: ctx,
      barrierColor: Colors.black87,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setD) {
          final raw = double.tryParse(gCtrl.text) ?? 100.0;
          final grams = raw.clamp(1.0, 5000.0);
          final cal = item.caloriesForGrams(grams).round();
          final prot = item.proteinForGrams(grams);
          final carbs = item.carbsForGrams(grams);
          final fat = item.fatForGrams(grams);

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E22),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.public_rounded,
                      size: 12, color: Color(0xFF40C8E0)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${item.source} · per 100g: ${item.calories100g.round()} kcal, '
                      '${item.protein100g.toStringAsFixed(1)}g protein'
                      '${hasServing ? ' · 1 serving ≈ ${item.servingSizeG!.round()}g' : ''}',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.38),
                          fontSize: 10),
                    ),
                  ),
                ]),
              ],
            ),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 4),
              // Quick gram presets
              Row(
                  children: [50, 100, 150, 200].map((g) {
                final sel = grams.round() == g;
                return Expanded(
                    child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: AppTappable(
                    onTap: () {
                      gCtrl.text = '$g';
                      setD(() {});
                    },
                    borderRadius: BorderRadius.circular(8),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: sel
                          ? const Color(0xFF40C8E0).withValues(alpha: 0.18)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: sel
                            ? const Color(0xFF40C8E0).withValues(alpha: 0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: Text('${g}g',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: sel
                              ? const Color(0xFF40C8E0)
                              : Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        )),
                  ),
                ));
              }).toList()),
              const SizedBox(height: 12),
              // Custom gram field
              TextField(
                controller: gCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: positiveDecimalInput,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  suffix: Text('g',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 16)),
                  hintText: '100',
                  hintStyle:
                      TextStyle(color: Colors.white.withValues(alpha: 0.2)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                ),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 12),
              // Live macro preview
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _NutCol(
                          label: 'Calories',
                          value: '$cal kcal',
                          color: const Color(0xFF30D158)),
                      _NutCol(
                          label: 'Protein',
                          value: '${prot.toStringAsFixed(1)}g',
                          color: const Color(0xFF40C8E0)),
                      _NutCol(
                          label: 'Carbs',
                          value: '${carbs.toStringAsFixed(1)}g',
                          color: const Color(0xFFFF9F0A)),
                      _NutCol(
                          label: 'Fat',
                          value: '${fat.toStringAsFixed(1)}g',
                          color: const Color(0xFF8E8E93)),
                    ]),
              ),
              const SizedBox(height: 4),
            ]),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx),
                child: Text('Cancel',
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.5))),
              ),
              ElevatedButton(
                onPressed: raw < 1
                    ? null
                    : () {
                        Navigator.pop(dCtx);
                        _addApiItem(ctx, item, grams);
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF30D158),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Add',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    ).then((_) => gCtrl.dispose());
  }

  void _addApiItem(BuildContext ctx, FoodApiResult item, double grams) {
    Haptics.tap();
    final provider = ctx.read<FitnessProvider>();
    provider.rememberPortion(item.name, grams); // portion memory (grams)
    final gStr = grams == grams.roundToDouble()
        ? '${grams.toInt()}g'
        : '${grams.toStringAsFixed(1)}g';
    // IFCT is a bundled offline source; Manual is a remembered scan; OFF/USDA
    // are online — label the serving note accordingly.
    final tag = switch (item.source) {
      'IFCT' => '🇮🇳 IFCT',
      'Manual' => '📷 scan',
      _ => '🌐 ${item.source}',
    };
    provider.addFoodEntry(
        FoodEntry(
          id: provider.newId(),
          name: item.name,
          calories: item.caloriesForGrams(grams),
          protein: item.proteinForGrams(grams),
          carbs: item.carbsForGrams(grams),
          fat: item.fatForGrams(grams),
          macrosKnown: item.macrosKnown,
          mealType: _selectedMeal,
          timestamp: _selectedDate,
          servingNote: '$gStr · $tag',
        ),
        date: _selectedDate);
    final messenger = ScaffoldMessenger.of(ctx);
    Navigator.pop(ctx);
    _foodSnack(messenger, '${item.name} added ✓');
  }

  // ────────────────────────────────────────────────────────────────────────────

  void _showQuantityPicker(BuildContext ctx, FoodItem item) {
    // Default to the last quantity logged for this food (portion memory).
    final remembered = context.read<FitnessProvider>().lastPortion(item.name);
    double servings = (remembered ?? 1.0).clamp(0.5, 10.0);
    showDialog(
      context: ctx,
      barrierColor: Colors.black87,
      builder: (dCtx) => StatefulBuilder(builder: (dCtx, setDState) {
        final cal = (item.calories * servings).round();
        final prot = item.protein * servings;
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E22),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(children: [
            Text(item.emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(item.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold))),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Per serving: ${item.serving}',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45), fontSize: 12)),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _QtyBtn(
                  icon: Icons.remove,
                  onTap: () {
                    if (servings > 0.5)
                      setDState(
                          () => servings = (servings - 0.5).clamp(0.5, 10.0));
                  }),
              const SizedBox(width: 20),
              Column(children: [
                Text(
                  servings == servings.roundToDouble()
                      ? '${servings.toInt()}'
                      : servings.toStringAsFixed(1),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.bold),
                ),
                Text('serving${servings != 1.0 ? 's' : ''}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12)),
              ]),
              const SizedBox(width: 20),
              _QtyBtn(
                  icon: Icons.add,
                  onTap: () {
                    if (servings < 10)
                      setDState(
                          () => servings = (servings + 0.5).clamp(0.5, 10.0));
                  }),
            ]),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14)),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NutCol(
                        label: 'Calories',
                        value: '$cal kcal',
                        color: const Color(0xFF30D158)),
                    _NutCol(
                        label: 'Protein',
                        value: '${prot.toStringAsFixed(1)}g',
                        color: const Color(0xFF40C8E0)),
                  ]),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: Text('Cancel',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dCtx);
                _addItemWithQty(ctx, item, servings);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Add',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }),
    );
  }

  void _addItemWithQty(BuildContext ctx, FoodItem item, double servings) {
    Haptics.tap();
    final provider = ctx.read<FitnessProvider>();
    provider.rememberPortion(item.name, servings); // portion memory (servings)
    // Format whole servings as "2×" not "2.0×"; keep one decimal for halves.
    final qtyStr = servings == servings.roundToDouble()
        ? servings.toInt().toString()
        : servings.toStringAsFixed(1);
    final label = servings == 1.0 ? item.serving : '$qtyStr× ${item.serving}';
    provider.addFoodEntry(
        FoodEntry(
          id: provider.newId(),
          name: item.name,
          calories: item.calories * servings,
          protein: item.protein * servings,
          // Store the food's REAL macros (0 when the DB item has none) so the entry
          // honestly records whether its carbs/fat are known. The macro donut
          // estimates per-entry at display time via FoodEntry.effectiveCarbs/Fat.
          carbs: item.carbs * servings,
          fat: item.fat * servings,
          macrosKnown: item.macrosKnown,
          mealType: _selectedMeal,
          timestamp: _selectedDate,
          servingNote: label,
        ),
        date: _selectedDate);
    // Capture messenger BEFORE pop (avoids using deactivated context)
    final messenger = ScaffoldMessenger.of(ctx);
    Navigator.pop(ctx);
    _foodSnack(messenger, '${item.name} added ✓');
  }

  void _addCustom(BuildContext ctx) {
    final name = _nameCtrl.text.trim();
    final cal = double.tryParse(_calCtrl.text.trim()) ?? 0;
    // Clamp protein to >= 0 so a stray "-5" can't subtract from the day's total.
    final prot =
        (double.tryParse(_protCtrl.text.trim()) ?? 0).clamp(0.0, 100000.0);
    if (name.isEmpty) {
      _foodSnack(ScaffoldMessenger.of(ctx), '⚠️ Enter a food name',
          color: const Color(0xFFFF9F0A));
      return;
    }
    if (cal <= 0) {
      _foodSnack(ScaffoldMessenger.of(ctx), '⚠️ Enter calories > 0',
          color: const Color(0xFFFF9F0A));
      return;
    }
    Haptics.tap();
    final provider = ctx.read<FitnessProvider>();
    // If this custom add is filling a barcode gap (a scan that resolved
    // nothing), remember the product BY BARCODE so the next scan is instant and
    // offline. Stored per-100g defaulting to a 100 g serving = the entered value.
    final barcode = _pendingBarcode;
    if (barcode != null) {
      FoodApiService.cacheManualBarcode(
          barcode: barcode, name: name, calories: cal, protein: prot);
    }
    provider.addFoodEntry(
        FoodEntry(
          id: provider.newId(),
          name: name,
          calories: cal,
          protein: prot,
          mealType: _selectedMeal,
          timestamp: _selectedDate,
          servingNote:
              barcode != null ? 'custom entry · 📷 scan' : 'custom entry',
        ),
        date: _selectedDate);
    final messenger = ScaffoldMessenger.of(ctx);
    Navigator.pop(ctx);
    _foodSnack(messenger, '$name added ✓');
  }

  // ── Unified result rows ───────────────────────────────────────────────────────

  /// One row in the unified ranked search list. Curated items use the per-serving
  /// quantity picker; IFCT / OFF / USDA use the per-100g gram picker.
  Widget _unifiedTile(UnifiedFoodResult r) {
    if (r.isLocal && r.source == 'curated') {
      final item = r.local!;
      return ListTile(
        leading: Text(item.emoji, style: const TextStyle(fontSize: 22)),
        title: Row(children: [
          Flexible(
            child: Text(item.name,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          _sourceChip('curated'),
        ]),
        subtitle: Text(
          '${item.calories.toInt()} kcal · ${item.protein.toStringAsFixed(1)}g protein · ${item.serving}',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          _starButton(item),
          IconButton(
            icon: const Icon(Icons.add_circle, color: Color(0xFF30D158)),
            onPressed: () => _showQuantityPicker(context, item),
          ),
        ]),
      );
    }

    // IFCT (local, per-100g) or remote OFF/USDA — both use the gram picker.
    final api = r.isLocal ? _ifctAsApi(r.local!) : r.remote!;
    final isIfct = api.source == 'IFCT';
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: (isIfct ? const Color(0xFFFF9F0A) : const Color(0xFF40C8E0))
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: isIfct
              ? const Text('🇮🇳', style: TextStyle(fontSize: 16))
              : const Icon(Icons.public_rounded,
                  size: 18, color: Color(0xFF40C8E0)),
        ),
      ),
      title: Row(children: [
        Flexible(
          child: Text(api.name,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        _sourceChip(api.source),
      ]),
      subtitle: Text(
        '${api.calories100g.round()} kcal · '
        '${api.protein100g.toStringAsFixed(1)}g prot · '
        '${api.carbs100g.toStringAsFixed(1)}g carbs per 100g',
        style:
            TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 10),
      ),
      trailing: IconButton(
        icon: Icon(Icons.add_circle,
            color: isIfct ? const Color(0xFFFF9F0A) : const Color(0xFF40C8E0)),
        onPressed: () => _showGramPicker(context, api),
      ),
    );
  }

  /// Small provenance chip shown on each result row.
  Widget _sourceChip(String source) {
    late final String label;
    late final Color color;
    switch (source) {
      case 'curated':
        label = 'DB';
        color = const Color(0xFF30D158);
        break;
      case 'IFCT':
        label = 'IFCT';
        color = const Color(0xFFFF9F0A);
        break;
      case 'USDA':
        label = 'USDA';
        color = const Color(0xFF40C8E0);
        break;
      case 'OpenFoodFacts':
        label = 'OFF';
        color = const Color(0xFF40C8E0);
        break;
      default:
        label = source;
        color = const Color(0xFF8E8E93);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 9, fontWeight: FontWeight.w700)),
    );
  }

  /// Star toggle to pin/unpin a food. Only for stable local foods (curated/IFCT).
  Widget _starButton(FoodItem item) {
    final fav = context.watch<FitnessProvider>().isFavoriteFood(item.name);
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 20,
          color: fav
              ? const Color(0xFFFF9F0A)
              : Colors.white.withValues(alpha: 0.35)),
      onPressed: () {
        Haptics.selection();
        context.read<FitnessProvider>().toggleFavoriteFood(item.name);
      },
    );
  }

  /// Quick-add chips for pinned foods (shown when search is empty).
  Widget _favoritesRow() {
    final favs = context.watch<FitnessProvider>().favoriteFoodItems;
    if (favs.isEmpty) return const SizedBox.shrink();
    return _ChipSection(
      label: 'FAVORITES',
      icon: Icons.star_rounded,
      iconColor: const Color(0xFFFF9F0A),
      children: favs.map((f) {
        return _quickChip(
          icon: Icons.star_rounded,
          iconColor: const Color(0xFFFF9F0A),
          label: f.name,
          trailing: '${f.calories.round()}kcal',
          onTap: () => f.source == 'IFCT'
              ? _showGramPicker(context, _ifctAsApi(f))
              : _showQuantityPicker(context, f),
        );
      }).toList(),
    );
  }

  /// Quick-add chips for recently-scanned products (shown when search is empty).
  Widget _recentScansRow() {
    if (_recentScans.isEmpty) return const SizedBox.shrink();
    return _ChipSection(
      label: 'RECENTLY SCANNED',
      icon: Icons.qr_code_scanner_rounded,
      iconColor: const Color(0xFF40C8E0),
      children: _recentScans.map((r) {
        return _quickChip(
          icon: Icons.qr_code_scanner_rounded,
          iconColor: const Color(0xFF40C8E0),
          label: r.name,
          trailing: '${r.calories100g.round()}/100g',
          onTap: () => _showGramPicker(context, r),
        );
      }).toList(),
    );
  }

  Widget _quickChip({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String trailing,
    required VoidCallback onTap,
  }) {
    return AppTappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3A3A3C)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: iconColor),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        Text(trailing,
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11)),
      ]),
    );
  }

  // ── Barcode scanning ──────────────────────────────────────────────────────────

  /// Opens the camera scanner after a permission check, then resolves the code.
  Future<void> _openScanner(BuildContext ctx) async {
    var status = await Permission.camera.status;
    if (!status.isGranted) status = await Permission.camera.request();
    if (!ctx.mounted) return;

    if (!status.isGranted) {
      _showCameraDeniedSheet(ctx,
          permanentlyDenied: status.isPermanentlyDenied);
      return;
    }

    final code = await Navigator.of(ctx).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (code == null || code.isEmpty || !ctx.mounted) return;
    await _resolveBarcode(ctx, code);
  }

  /// Camera permission denied — explain + offer settings; manual entry still works.
  void _showCameraDeniedSheet(BuildContext ctx,
      {required bool permanentlyDenied}) {
    showDialog(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Camera needed to scan',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          permanentlyDenied
              ? 'Enable camera access in Settings to scan barcodes, or enter a barcode manually.'
              : 'Allow camera access to scan barcodes, or enter a barcode manually.',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dCtx);
              _manualBarcodeEntry(ctx);
            },
            child: const Text('Enter manually',
                style: TextStyle(color: Color(0xFF40C8E0))),
          ),
          if (permanentlyDenied)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dCtx);
                openAppSettings();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Open settings',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  /// Manual barcode text entry (used when the camera is unavailable/denied).
  Future<void> _manualBarcodeEntry(BuildContext ctx) async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Enter barcode',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: positiveIntInput,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. 8901234567890',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.07),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF30D158),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Look up',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (code == null || code.isEmpty || !ctx.mounted) return;
    await _resolveBarcode(ctx, code);
  }

  /// Resolves a barcode → confirm/gram picker, or the manual gap-filler on a miss.
  Future<void> _resolveBarcode(BuildContext ctx, String code) async {
    // Brief blocking spinner — lookup hits cache (instant) or network (≤8s).
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF30D158))),
    );
    FoodApiResult? result;
    try {
      result = await FoodApiService.lookupByBarcode(code);
    } catch (_) {
      result = null;
    }
    if (!ctx.mounted) return;
    Navigator.pop(ctx); // dismiss spinner

    if (result != null) {
      _showGramPicker(ctx, result); // confirm card + quantity in one step
      return;
    }

    // Nothing matched anywhere → manual gap-fill with the barcode remembered.
    _startManualGapFill(barcode: code);
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text('No match for barcode $code — add it manually'),
      backgroundColor: const Color(0xFFFF9F0A),
      duration: const Duration(seconds: 3),
    ));
  }

  /// Reveals the custom-entry form for a permanent gap-fill. When [barcode] is
  /// given, the saved food is cached by that barcode (next scan is instant).
  void _startManualGapFill({String? barcode}) {
    setState(() {
      _pendingBarcode = barcode;
      _showCustom = true;
      if (barcode == null && _search.trim().isNotEmpty) {
        _nameCtrl.text = _search.trim(); // pre-fill the partial name
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (ctx, scrollCtrl) {
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Column(children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Text('Add Food',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const Spacer(),
                  // Backdate: pick the day this entry should be logged to.
                  DatePickerChip(
                    date: _selectedDate,
                    onChanged: (d) => setState(() => _selectedDate = d),
                  ),
                ],
              ),
            ),

            // Scan meal photo — AI camera path (only when the key is compiled in)
            if (GeminiVisionService.isConfigured)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      // Close the sheet, then scan from the still-valid root context.
                      final rootCtx =
                          Navigator.of(context, rootNavigator: true).context;
                      Navigator.pop(context);
                      startMealScan(rootCtx);
                    },
                    icon: const Icon(Icons.photo_camera_rounded, size: 18),
                    label: const Text('Scan meal photo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF30D158),
                      side: const BorderSide(color: Color(0xFF30D158)),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ),
            if (GeminiVisionService.isConfigured)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: ScanQuotaCaption(),
              ),

            // Meal type chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: MealType.values.map((mt) {
                  const labels = ['Breakfast', 'Lunch', 'Dinner', 'Snack'];
                  final sel = _selectedMeal == mt;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AppTappable(
                      onTap: () => setState(() => _selectedMeal = mt),
                      borderRadius: BorderRadius.circular(20),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: sel
                            ? const Color(0xFF30D158)
                            : Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(labels[mt.index],
                          style: TextStyle(
                            color: sel
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.6),
                            fontSize: 13,
                            fontWeight:
                                sel ? FontWeight.bold : FontWeight.normal,
                          )),
                    ),
                  );
                }).toList(),
              ),
            ),

            // Search bar + barcode scanner
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (v) {
                      // 200 ms debounce: avoids filtering on every keystroke
                      // (keyboard stutter on the 700+ curated+IFCT list) and
                      // auto-kicks the REMOTE (OFF+USDA) search once settled.
                      _searchDebounce?.cancel();
                      _searchDebounce =
                          Timer(const Duration(milliseconds: 200), () {
                        if (!mounted) return;
                        setState(() {
                          _search = v;
                          if (v != _lastOnlineQuery) {
                            _onlineResults = [];
                            _onlineError = null;
                            _searchingOnline = false;
                          }
                        });
                        // LOCAL shows instantly (above); REMOTE appends async.
                        if (v.trim().length >= 2) _searchOnline(context);
                      });
                    },
                    decoration: InputDecoration(
                      hintText: 'Search foods or scan a barcode…',
                      hintStyle:
                          TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                      prefixIcon: Icon(Icons.search,
                          color: Colors.white.withValues(alpha: 0.4)),
                      suffixIcon: _search.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear,
                                  color: Colors.white.withValues(alpha: 0.4),
                                  size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _search = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.07),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Barcode scanner button
                AppTappable(
                  onTap: () => _openScanner(context),
                  borderRadius: BorderRadius.circular(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF40C8E0).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: const Color(0xFF40C8E0).withValues(alpha: 0.4)),
                  ),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.qr_code_scanner_rounded,
                        color: Color(0xFF40C8E0), size: 22),
                  ),
                ),
              ]),
            ),

            // ── Favorites (pinned foods) ──
            if (_search.isEmpty) _favoritesRow(),

            // ── Recently scanned products ──
            if (_search.isEmpty) _recentScansRow(),

            // ── Recent foods (5 most recent unique food names logged today or ever) ──
            if (_search.isEmpty)
              _RecentFoodsRow(meal: _selectedMeal, date: _selectedDate),

            // Category tabs
            if (_search.isEmpty)
              SizedBox(
                height: 36,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: kFoodCategories.length,
                  itemBuilder: (_, i) {
                    final cat = kFoodCategories[i];
                    final sel = _selectedCategory == cat;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedCategory = cat),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? const Color(0xFF30D158).withValues(alpha: 0.2)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: sel
                                ? const Color(0xFF30D158)
                                : Colors.white.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Text(cat,
                            style: TextStyle(
                              color: sel
                                  ? const Color(0xFF30D158)
                                  : Colors.white.withValues(alpha: 0.55),
                              fontSize: 12,
                              fontWeight:
                                  sel ? FontWeight.bold : FontWeight.normal,
                            )),
                      ),
                    );
                  },
                ),
              ),

            // Custom entry
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: TextButton.icon(
                onPressed: () => setState(() => _showCustom = !_showCustom),
                icon: Icon(_showCustom ? Icons.expand_less : Icons.add,
                    size: 16, color: const Color(0xFF40C8E0)),
                label: Text(
                    _showCustom ? 'Hide custom entry' : 'Add custom food',
                    style: const TextStyle(
                        color: Color(0xFF40C8E0), fontSize: 12)),
              ),
            ),
            if (_showCustom)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(children: [
                  Expanded(
                      flex: 3,
                      child: _MiniField(ctrl: _nameCtrl, hint: 'Food name')),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _MiniField(
                          ctrl: _calCtrl,
                          hint: 'kcal',
                          keyboard: TextInputType.number)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _MiniField(
                          ctrl: _protCtrl,
                          hint: 'prot g',
                          keyboard: TextInputType.number)),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    onPressed: () => _addCustom(context),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF30D158),
                        padding: const EdgeInsets.all(12),
                        minimumSize: Size.zero),
                    child:
                        const Icon(Icons.check, color: Colors.white, size: 18),
                  ),
                ]),
              ),

            // Food list — browse (empty search) OR unified ranked search
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.only(bottom: 20),
                children: [
                  // ── Browse by category (empty search) ───────────────────
                  if (_search.isEmpty)
                    ..._browseItems.map((item) => ListTile(
                          leading: Text(item.emoji,
                              style: const TextStyle(fontSize: 22)),
                          title: Text(item.name,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14)),
                          subtitle: Text(
                            '${item.calories.toInt()} kcal · ${item.protein.toStringAsFixed(1)}g protein · ${item.serving}',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 11),
                          ),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            _starButton(item),
                            IconButton(
                              icon: const Icon(Icons.add_circle,
                                  color: Color(0xFF30D158)),
                              onPressed: () =>
                                  _showQuantityPicker(context, item),
                            ),
                          ]),
                        )),

                  // ── Unified ranked results (curated + IFCT + OFF + USDA) ──
                  if (_search.isNotEmpty) ...[
                    ..._unifiedResults.map(_unifiedTile),

                    // Loading — skeleton rows while REMOTE half is in flight.
                    if (_searchingOnline) const _OnlineSearchSkeleton(),

                    // Offline / network error — local results still show above.
                    if (_onlineError != null && !_searchingOnline)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                        child: Row(children: [
                          Icon(Icons.cloud_off_rounded,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.4)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_onlineError!,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: () => _searchOnline(context),
                            style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF40C8E0),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8)),
                            child: const Text('Retry'),
                          ),
                        ]),
                      ),

                    // Permanent gap-filler — nothing matched anywhere.
                    if (_search.trim().length >= 2 &&
                        _unifiedResults.isEmpty &&
                        !_searchingOnline)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(children: [
                          Text('No match for "${_search.trim()}"',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  fontSize: 13)),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _startManualGapFill,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add it manually'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF40C8E0),
                              side: const BorderSide(color: Color(0xFF40C8E0)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ]),
                      ),

                    if (_search.trim().length < 2 && _unifiedResults.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text('Type more to search…',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  fontSize: 13)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ]),
        );
      },
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

/// Shimmer placeholder shown while the online food search is in flight. Mirrors
/// the shape of the real result rows (icon + name + macro line + add button) so
/// the transition to real data is seamless.
class _OnlineSearchSkeleton extends StatelessWidget {
  const _OnlineSearchSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      enabled: true,
      child: Column(
        children: List.generate(
            4,
            (i) => ListTile(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF40C8E0).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  title: const Text('Online food item name',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: const Text(
                      '123 kcal · 12.0g prot · 20.0g carbs per 100g',
                      style: TextStyle(fontSize: 10)),
                  trailing:
                      const Icon(Icons.add_circle, color: Color(0xFF40C8E0)),
                )),
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return AppTappable(
      onTap: onTap,
      customBorder: const CircleBorder(),
      decoration: BoxDecoration(
        color: const Color(0xFF30D158).withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border:
            Border.all(color: const Color(0xFF30D158).withValues(alpha: 0.4)),
      ),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, color: const Color(0xFF30D158), size: 20),
      ),
    );
  }
}

class _NutCol extends StatelessWidget {
  final String label, value;
  final Color color;
  const _NutCol(
      {required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value,
          style: TextStyle(
              color: color, fontSize: 18, fontWeight: FontWeight.bold)),
      Text(label,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
    ]);
  }
}

class _MiniField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final TextInputType keyboard;
  const _MiniField(
      {required this.ctrl,
      required this.hint,
      this.keyboard = TextInputType.text});
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboard,
      // Numeric mini-fields (kcal, protein…) accept positive numbers only; the
      // text variant (food name) keeps free input.
      inputFormatters:
          keyboard == TextInputType.text ? null : positiveDecimalInput,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.35), fontSize: 12),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.07),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );
  }
}

// ── Labeled horizontal chip section (Favorites / Recently scanned) ────────────
class _ChipSection extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;
  const _ChipSection(
      {required this.label,
      required this.icon,
      required this.iconColor,
      required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 12, color: iconColor),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5)),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: children),
        const SizedBox(height: 8),
        const Divider(color: Color(0xFF2C2C2E), height: 1),
        const SizedBox(height: 4),
      ]),
    );
  }
}

// ── Recent foods row ──────────────────────────────────────────────────────────
// Shows the last 5 distinct food names logged across any day, as quick-add chips.
class _RecentFoodsRow extends StatelessWidget {
  final MealType meal;
  final DateTime date;
  const _RecentFoodsRow({required this.meal, required this.date});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    // Collect the most-recent logged ENTRY per distinct food name (newest first).
    // Re-adding works for ANY past food — DB items, custom entries, and
    // OpenFoodFacts results alike — because we replay the stored entry's own
    // calories/protein/macros rather than re-looking it up in the local DB.
    final seen = <String>{};
    final recents = <FoodEntry>[];
    final hist = p.foodHistory;
    final keys = hist.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final key in keys) {
      for (final e in (hist[key] ?? <FoodEntry>[])) {
        if (seen.add(e.name.toLowerCase())) recents.add(e);
        if (recents.length >= 5) break;
      }
      if (recents.length >= 5) break;
    }
    if (recents.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('RECENT',
            style: TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: recents.map((src) {
            return AppTappable(
              onTap: () {
                // Replay the stored entry into the current meal with a fresh id
                // and timestamp (UUID, not ms — avoids duplicate-key crashes).
                final messenger = ScaffoldMessenger.of(context);
                context.read<FitnessProvider>().addFoodEntry(
                    FoodEntry(
                      id: context.read<FitnessProvider>().newId(),
                      name: src.name,
                      calories: src.calories,
                      protein: src.protein,
                      carbs: src.carbs,
                      fat: src.fat,
                      macrosKnown: src.macrosKnown,
                      mealType: meal,
                      servingNote: src.servingNote,
                      timestamp: date,
                    ),
                    date: date);
                Navigator.pop(context);
                _foodSnack(messenger, 'Added ${src.name}',
                    duration: const Duration(seconds: 2));
              },
              borderRadius: BorderRadius.circular(20),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF3A3A3C)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.history_rounded,
                    size: 12, color: Color(0xFF8E8E93)),
                const SizedBox(width: 4),
                Text(src.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(width: 4),
                Text('${src.calories.round()}kcal',
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 11)),
              ]),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        const Divider(color: Color(0xFF2C2C2E), height: 1),
        const SizedBox(height: 4),
      ]),
    );
  }
}
