import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/meal_scan_result_screen.dart';
import '../theme/app_tokens.dart';
import 'gemini_vision_service.dart';
import 'haptics.dart';
import 'nav_router.dart';
import 'scan_quota.dart';

/// SharedPreferences flag: the user has agreed (once) to send meal photos to
/// the cloud vision provider for analysis. Gates [startMealScan].
const String _kPhotoConsentKey = 'meal_scan_photo_consent';

/// SharedPreferences flag set while the camera is open for a scan. If Android
/// reclaims memory while the camera is foregrounded (common on mid-range phones,
/// or with "Don't keep activities" on) it may destroy just our Activity — or the
/// WHOLE process. Either way the picked photo is delivered to a freshly
/// recreated Activity and the original `pickImage` await never completes — the
/// scan silently dies and the user lands back on Home. This marker (persisted, so
/// it survives a full process death) lets [recoverLostMealScan] retrieve that
/// lost photo on the next resume OR cold launch and finish the scan. It's the
/// reason "take a pic → nothing happens → works the second time" occurs.
const String _kPendingScanKey = 'meal_scan_pending';

/// Guards [recoverLostMealScan] against re-entrancy: after a process kill the
/// cold-start recovery (from `initState`) and a `resumed` lifecycle event can
/// both fire within the same launch. Whichever runs first consumes the pending
/// photo; the other must no-op instead of double-analysing it.
bool _recovering = false;

/// "Scan meal" entry point used by both buttons on the Food page.
/// Flow: quota check → one-time privacy consent → camera capture → Gemini
/// analysis → editable results.
Future<void> startMealScan(BuildContext context) async {
  if (!GeminiVisionService.isConfigured) {
    _snack(context, "AI photo scan isn't available in this build.");
    return;
  }
  final prefs = await SharedPreferences.getInstance();

  if (!ScanQuota.canScan(prefs)) {
    Haptics.warning();
    if (context.mounted) _showExhausted(context);
    return;
  }

  // One-time disclosure: the photo leaves the device for cloud analysis.
  if (!context.mounted) return;
  final consented = await _ensurePhotoConsent(context, prefs);
  if (!consented) return;

  Haptics.tap();
  XFile? shot;
  // Mark a scan in flight so a low-memory Activity kill while the camera is open
  // is recoverable on resume (see [_kPendingScanKey] / [recoverLostMealScan]).
  await prefs.setBool(_kPendingScanKey, true);
  try {
    shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 60, // compress for a fast, cheap upload
      maxWidth: 1280,
    );
  } catch (_) {
    await prefs.setBool(_kPendingScanKey, false);
    if (context.mounted) _snack(context, "Couldn't open the camera.");
    return;
  }
  // We got here => our Activity survived the camera; nothing to recover later.
  await prefs.setBool(_kPendingScanKey, false);
  if (shot == null) return; // cancelled

  final bytes = await shot.readAsBytes();
  if (!context.mounted) return;
  await _analyzeAndShow(context, bytes, prefs);
}

/// Recovers a meal photo captured while Android had killed our Activity — or the
/// whole process — with the camera foregrounded, then finishes the scan as if
/// the pick had returned normally. Call it BOTH on app resume and on cold launch:
/// a warm Activity recreation delivers a `resumed` event, but a full process
/// death cold-starts the app with no `resumed`, so the launch call is what fixes
/// "press OK → land on Home". It no-ops unless a scan was actually in flight, so
/// it's cheap to call every launch/resume.
Future<void> recoverLostMealScan(BuildContext context) async {
  if (_recovering) return; // one recovery per launch; see [_recovering]
  _recovering = true;
  try {
    if (!GeminiVisionService.isConfigured) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kPendingScanKey) ?? false)) return;
    // Consume the marker up-front so a second resume can't double-trigger.
    await prefs.setBool(_kPendingScanKey, false);

    final LostDataResponse resp;
    try {
      resp = await ImagePicker().retrieveLostData();
    } catch (_) {
      return; // platform without lost-data support, or nothing pending
    }
    final file = resp.file;
    if (file == null) return; // user cancelled the camera, or nothing to recover

    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    // Recovery runs on cold start / resume where the app is sitting on the Home
    // tab (the scan's Activity was killed), so the progress dialog and results
    // would otherwise appear over Home. Jump to the Food section first so the
    // whole flow lands where the user actually started the scan.
    try {
      Provider.of<NavRouter>(context, listen: false).open('food');
    } catch (_) {
      // NavRouter not in the tree (focused widget tests) — routing is optional.
    }
    await _analyzeAndShow(context, bytes, prefs);
  } finally {
    _recovering = false;
  }
}

