import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/meal_scan_result_screen.dart';
import '../theme/app_tokens.dart';
import 'gemini_vision_service.dart';
import 'haptics.dart';
import 'scan_quota.dart';

/// SharedPreferences flag: the user has agreed (once) to send meal photos to
/// the cloud vision provider for analysis. Gates [startMealScan].
const String _kPhotoConsentKey = 'meal_scan_photo_consent';

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
  try {
    shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 60, // compress for a fast, cheap upload
      maxWidth: 1280,
    );
  } catch (_) {
    if (context.mounted) _snack(context, "Couldn't open the camera.");
    return;
  }
  if (shot == null) return; // cancelled

  final bytes = await shot.readAsBytes();
  if (!context.mounted) return;

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
