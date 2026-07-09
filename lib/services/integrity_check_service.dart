import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Detects whether the running APK was re-signed with a different key than
/// the official release — e.g. someone decompiled it, modified it, and
/// re-signed it with their own key before redistributing it. Blocks app
/// startup when this is detected (see main.dart) — a determined reverse
/// engineer could still patch this check out of a modified copy, but it
/// stops a re-signed APK from silently passing as the real thing.
///
/// The expected fingerprint is computed in CI from the real release
/// keystore and baked in via --dart-define=EXPECTED_SIGNING_SHA256. Local/
/// debug builds don't set it, so the check is a no-op there — it can only
/// ever fire on a real CI-signed release build.
class IntegrityCheckService {
  static const _channel = MethodChannel('com.kfitness/integrity');
  static const _expectedSha256 = String.fromEnvironment('EXPECTED_SIGNING_SHA256');

  /// True only when we have a known-good fingerprint to compare against AND
  /// the running app's actual signing certificate doesn't match it. Fails
  /// open (returns false) on any error, timeout, or missing data — an
  /// undetected tampered build is a smaller harm than a bug in this check
  /// bricking a legitimate install.
  static Future<bool> isTampered() => isTamperedFor(_expectedSha256);

  /// Same logic as [isTampered], but takes the expected fingerprint as a
  /// parameter instead of reading the compile-time constant — lets tests
  /// exercise the match/mismatch/error branches without needing a
  /// --dart-define at test-run time. Not used outside tests.
  @visibleForTesting
  static Future<bool> isTamperedFor(String expectedSha256) async {
    if (expectedSha256.isEmpty) return false;
    try {
      final actual = await _channel
          .invokeMethod<String>('getSigningSha256')
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      if (actual == null || actual.isEmpty) return false;
      return actual.toLowerCase() != expectedSha256.toLowerCase();
    } catch (_) {
      return false;
    }
  }
}