/// Shared tail of the scan pipeline: upload [bytes] to the vision service, show
/// the progress dialog, then open the editable results (or a helpful snack).
/// Used by both the normal pick and the lost-data recovery path.
Future<void> _analyzeAndShow(
    BuildContext context, Uint8List bytes, SharedPreferences prefs) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _AnalyzingDialog(),
  );

  List<ScannedFood> foods;
  try {
    foods = await GeminiVisionService.analyze(bytes);
  } on GeminiException catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    if (context.mounted) _snack(context, e.message);
    return;
  } catch (_) {
    if (context.mounted) Navigator.of(context).pop();
    if (context.mounted) _snack(context, 'Analysis failed. Please try again.');
    return;
  }
  if (context.mounted) Navigator.of(context).pop(); // close progress

  if (foods.isEmpty) {
    Haptics.warning();
    if (context.mounted) {
      _snack(context, 'No food detected — try a clearer, closer photo.');
    }
    return;
  }

  // Only a genuinely successful analysis burns a credit.
  await ScanQuota.record(prefs);
  Haptics.success();

  if (!context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => MealScanResultScreen(foods: foods)),
  );
}

/// Shows the one-time privacy consent sheet if the user hasn't agreed yet.
/// Returns true when it's OK to proceed (already agreed, or agreed just now),
/// false when the user cancels. The decision is persisted so it's asked once.
Future<bool> _ensurePhotoConsent(
    BuildContext context, SharedPreferences prefs) async {
  if (prefs.getBool(_kPhotoConsentKey) ?? false) return true;

  final agreed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface3,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 18),
          Row(children: const [
            Icon(Icons.privacy_tip_outlined, color: AppColors.blue, size: 22),
            SizedBox(width: 10),
            Expanded(child: Text('Before you scan', style: AppText.title)),
          ]),
          const SizedBox(height: 12),
          const Text(
            'To identify your food, the photo you take is sent to Google\'s '
            'Gemini vision service for analysis. Nothing else — your logs, '
            'weight or profile — is shared, and photos aren\'t stored by the '
            'app. You can add food manually instead at any time.',
            style: TextStyle(color: AppColors.muted, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  Haptics.selection();
                  Navigator.pop(ctx, false);
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: AppRadii.rMd),
                ),
                child: const Text('Cancel',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  Haptics.tap();
                  Navigator.pop(ctx, true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: AppRadii.rMd),
                ),
                child: const Text('Allow',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ],
      ),
    ),
  );

  if (agreed == true) {
    await prefs.setBool(_kPhotoConsentKey, true);
    return true;
  }
  return false;
}

/// A small caption showing how many AI scans remain today ("N scan(s) left
/// today"). Reads the per-day counter from SharedPreferences; refreshes whenever
/// the sheet it lives in is rebuilt (re-opened after a scan).
class ScanQuotaCaption extends StatelessWidget {
  const ScanQuotaCaption({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snap) {
        final prefs = snap.data;
        if (prefs == null) return const SizedBox.shrink();
        final left = ScanQuota.remaining(prefs);
        return Text('$left scan${left == 1 ? '' : 's'} left today',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 11));
      },
    );
  }
}

void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(
      SnackBar(content: Text(m), backgroundColor: AppColors.surface2),
    );

void _showExhausted(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.surface3,
      title: const Text("You've used today's scans"),
      content: Text(
        'AI meal scan is limited to ${ScanQuota.dailyLimit} photos per day. '
        'Your credits reset tomorrow — meanwhile you can still add food manually.',
        style: const TextStyle(color: AppColors.muted, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Got it', style: TextStyle(color: AppColors.green)),
        ),
      ],
    ),
  );
}

class _AnalyzingDialog extends StatelessWidget {
  const _AnalyzingDialog();
  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      backgroundColor: AppColors.surface3,
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: AppColors.green),
          ),
          SizedBox(width: 16),
          Flexible(child: Text('Analysing your meal…')),
        ],
      ),
    );
  }
}
