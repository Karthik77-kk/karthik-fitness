import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kfit/services/update_service.dart';

// Auto-download / resume / keep-until-installed / cleanup-on-latest.
// These cover the file-management guarantees the user asked for without a
// network: a completed background download is detected (readyApk), a full
// partial is finalized (resume end-state), the file survives "Later", and it's
// purged only once the user is on the latest.
AppUpdateInfo _info({int build = 5, int size = 0}) => AppUpdateInfo(
      tag: 'v2.3.$build',
      build: build,
      versionName: '2.3.$build',
      notes: '',
      apkUrl: 'https://example.invalid/kfit.apk',
      sizeBytes: size,
    );

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('kfit_upd_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File f(String name) => File('${tmp.path}/$name');
  Future<void> put(String name, int bytes) async =>
      f(name).writeAsBytes(List.filled(bytes, 7));

  group('readyApk', () {
    test('null when the file is absent', () async {
      expect(await UpdateService().readyApk(5, dir: tmp), isNull);
    });
    test('returns the file when present and the size matches', () async {
      await put('kfit_5.apk', 100);
      expect(await UpdateService().readyApk(5, expectedBytes: 100, dir: tmp),
          isNotNull);
    });
    test('null when the size mismatches (stale/partial leftover)', () async {
      await put('kfit_5.apk', 50);
      expect(await UpdateService().readyApk(5, expectedBytes: 100, dir: tmp),
          isNull);
    });
  });

  group('cleanupCachedApks', () {
    test('keeps the kept build (apk + part), deletes others, spares non-kfit',
        () async {
      await put('kfit_5.apk', 10);
      await put('kfit_5.apk.part', 10);
      await put('kfit_4.apk', 10);
      await put('kfit_3.apk.part', 10);
      await put('notes.txt', 10);
      await UpdateService.cleanupCachedApks(keepBuild: 5, dir: tmp);
      expect(await f('kfit_5.apk').exists(), isTrue);
      expect(await f('kfit_5.apk.part').exists(), isTrue);
      expect(await f('kfit_4.apk').exists(), isFalse);
      expect(await f('kfit_3.apk.part').exists(), isFalse);
      expect(await f('notes.txt').exists(), isTrue);
    });
    test('no keepBuild purges every cached apk/partial (on-latest cleanup)',
        () async {
      await put('kfit_5.apk', 10);
      await put('kfit_6.apk.part', 10);
      await UpdateService.cleanupCachedApks(dir: tmp);
      expect(await f('kfit_5.apk').exists(), isFalse);
      expect(await f('kfit_6.apk.part').exists(), isFalse);
    });
  });

  group('downloadApk finalization (no network)', () {
    test('a complete .part is finalized to .apk with no request', () async {
      await put('kfit_5.apk.part', 100); // already full size
      final file =
          await UpdateService().downloadApk(_info(build: 5, size: 100), dir: tmp);
      expect(file.path.endsWith('kfit_5.apk'), isTrue);
      expect(await file.exists(), isTrue);
      expect(await f('kfit_5.apk.part').exists(), isFalse); // renamed
    });
    test('an already-complete .apk short-circuits', () async {
      await put('kfit_5.apk', 100);
      final file =
          await UpdateService().downloadApk(_info(build: 5, size: 100), dir: tmp);
      expect(await file.length(), 100);
    });
    test('starting a fresh build clears a different build\'s leftovers',
        () async {
      await put('kfit_4.apk', 100); // old build fully downloaded
      await put('kfit_9.apk', 100); // target already present
      await UpdateService().downloadApk(_info(build: 9, size: 100), dir: tmp);
      expect(await f('kfit_4.apk').exists(), isFalse); // purged
      expect(await f('kfit_9.apk').exists(), isTrue); // kept
    });
  });
}
