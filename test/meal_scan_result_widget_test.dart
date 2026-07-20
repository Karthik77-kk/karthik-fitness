import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/screens/meal_scan_result_screen.dart';
import 'package:kfit/services/gemini_vision_service.dart';

Widget _host(FitnessProvider p, List<ScannedFood> foods) {
  // Provider ABOVE MaterialApp so the pushed results route can read it.
  return ChangeNotifierProvider<FitnessProvider>.value(
    value: p,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => MealScanResultScreen(foods: foods))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openResults(WidgetTester t, FitnessProvider p,
    List<ScannedFood> foods) async {
  await t.pumpWidget(_host(p, foods));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  const sample = [
    ScannedFood(
        name: 'Dosa',
        grams: 120,
        kcal: 168,
        protein: 4,
        carbs: 30,
        fat: 3,
        confidence: 0.8),
    ScannedFood(
        name: 'Sambar',
        grams: 100,
        kcal: 90,
        protein: 4,
        carbs: 12,
        fat: 2,
        confidence: 0.6),
  ];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders foods, total, and switches meal', (t) async {
    final p = FitnessProvider();
    await _openResults(t, p, sample);

    expect(find.text('Dosa'), findsOneWidget);
    expect(find.text('Sambar'), findsOneWidget);
    expect(find.textContaining('258'), findsWidgets); // 168 + 90 total kcal

    // change the target meal
    await t.tap(find.text('Breakfast'));
    await t.pumpAndSettle();
    expect(find.text('Breakfast'), findsOneWidget);
  });

  testWidgets('removing a row drops it', (t) async {
    final p = FitnessProvider();
    await _openResults(t, p, sample);

    expect(find.byIcon(Icons.close_rounded), findsNWidgets(2));
    await t.tap(find.byIcon(Icons.close_rounded).first);
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.close_rounded), findsNWidgets(1));
  });

  testWidgets('food-DB search opens and picks an item', (t) async {
    final p = FitnessProvider();
    await _openResults(t, p, sample);

    await t.tap(find.byIcon(Icons.search_rounded).first);
    await t.pumpAndSettle();
    expect(find.text('Search food database…'), findsOneWidget);
    // tap the first DB result → sheet closes, row updated
    await t.tap(find.byType(ListTile).first);
    await t.pumpAndSettle();
    expect(find.text('Search food database…'), findsNothing);
  });

  testWidgets('Add logs all items to the provider', (t) async {
    final p = FitnessProvider();
    await _openResults(t, p, sample);

    expect(p.todayFood, isEmpty);
    await t.tap(find.textContaining('Add 2 items'));
    await t.pumpAndSettle();
    expect(p.todayFood.length, 2);
  });

  testWidgets('portion chip rescales grams and macros from the AI estimate',
      (t) async {
    final p = FitnessProvider();
    await _openResults(t, p, sample);

    // Dosa starts at the AI's 120 g / 168 kcal, so "1×" is the selected chip.
    expect(find.text('120'), findsOneWidget);
    expect(find.text('168'), findsOneWidget);

    // Tap "2×" on the first row → 120 g doubles to 240 g and macros scale with
    // it (168 → 336 kcal). This is the one-tap depth/quantity correction.
    await t.tap(find.text('2×').first);
    await t.pumpAndSettle();
    expect(find.text('240'), findsOneWidget); // grams doubled
    expect(find.text('336'), findsOneWidget); // kcal doubled

    // Sambar (second row) is untouched.
    expect(find.text('100'), findsOneWidget);
  });
}
