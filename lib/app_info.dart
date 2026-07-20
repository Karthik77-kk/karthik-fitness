/// Single source of truth for the app's user-visible version.
///
/// These MUST stay in sync with `pubspec.yaml` (`version: <name>+<build>`).
/// A test (`test/app_version_test.dart`) reads pubspec.yaml and fails the build
/// if they drift, so the "About" screen can never show a stale build number
/// again (the old hardcoded "Build 82" lagged pubspec by 20+ builds).
library;

const String kAppVersionName = '3.0.0';
const int kAppBuild = 111;

/// e.g. "v3.0.0 · Build 111"
const String kAppVersionLabel = 'v$kAppVersionName · Build $kAppBuild';
