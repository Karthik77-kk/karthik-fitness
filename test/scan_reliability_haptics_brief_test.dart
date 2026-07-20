import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/services/haptics.dart';
import 'package:kfit/services/meal_scan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─── Dynamic scroll haptics ───────────────────────────────────────────────
  // HapticScroll now ticks WHILE dragging (a light selection tick every ~42 px),
  // not only at the boundary. Verify a drag produces at least one tick and the
  // global toggle silences it.
  group('HapticScroll dynamic ticks', () {
    tearDown(() => Haptics.enabled = true); // never leak a disabled flag

    Widget host() => MaterialApp(
          home: Scaffold(
            body: HapticScroll(
              child: ListView(
                children: [
                  for (var i = 0; i < 50; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
            ),
          ),
        );

    testWidgets('a drag fires scroll ticks; disabling silences them',
        (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') calls.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      Haptics.enabled = true;
      await tester.pumpWidget(host());
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(calls, isNotEmpty); // dragging produced haptic feedback

      calls.clear();
      Haptics.enabled = false;
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(calls, isEmpty); // the Settings toggle silences scroll haptics
    });
  });

  // ─── Daily brief manual refresh ───────────────────────────────────────────
  group('forceRefreshDailyBrief', () {
    test('no-ops safely when cloud AI is not configured', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      await p.loadData();
      expect(p.dailyBrief, isNull);
      // No GEMINI key is compiled into the test build, so this must return
      // without a network call and without throwing.
      await p.forceRefreshDailyBrief();
      expect(p.dailyBrief, isNull);
    });
  });

  // ─── Lost meal-scan recovery guard ────────────────────────────────────────
  group('recoverLostMealScan', () {
    testWidgets('no-ops (no throw, no navigation) when nothing is pending',
        (tester) async {
      SharedPreferences.setMockInitialValues({}); // no pending-scan marker
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold(body: Text('home'));
        }),
      ));

      await recoverLostMealScan(ctx);
      await tester.pumpAndSettle();

      // Still on the same page — no results route was pushed.
      expect(find.text('home'), findsOneWidget);
    });
  });
}
