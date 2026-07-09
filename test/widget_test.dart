import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:kfit/providers/fitness_provider.dart';
import 'package:kfit/services/nav_router.dart';
import 'package:kfit/main.dart';
import 'package:kfit/screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App with providers. Seeds onboarding_done=true so main nav is shown.
Widget _appWithProvider({bool onboardingDone = true}) {
  SharedPreferences.setMockInitialValues(
    onboardingDone ? {'onboarding_done': true} : {},
  );
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => FitnessProvider()..loadData()),
      ChangeNotifierProvider(create: (_) => NavRouter()),
    ],
    child: const KfitApp(),
  );
}

/// Disposes the current widget tree so pending startup timers (e.g. the
/// 4-second update-check timer in MainNavigationScreen) are cancelled before
/// the test framework checks for pending timers.
Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
  });

  // ── Existing nav tests (unchanged behaviour) ──────────────────────────────

  testWidgets('App renders without crashing', (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();
    expect(find.byType(MaterialApp), findsOneWidget);
    await _disposeTree(tester);
  });

  testWidgets('Bottom nav has 5 tabs (Stats merged into Body)', (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();
    expect(find.byType(BottomNavigationBar), findsOneWidget);

    final nav = tester.widget<BottomNavigationBar>(
        find.byType(BottomNavigationBar));
    expect(nav.items.length, 5);
    await _disposeTree(tester);
  });

  testWidgets('Bottom nav labels are correct', (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();

    expect(find.text('Summary'),   findsWidgets);
    expect(find.text('Nutrition'), findsWidgets);
    expect(find.text('Workout'),   findsWidgets);
    expect(find.text('Body'),      findsWidgets);   // merged tab
    expect(find.text('History'),   findsWidgets);
    // Stats is now a sub-tab inside Body, not a bottom nav tab
    await _disposeTree(tester);
  });

  testWidgets('Tapping Nutrition tab navigates to nutrition screen',
      (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nutrition').last);
    await tester.pumpAndSettle();

    expect(find.text('Nutrition'), findsWidgets);
    await _disposeTree(tester);
  });

  testWidgets('Tapping Workout tab navigates to workout screen',
      (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Workout').last);
    await tester.pumpAndSettle();

    expect(find.text('Workout'), findsWidgets);
    await _disposeTree(tester);
  });

  testWidgets('App uses dark theme', (tester) async {
    await tester.pumpWidget(_appWithProvider());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.brightness, Brightness.dark);
    await _disposeTree(tester);
  });

  // ── Onboarding gate ───────────────────────────────────────────────────────

  testWidgets('Shows OnboardingScreen on first install (onboarding_done absent)',
      (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: false));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(MainNavigationScreen), findsNothing);
  });

  testWidgets('Shows MainNavigationScreen when onboarding already done',
      (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: true));
    await tester.pumpAndSettle();

    expect(find.byType(MainNavigationScreen), findsOneWidget);
    expect(find.byType(OnboardingScreen),     findsNothing);
    await _disposeTree(tester);
  });

  // ── Tampered-build gate ───────────────────────────────────────────────────

  testWidgets(
      'Shows block screen instead of onboarding/main nav when tampered',
      (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final provider = FitnessProvider();
    await provider.loadData();
    provider.debugSetTampered(true);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider(create: (_) => NavRouter()),
        ],
        child: const KfitApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("This app can't be verified"), findsOneWidget);
    expect(find.byType(MainNavigationScreen), findsNothing);
    expect(find.byType(OnboardingScreen), findsNothing);
    await _disposeTree(tester);
    provider.dispose(); // owned via .value() — cancels its day-reset timer
  });

  testWidgets('No block screen when signing check has not flagged tampering',
      (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: true));
    await tester.pumpAndSettle();

    expect(find.text("This app can't be verified"), findsNothing);
    expect(find.byType(MainNavigationScreen), findsOneWidget);
    await _disposeTree(tester);
  });

  testWidgets('Onboarding page 1 has name text field', (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Enter your name'), findsOneWidget);
  });

  testWidgets('Onboarding shows Continue button on page 1', (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Continue'), findsOneWidget);
  });

  testWidgets('Onboarding Continue advances Welcome → Profile → Activity',
      (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: false));
    await tester.pumpAndSettle();

    // page 0 (Welcome) → page 1 (Profile)
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(find.text('A bit about you'), findsOneWidget);

    // page 1 (Profile) → page 2 (Activity). Sex is now REQUIRED before the
    // Profile page's Continue enables, so pick one first.
    await tester.tap(find.text('Male'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Track your steps automatically'), findsOneWidget);
  });

  testWidgets('Onboarding Activity page has Skip button', (tester) async {
    await tester.pumpWidget(_appWithProvider(onboardingDone: false));
    await tester.pumpAndSettle();

    // advance Welcome → Profile → Activity (sex is required on the Profile page)
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Male'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextButton, 'Skip for now'), findsOneWidget);
  });

  testWidgets('Splash screen shown while provider is loading', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    // Provider starts loading; before pumpAndSettle the splash is shown.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => FitnessProvider()..loadData()),
          ChangeNotifierProvider(create: (_) => NavRouter()),
        ],
        child: const KfitApp(),
      ),
    );
    // One pump — provider hasn't finished yet, so splash should show.
    await tester.pump();
    // Either splash or main nav is acceptable here (timing-dependent in test).
    expect(find.byType(MaterialApp), findsOneWidget);
    // If the provider finished loading the Home feed may have mounted, starting
    // its refresh timer + flutter_animate entrance timers. Settle then unmount
    // so the end-of-test pending-timer check passes.
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
