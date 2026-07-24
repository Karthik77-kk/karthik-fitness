import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kfit/services/update_service.dart';

import 'support/bsdiff_fixture.dart';

void main() {
  group('UpdateService.parseLatest — patch assets', () {
    Map<String, dynamic> release({bool withPatch = true}) => {
          'tag_name': 'v3.0.328',
          'body': 'notes',
          'assets': [
            {'name': 'kfit.apk', 'browser_download_url': 'https://x/kfit.apk', 'size': 100},
            if (withPatch)
              {'name': 'kfit.patch', 'browser_download_url': 'https://x/kfit.patch', 'size': 20},
            if (withPatch)
              {'name': 'patch.json', 'browser_download_url': 'https://x/patch.json', 'size': 3},
          ],
        };

    test('surfaces patch + meta urls when present', () {
      final info = UpdateService.parseLatest(release());
      expect(info!.patchUrl, 'https://x/kfit.patch');
      expect(info.patchMetaUrl, 'https://x/patch.json');
    });

    test('leaves patch urls null when the release has none', () {
      final info = UpdateService.parseLatest(release(withPatch: false));
      expect(info!.patchUrl, isNull);
      expect(info.patchMetaUrl, isNull);
    });
  });

  group('PatchMeta.parse', () {
    test('parses a full object and lowercases hashes', () {
      final m = PatchMeta.parse({
        'fromBuild': 327,
        'toBuild': 328,
        'fromSha256': 'AABB',
        'toSha256': 'CCDD',
        'patchSha256': 'EEFF',
        'patchSize': 15,
      });
      expect(m!.fromBuild, 327);
      expect(m.toBuild, 328);
      expect(m.fromSha256, 'aabb');
      expect(m.toSha256, 'ccdd');
      expect(m.patchSha256, 'eeff');
      expect(m.patchSize, 15);
    });

    test('returns null when a required field is missing', () {
      expect(PatchMeta.parse({'fromBuild': 1, 'toBuild': 2, 'fromSha256': 'a'}), isNull);
    });

    test('returns null when a hash is empty', () {
      expect(
        PatchMeta.parse({'fromBuild': 1, 'toBuild': 2, 'fromSha256': '', 'toSha256': 'b'}),
        isNull,
      );
    });
  });

  group('UpdateService.tryDeltaUpdate', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('delta_update'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // Old "installed" APK + a real old→new patch + its patch.json.
    _Fixture makeFixture() {
      final oldBytes = Uint8List.fromList(List.generate(2048, (i) => (i * 13) & 0xFF));
      final newBytes = Uint8List.fromList(List.generate(2000, (i) => (i * 7 + 1) & 0xFF));
      final oldFile = File('${tmp.path}/installed.apk')..writeAsBytesSync(oldBytes);
      final patch = allExtraPatch(newBytes);
      final meta = <String, dynamic>{
        'fromBuild': 327,
        'toBuild': 328,
        'fromSha256': sha256.convert(oldBytes).toString(),
        'toSha256': sha256.convert(newBytes).toString(),
        'patchSha256': sha256.convert(patch).toString(),
        'patchSize': patch.length,
      };
      return _Fixture(oldFile.path, newBytes, patch, meta);
    }

    http.Client client(Uint8List patch, Map<String, dynamic> meta) => MockClient((req) async {
          if (req.url.path.endsWith('patch.json')) {
            return http.Response(jsonEncode(meta), 200,
                headers: {'content-type': 'application/json'});
          }
          if (req.url.path.endsWith('kfit.patch')) {
            return http.Response.bytes(patch, 200);
          }
          return http.Response('not found', 404);
        });

    AppUpdateInfo infoWithPatch() => const AppUpdateInfo(
          tag: 'v3.0.328',
          build: 328,
          versionName: '3.0.328',
          notes: '',
          apkUrl: 'https://x/kfit.apk',
          sizeBytes: 2000,
          patchUrl: 'https://x/kfit.patch',
          patchMetaUrl: 'https://x/patch.json',
        );

    test('happy path reconstructs the new APK and passes both SHA gates', () async {
      final f = makeFixture();
      final svc = UpdateService(httpClient: client(f.patch, f.meta));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNotNull);
      expect(out!.readAsBytesSync(), f.newBytes);
      expect(sha256.convert(out.readAsBytesSync()).toString(), f.meta['toSha256']);
    });

    test('null when not exactly one build behind', () async {
      final f = makeFixture();
      final svc = UpdateService(httpClient: client(f.patch, f.meta));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 320, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });

    test('null when the installed APK SHA does not match fromSha256', () async {
      final f = makeFixture();
      File(f.oldPath).writeAsBytesSync([9, 9, 9]); // tamper the installed APK
      final svc = UpdateService(httpClient: client(f.patch, f.meta));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });

    test('null when the reconstruction fails the toSha256 gate', () async {
      final f = makeFixture();
      final bad = Map<String, dynamic>.from(f.meta)..['toSha256'] = 'deadbeef';
      final svc = UpdateService(httpClient: client(f.patch, bad));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });

    test('null when patchSha256 does not match the downloaded bytes', () async {
      final f = makeFixture();
      final bad = Map<String, dynamic>.from(f.meta)..['patchSha256'] = 'deadbeef';
      final svc = UpdateService(httpClient: client(f.patch, bad));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });

    test('null when the patch targets a different toBuild', () async {
      final f = makeFixture();
      final bad = Map<String, dynamic>.from(f.meta)..['toBuild'] = 999;
      final svc = UpdateService(httpClient: client(f.patch, bad));
      final out = await svc.tryDeltaUpdate(infoWithPatch(),
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });

    test('null when the release carries no patch assets', () async {
      final f = makeFixture();
      final svc = UpdateService(httpClient: client(f.patch, f.meta));
      const noPatch = AppUpdateInfo(
        tag: 'v3.0.328',
        build: 328,
        versionName: '3.0.328',
        notes: '',
        apkUrl: 'https://x/kfit.apk',
        sizeBytes: 2000,
      );
      final out = await svc.tryDeltaUpdate(noPatch,
          currentBuild: 327, installedApkPath: f.oldPath, dir: tmp);
      expect(out, isNull);
    });
  });
}

class _Fixture {
  final String oldPath;
  final Uint8List newBytes;
  final Uint8List patch;
  final Map<String, dynamic> meta;
  _Fixture(this.oldPath, this.newBytes, this.patch, this.meta);
}
