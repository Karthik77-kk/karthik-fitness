import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kfit/services/update_service.dart';
import 'package:kfit/widgets/update_dialog.dart';

/// A controllable [UpdateService] so the download UI can be observed mid-flight.
/// [tryDeltaUpdate] and [downloadApk] each hang on a completer so the sheet stays
/// in its "downloading" phase for assertions instead of racing to "ready".
class _FakeUpdateService extends UpdateService {
  Completer<File?>? deltaCompleter; // pending → stays on the delta spinner
  final downloadCompleter = Completer<File>();
  double emitProgress = 0.42;

  @override
  Future<File?> readyApk(int build, {int expectedBytes = 0, Directory? dir}) async => null;

  @override
  Future<File?> tryDeltaUpdate(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
    Directory? dir,
    int? currentBuild,
    String? installedApkPath,
  }) async {
    if (deltaCompleter != null) return deltaCompleter!.future;
    return null; // no patch applies → caller falls back to full download
  }

  @override
  Future<File> downloadApk(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
    Directory? dir,
  }) async {
    onProgress?.call(emitProgress);
    return downloadCompleter.future;
  }

  @override
  Future<void> install(File apkFile) async {}
}

/// Opens the update sheet and pumps far enough that the async
/// prepare → delta → download chain has reached its (still-pending) phase.
/// No FitnessProvider is provided: the sheet only reads it from the Install/Later
/// callbacks, which these tests don't tap, and a real provider would leak its
/// hourly day-reset timer into the widget-test timer check.
Future<void> _openSheet(
  WidgetTester tester,
  UpdateService service,
  AppUpdateInfo info,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showUpdateDialog(context, info, service),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(); // present sheet + run initState/_prepare
  await tester.pump(const Duration(milliseconds: 400)); // finish entrance
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10)); // flush async chain
  }
}

const _info = AppUpdateInfo(
  tag: 'v3.0.400',
  build: 400,
  versionName: '3.0.400',
  notes: '',
  apkUrl: 'https://x/kfit.apk',
  sizeBytes: 180 * 1048576,
);

// A release that also ships a small delta patch (18 KB).
const _infoWithPatch = AppUpdateInfo(
  tag: 'v3.0.400',
  build: 400,
  versionName: '3.0.400',
  notes: '',
  apkUrl: 'https://x/kfit.apk',
  sizeBytes: 180 * 1048576,
  patchUrl: 'https://x/kfit.patch',
  patchMetaUrl: 'https://x/patch.json',
  patchSizeBytes: 18 * 1024,
);

void main() {
  testWidgets('full-APK fallback shows a live percentage bar', (tester) async {
    final service = _FakeUpdateService()..emitProgress = 0.42;
    await _openSheet(tester, service, _info);

    // No patch → full download → determinate progress with a percentage.
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Preparing update…'), findsNothing);

    // Completing the download flips to the Install action.
    service.downloadCompleter.complete(File('${Directory.systemTemp.path}/x.apk'));
    await tester.pumpAndSettle();
    expect(find.text('Install now'), findsOneWidget);
  });

  testWidgets('delta-patch path shows a spinner, not a percentage', (tester) async {
    final service = _FakeUpdateService()..deltaCompleter = Completer<File?>();
    await _openSheet(tester, service, _info);

    // Small/fast patch attempt → indeterminate spinner, no percentage.
    expect(find.text('Preparing update…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // When the patch is ready it goes straight to Install (no full download).
    service.deltaCompleter!.complete(File('${Directory.systemTemp.path}/y.apk'));
    await tester.pumpAndSettle();
    expect(find.text('Install now'), findsOneWidget);
  });

  testWidgets('delta path shows the small patch size, not the full APK size',
      (tester) async {
    final service = _FakeUpdateService()..deltaCompleter = Completer<File?>();
    await _openSheet(tester, service, _infoWithPatch);

    // Downloading only the 18 KB patch → the size label reflects that, not 180 MB.
    expect(find.text('18 KB'), findsOneWidget);
    expect(find.text('180 MB'), findsNothing);

    service.deltaCompleter!.complete(File('${Directory.systemTemp.path}/z.apk'));
    await tester.pumpAndSettle();
  });

  testWidgets('full download shows the full APK size, not KB', (tester) async {
    // deltaCompleter null → fake delta returns null → falls back to full download.
    final service = _FakeUpdateService()..emitProgress = 0.42;
    await _openSheet(tester, service, _infoWithPatch);

    // On the full path the label flips back to the full APK size.
    expect(find.text('180 MB'), findsOneWidget);
    expect(find.textContaining('KB'), findsNothing);

    service.downloadCompleter.complete(File('${Directory.systemTemp.path}/x.apk'));
    await tester.pumpAndSettle();
  });
}
