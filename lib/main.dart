import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'providers/fitness_provider.dart';
import 'services/cloud_backup_service.dart';
import 'services/food_repository.dart';
import 'services/haptics.dart';
import 'services/meal_scan.dart';
import 'services/nav_router.dart';
import 'services/on_device_ai_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'theme/app_tokens.dart';
import 'widgets/brand_splash.dart';
import 'widgets/update_dialog.dart';
import 'widgets/heart_splash.dart';
import 'screens/home_screen.dart';
import 'screens/nutrition_screen.dart';
import 'screens/workout_screen.dart';
import 'screens/body_screen.dart';
import 'screens/history_screen.dart';
import 'screens/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Capture Flutter framework errors (widget build errors, assertion failures)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details); // show red screen in debug
    _appendCrashLog('FlutterError', details.exceptionAsString(),
        details.stack?.toString() ?? '');
  };

  // Capture uncaught async errors (Future exceptions, stream errors)
  runZonedGuarded(
    () async {
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF000000),
        systemNavigationBarIconBrightness: Brightness.light,
      ));

      // Warm the bundled offline Indian food source (IFCT 2017) into memory so
      // the Add-Food search has it ready. Fire-and-forget — failure is non-fatal
      // (curated DB + remote sources still work) and the Add-Food sheet re-awaits
      // it if startup hasn't finished loading.
      FoodRepository.instance.ensureLoaded();

      // Sweep leftover update APKs (~170 MB each) ~12 s after launch so the
      // cache never piles up — clears ALL stale kfit_*.apk, including any left
      // over from before this cleanup existed. Fire-and-forget, best-effort.
      Timer(const Duration(seconds: 12),
          () => UpdateService.cleanupCachedApks());

      final fitnessProvider = FitnessProvider()..loadData();

      // Cold-launch auto-backup: ~10 s in (and at most once/day), push a cloud
      // backup if GitHub cloud sync is configured and an account is set. Silent
      // and best-effort — never blocks startup or surfaces errors at launch.
      Timer(const Duration(seconds: 10), () async {
        final pushed = await CloudBackupService.instance
            .autoBackupIfDue(fitnessProvider.buildBackupJson);
        if (pushed) fitnessProvider.markBackedUp();
      });

      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: fitnessProvider),
            // lazy:true → service is only created the first time Settings or
            // Chat is opened. Defers model loading out of the cold-start window
            // so loadData() gets full CPU/IO priority at launch.
            ChangeNotifierProvider(
              lazy: true,
              create: (_) => OnDeviceAiService()..init(),
            ),
            ChangeNotifierProvider(create: (_) => NavRouter()),
          ],
          child: const KfitApp(),
        ),
      );
    },
    (error, stack) {
      _appendCrashLog('DartError', error.toString(), stack.toString());
    },
  );
}

/// Appends a crash entry to crash_log.txt in the app documents directory.
/// Exported via "Export Data" so users can share it when reporting bugs.
/// Fire-and-forget — never rethrows or crashes the app itself.
void _appendCrashLog(String type, String error, String stack) {
  getApplicationDocumentsDirectory().then((dir) {
    try {
      final file = File('${dir.path}/crash_log.txt');
      final ts = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$ts] [$type]\n$error\n$stack\n---\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // If log write fails, swallow — never crash inside an error handler.
    }
  }).catchError((_) {});
}

class KfitApp extends StatelessWidget {
  const KfitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'K Fitness',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Consumer<FitnessProvider>(
        builder: (context, p, _) {
          if (!p.isLoaded) return const _SplashScreen();
          if (p.isTampered) return const _TamperedBlockScreen();
          if (!p.onboardingDone) return const OnboardingScreen();
          return const MainNavigationScreen();
        },
      ),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) => const BrandSplash();
}

