import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/screens/copy_yesterday_sheet.dart';

String _yKey() {
  final y = DateTime.now().subtract(const Duration(days: 1));
  return '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
}

Map<String, Object> _seedYesterday(List<Map<String, dynamic>> entries) =>
    {'food_${_yKey()}': jsonEncode(entries)};

Map<String, dynamic> _entry({
  required String id,
  required String name,
  required double kcal,
  double protein = 5,
  double carbs = 20,
  double fat = 3,
  int meal = 1,
}) =>
    {
      'id': id,
      'name': name,
      'calories': kcal,
      'protein': protein,
      'carbs': carbs,
      'fat': fat,
      'mealType': meal,
      'timestamp': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
      'servingNote': 'note',
      'macrosKnown': true,
    };

Future<FitnessProvider> _load(WidgetTester tester) async {
  final p = FitnessProvider();
  await p.loadData();
  return p;
}

/// Unmount the tree and dispose the provider WITHIN the test body — loadData
/// starts a periodic day-reset timer and SnackBars schedule dismiss timers; both
/// must be cleared before the body ends or the framework flags a pending timer.
Future<void> _close(WidgetTester tester, FitnessProvider p) async {
  await tester.pumpWidget(const SizedBox.shrink());
  p.dispose();
}

Widget _host(FitnessProvider p) => ChangeNotifierProvider<FitnessProvider>.value(
      value: p,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showCopyYesterdaySheet(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('sheet lists yesterday\'s items for review', (tester) async {
    SharedPreferences.setMockInitialValues(_seedYesterday([
      _entry(id: 'a', name: 'Masala Dosa', kcal: 400),
      _entry(id: 'b', name: 'Filter Coffee', kcal: 90),
    ]));
    final p = await _load(tester);
    await tester.pumpWidget(_host(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Copy yesterday\'s meals'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Masala Dosa'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Filter Coffee'), findsOneWidget);
    // Running total in the CTA (400 + 90).
    expect(find.textContaining('490 kcal'), findsWidgets);
    await _close(tester, p);
  });

  testWidgets('Add to today logs every reviewed item to today', (tester) async {
    SharedPreferences.setMockInitialValues(_seedYesterday([
      _entry(id: 'a', name: 'Masala Dosa', kcal: 400),
      _entry(id: 'b', name: 'Filter Coffee', kcal: 90),
    ]));
    final p = await _load(tester);
    expect(p.todayCalories, 0);

    await tester.pumpWidget(_host(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Add 2 items to today'));
    await tester.pumpAndSettle();

    expect(p.todayCalories, closeTo(490, 0.01));
    expect(find.byType(TextField), findsNothing); // sheet closed
    await _close(tester, p);
  });

  testWidgets('removing an item excludes it from the copy', (tester) async {
    SharedPreferences.setMockInitialValues(_seedYesterday([
      _entry(id: 'a', name: 'Masala Dosa', kcal: 400),
      _entry(id: 'b', name: 'Filter Coffee', kcal: 90),
    ]));
    final p = await _load(tester);
    await tester.pumpWidget(_host(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Remove the coffee via its X button (second remove icon).
    await tester.tap(find.byTooltip('Remove').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Filter Coffee'), findsNothing);

    await tester.tap(find.textContaining('Add 1 item to today'));
    await tester.pumpAndSettle();
    expect(p.todayCalories, closeTo(400, 0.01)); // only the dosa
    await _close(tester, p);
  });

  testWidgets('editing a macro updates the running total', (tester) async {
    SharedPreferences.setMockInitialValues(_seedYesterday([
      _entry(id: 'a', name: 'Rice', kcal: 200),
    ]));
    final p = await _load(tester);
    await tester.pumpWidget(_host(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The KCAL field currently holds 200; change it to 350.
    final kcalField = find.widgetWithText(TextField, '200');
    expect(kcalField, findsOneWidget);
    await tester.enterText(kcalField, '350');
    await tester.pump();
    expect(find.textContaining('350 kcal'), findsWidgets);

    await tester.tap(find.textContaining('Add 1 item to today'));
    await tester.pumpAndSettle();
    expect(p.todayCalories, closeTo(350, 0.01));
    await _close(tester, p);
  });
}
