import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/services/on_device_ai_service.dart';
import 'package:kfit/screens/home_screen.dart';
import 'package:kfit/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI Coach disable toggle: a Settings switch (persisted as 'ai_coach_enabled')
/// that fully hides the AI Coach from Home and collapses its sub-tiles/chat
/// entry in Settings. Defaults to ON for backward compatibility.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('provider — aiCoachEnabled persistence', () {
    test('defaults to true on a fresh install', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      addTearDown(p.dispose);
      await p.loadData();
      expect(p.aiCoachEnabled, isTrue);
    });

    test('loadData persists the default so it appears in backups', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      addTearDown(p.dispose);
      await p.loadData();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ai_coach_enabled'), isTrue);
    });

    test('saveAiCoachEnabled(false) persists and survives reload', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FitnessProvider();
      addTearDown(p.dispose);
      await p.loadData();

      await p.saveAiCoachEnabled(false);
      expect(p.aiCoachEnabled, isFalse);

      final p2 = FitnessProvider();
      addTearDown(p2.dispose);
      await p2.loadData();
      expect(p2.aiCoachEnabled, isFalse);
    });

    test('honours an explicitly disabled stored value', () async {
      SharedPreferences.setMockInitialValues({'ai_coach_enabled': false});
      final p = FitnessProvider();
      addTearDown(p.dispose);
      await p.loadData();
      expect(p.aiCoachEnabled, isFalse);
    });
  });

  group('UI — Home + Settings honour the toggle', () {
    Future<FitnessProvider> seeded({required bool aiEnabled}) async {
      SharedPreferences.setMockInitialValues({
        'onboarding_done': true,
        'user_name': 'Test',
        'ai_coach_enabled': aiEnabled,
      });
      final p = FitnessProvider();
      await p.loadData();
      return p;
    }

    Future<void> pump(WidgetTester tester, Widget child, FitnessProvider p) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Unmount at teardown so the provider day-reset timer + Home's refresh
      // timer are disposed before the pending-timer check.
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));

      final ai = OnDeviceAiService();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<FitnessProvider>(create: (_) => p, lazy: false),
          ChangeNotifierProvider<OnDeviceAiService>(create: (_) => ai, lazy: false),
        ],
        child: MaterialApp(home: child),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('Home shows the coach when enabled', (tester) async {
      // The ChangeNotifierProvider owns p and disposes it on unmount — so we
      // deliberately do NOT call p.dispose() here (that would double-dispose).
      final p = await seeded(aiEnabled: true);
      await pump(tester, const HomeScreen(), p);
      expect(find.text('Ask Coach'), findsOneWidget);
    });

    testWidgets('Home hides the coach when disabled', (tester) async {
      final p = await seeded(aiEnabled: false);
      await pump(tester, const HomeScreen(), p);
      expect(find.text('Ask Coach'), findsNothing);
      expect(find.text('COACH'), findsNothing);
    });

    testWidgets('Settings always shows the enable toggle; sub-tiles collapse when off',
        (tester) async {
      final p = await seeded(aiEnabled: false);
      await pump(tester, const SettingsScreen(), p);
      expect(find.text('Enable Coach'), findsOneWidget);
      // Auto-load sub-tile is gated behind the enable flag.
      expect(find.text('Load coach at app start'), findsNothing);
    });

    testWidgets('Settings shows sub-tiles when enabled', (tester) async {
      final p = await seeded(aiEnabled: true);
      await pump(tester, const SettingsScreen(), p);
      expect(find.text('Enable Coach'), findsOneWidget);
      expect(find.text('Load coach at app start'), findsOneWidget);
    });
  });
}