/// Terminal screen shown instead of the app when this build's signing
/// certificate doesn't match the official release (see
/// FitnessProvider.isTampered / IntegrityCheckService). Deliberately has no
/// way to continue past it — this can only ever trigger on a real CI-signed
/// release build whose certificate has since changed, i.e. a modified,
/// re-signed copy.
class _TamperedBlockScreen extends StatelessWidget {
  const _TamperedBlockScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.gpp_bad_outlined,
                    color: Color(0xFFFF453A), size: 56),
                SizedBox(height: 20),
                Text(
                  "This app can't be verified",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 12),
                Text(
                  "This install doesn't match the official release build, "
                  "so it won't run. If you didn't modify it yourself, "
                  're-download it from the official source.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Color(0xFF8E8E93), fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MainNavigationScreenState extends State<MainNavigationScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _index = 0;
  // One-shot launch greeting, shown once per launch for a matching profile.
  bool _showHeart = false;
  // Suppress the greeting whenever the update dialog is on screen.
  bool _updateDialogVisible = false;

  // Drives a quick fade-through of the active tab on switch. IndexedStack keeps
  // every screen mounted (state + correct offstage semantics); this just fades
  // the newly-shown one in.
  late final AnimationController _tabFade;

  // Widget-tap routing.
  StreamSubscription<Uri?>? _widgetClickSub;
  NavRouter? _navRouter;
  VoidCallback? _navRouterListener;

  // ignore: unused_field — Dart lint doesn't recognise ?.cancel() as a "use"
  Timer? _updateCheckTimer;

  final List<Widget> _screens = const [
    HomeScreen(),
    NutritionScreen(),
    WorkoutScreen(),
    BodyScreen(),
    HistoryScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabFade = AnimationController(
        vsync: this, duration: AppDurations.normal, value: 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initWidgetRouting();
      // One-shot launch greeting, gated on the profile name and skipped under
      // reduce-motion. No-op for every other profile.
      if (!mounted) return;
      final name = context.read<FitnessProvider>().userName.trim().toLowerCase();
      if (name == 'jaswini' && !MediaQuery.of(context).disableAnimations) {
        setState(() => _showHeart = true);
      }
    });
    // Delay the update check so it doesn't compete with loadData() and AI init
    // during the critical first few seconds. 4 s is enough for loadData() to
    // finish its 60-day JSON parse; the update dialog has no urgency.
    // Stored so dispose() can cancel it and tests don't leak pending timers.
    _updateCheckTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _checkForUpdate();
    });
  }

  void _initWidgetRouting() {
    if (!mounted) return;

    // NavRouter is always provided in production (see MultiProvider in main()).
    // Focused widget tests may build this screen without it — skip widget-tap
    // routing gracefully in that case instead of throwing.
    final NavRouter router;
    try {
      router = context.read<NavRouter>();
    } catch (_) {
      return;
    }

    // Register NavRouter listener — when the router fires, jump to its tab.
    _navRouter = router;
    _navRouterListener = () {
      if (!mounted) return;
      setState(() => _index = router.tabIndex);
    };
    router.addListener(_navRouterListener!);

    // Handle warm-launch taps (app already running).
    _widgetClickSub = HomeWidget.widgetClicked.listen((Uri? uri) {
      if (!mounted) return;
      context.read<NavRouter>().open(uri?.host ?? 'home');
    }, onError: (_) {/* platform channel hiccup — ignore */});

    // Handle cold-launch taps (app started from widget tap).
    HomeWidget.initiallyLaunchedFromHomeWidget().then((Uri? uri) {
      if (!mounted) return;
      if (uri != null) {
        context.read<NavRouter>().open(uri.host.isEmpty ? 'home' : uri.host);
      }
    }).catchError((_) {/* plugin unavailable (e.g. in tests) — ignore */});
  }

  Future<void> _checkForUpdate() async {
    if (!mounted) return;
    final provider = context.read<FitnessProvider>();
    if (!provider.autoUpdateCheck) return;

    try {
      final pkgInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(pkgInfo.buildNumber) ?? 0;
      if (currentBuild == 0) return;

      final service = UpdateService();
      final info = await service.checkForUpdate(currentBuild);
      if (info == null) {
        // Already on the latest — purge any leftover downloaded installer.
        await UpdateService.cleanupCachedApks();
        return;
      }

      // Suppress only for the exact build the user already snoozed/started —
      // a newer release always prompts, even mid-snooze. The downloaded file (if
      // any) is kept so "Later" doesn't cost a re-download.
      if (provider.shouldSuppressUpdateFor(info.build)) return;

      // Auto-download in the background: if a prior download already finished,
      // offer Install straight away; otherwise fetch (resuming any partial) and
      // prompt once it's ready. The app stays usable throughout, and closing it
      // mid-download just resumes on the next launch.
      var ready = await service.readyApk(info.build, expectedBytes: info.sizeBytes);
      if (ready == null) {
        try {
          ready = await service.downloadApk(info);
        } catch (_) {
          return; // network hiccup — resumes next launch
        }
      }
      if (!mounted) return;

      // Keep the launch greeting out of the update flow.
      setState(() => _updateDialogVisible = true);
      try {
        await showUpdateDialog(context, info, service, readyFile: ready);
      } finally {
        if (mounted) setState(() => _updateDialogVisible = false);
      }
    } catch (_) {
      // Never crash the app on update check failure.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabFade.dispose();
    _widgetClickSub?.cancel();
    _updateCheckTimer?.cancel();
    if (_navRouterListener != null) {
      _navRouter?.removeListener(_navRouterListener!);
    }
    super.dispose();
  }

  void _onTabTap(int i) {
    if (i == _index) return;
    Haptics.selection();
    setState(() => _index = i);
    if (reduceMotion(context)) {
      _tabFade.value = 1;
    } else {
      _tabFade.forward(from: 0);
    }
  }

  /// Refresh data when the app returns to the foreground.
  /// Within the same calendar day the data is already current in memory, so
  /// a full reload (60-day JSON re-parse + prefs scan) is wasteful and makes
  /// the resume feel sluggish. We only do a full reload when the date has
  /// advanced since the last load (midnight crossover while backgrounded).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final provider = context.read<FitnessProvider>();
      if (provider.dateChanged) provider.loadData();
      // Recover a meal photo captured if Android killed us while the camera was
      // open (low-memory). No-op unless a scan was actually in flight — fixes
      // "take a pic, nothing happens, works the second time".
      recoverLostMealScan(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Frosted-glass nav: `extendBody` lets content scroll *under* the bar so
      // the BackdropFilter has something to blur (without it there's only black
      // behind the bar and the blur is invisible). This was reverted once (#53)
      // because bottom-anchored controls got tucked under the nav — every screen
      // now pads its bottom content by MediaQuery.padding.bottom (which, with
      // extendBody on, reports the nav's height) so nothing is occluded.
      extendBody: true,
      // IndexedStack keeps all tabs mounted (scroll positions, sub-tab
      // selections, Home's entrance animation) and offstage-hides the inactive
      // ones; the FadeTransition fades the active tab in on each switch.
      // HapticScroll (one listener for the whole app) gives a subtle edge tick
      // when any tab's scroll view hits its top/bottom boundary.
      body: HapticScroll(
        child: Stack(children: [
        FadeTransition(
          opacity: _tabFade,
          child: IndexedStack(index: _index, children: _screens),
        ),
        // Gated launch greeting. IgnorePointer so it never traps taps; it
        // auto-dismisses after ~3s via onDone.
        if (_showHeart && !_updateDialogVisible)
          Positioned.fill(
            child: IgnorePointer(
              child: HeartSplash(
                onDone: () {
                  if (mounted) setState(() => _showHeart = false);
                },
              ),
            ),
          ),
      ])),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Translucent so the blurred content shows through the bar.
              color: AppColors.navBackground.withValues(alpha: 0.80),
              border: const Border(
                top: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: BottomNavigationBar(
              backgroundColor: Colors.transparent,
              currentIndex: _index,
              onTap: _onTabTap,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.house_outlined, size: 24),
                  activeIcon: Icon(Icons.house_rounded, size: 24),
                  label: 'Summary',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.restaurant_menu_outlined, size: 24),
                  activeIcon: Icon(Icons.restaurant_menu_rounded, size: 24),
                  label: 'Nutrition',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.fitness_center_outlined, size: 24),
                  activeIcon: Icon(Icons.fitness_center_rounded, size: 24),
                  label: 'Workout',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline_rounded, size: 24),
                  activeIcon: Icon(Icons.person_rounded, size: 24),
                  label: 'Body',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.history_outlined, size: 24),
                  activeIcon: Icon(Icons.history_rounded, size: 24),
                  label: 'History',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
