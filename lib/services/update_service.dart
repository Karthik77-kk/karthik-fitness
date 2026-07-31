import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'apk_patcher.dart';

const _repo = 'Karthik77-kk/kfit';
const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';
const _assetName = 'kfit.apk';
const _patchName = 'kfit.patch';
const _patchMetaName = 'patch.json';

/// Reads the installed base APK's path (`applicationInfo.sourceDir`) — the exact
/// bytes this app was installed from, which a delta patch reconstructs against.
const _integrityChannel = MethodChannel('com.kfitness/integrity');

class AppUpdateInfo {
  final String tag;
  final int build;
  final String versionName;
  final String notes;
  final String apkUrl;
  final int sizeBytes;

  /// Download URLs for the optional delta-patch assets (`kfit.patch` and
  /// `patch.json`). Null when this release carries no patch — the app then just
  /// does a full download. Present only from the build that first added patch
  /// generation onward.
  final String? patchUrl;
  final String? patchMetaUrl;

  /// Byte size of the `kfit.patch` delta asset (0 when the release ships no
  /// patch). Lets the UI show the *actual* bytes a delta update downloads
  /// (a few KB) instead of the full APK size when patching.
  final int patchSizeBytes;

  const AppUpdateInfo({
    required this.tag,
    required this.build,
    required this.versionName,
    required this.notes,
    required this.apkUrl,
    required this.sizeBytes,
    this.patchUrl,
    this.patchMetaUrl,
    this.patchSizeBytes = 0,
  });
}

/// Parsed `patch.json` — describes the single `prev → this` delta the release
/// ships, and carries the two SHA-256 gates that make applying it safe:
/// [fromSha256] (the installed APK a patch expects) and [toSha256] (the exact
/// signed APK the reconstruction must reproduce).
class PatchMeta {
  final int fromBuild;
  final int toBuild;
  final String fromSha256;
  final String toSha256;
  final String? patchSha256;
  final int patchSize;

  const PatchMeta({
    required this.fromBuild,
    required this.toBuild,
    required this.fromSha256,
    required this.toSha256,
    this.patchSha256,
    this.patchSize = 0,
  });

  /// Parses `patch.json`. Returns null if any required field is missing/malformed
  /// so the caller falls back to a full download rather than trusting bad data.
  static PatchMeta? parse(Map<String, dynamic> json) {
    try {
      final fromBuild = json['fromBuild'] as int?;
      final toBuild = json['toBuild'] as int?;
      final fromSha = (json['fromSha256'] as String?)?.toLowerCase();
      final toSha = (json['toSha256'] as String?)?.toLowerCase();
      if (fromBuild == null ||
          toBuild == null ||
          fromSha == null ||
          fromSha.isEmpty ||
          toSha == null ||
          toSha.isEmpty) {
        return null;
      }
      return PatchMeta(
        fromBuild: fromBuild,
        toBuild: toBuild,
        fromSha256: fromSha,
        toSha256: toSha,
        patchSha256: (json['patchSha256'] as String?)?.toLowerCase(),
        patchSize: (json['patchSize'] as int?) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class UpdateService {
  UpdateService({http.Client? httpClient}) : _client = httpClient ?? http.Client();

  final http.Client _client;

  /// Extracts the build number (commit count) from a tag like `v2.3.272` → 272.
  /// Returns null if the tag doesn't match the expected format.
  static int? buildFromTag(String tag) {
    final parts = tag.split('.');
    if (parts.length < 3) return null;
    return int.tryParse(parts.last);
  }

  /// Parses the GitHub releases/latest JSON into [AppUpdateInfo].
  /// Returns null if the response is malformed or the kfit.apk asset is missing.
  static AppUpdateInfo? parseLatest(Map<String, dynamic> json) {
    try {
      final tag = json['tag_name'] as String? ?? '';
      final build = buildFromTag(tag);
      if (build == null) return null;

      final assets = (json['assets'] as List<dynamic>?) ?? [];
      final list = assets.cast<Map<String, dynamic>>();

      String? urlOf(String name) {
        final a = list.firstWhere(
          (a) => (a['name'] as String?) == name,
          orElse: () => const {},
        );
        final u = a['browser_download_url'] as String?;
        return (u != null && u.isNotEmpty) ? u : null;
      }

      int sizeOf(String name) {
        final a = list.firstWhere(
          (a) => (a['name'] as String?) == name,
          orElse: () => const {},
        );
        return (a['size'] as int?) ?? 0;
      }

      final asset = list.firstWhere(
        (a) => (a['name'] as String?) == _assetName,
        orElse: () => {},
      );
      if (asset.isEmpty) return null;

      final apkUrl = asset['browser_download_url'] as String? ?? '';
      if (apkUrl.isEmpty) return null;

      return AppUpdateInfo(
        tag: tag,
        build: build,
        versionName: tag.replaceFirst('v', ''),
        notes: (json['body'] as String?) ?? '',
        apkUrl: apkUrl,
        sizeBytes: (asset['size'] as int?) ?? 0,
        patchUrl: urlOf(_patchName),
        patchMetaUrl: urlOf(_patchMetaName),
        patchSizeBytes: sizeOf(_patchName),
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches the latest release from GitHub unconditionally.
  /// Returns [AppUpdateInfo] if the release has a kfit.apk asset, null otherwise.
  /// Use this right before downloading to get a fresher URL than the initial check.
  Future<AppUpdateInfo?> fetchLatestInfo() async {
    try {
      final response = await _client
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return parseLatest(json);
    } catch (_) {
      return null;
    }
  }

  /// Checks GitHub for a newer release. Returns [AppUpdateInfo] if an update
  /// exists, null if already up-to-date, network fails, or the API errors.
  Future<AppUpdateInfo?> checkForUpdate(int currentBuild) async {
    try {
      final response = await _client
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final info = parseLatest(json);
      if (info == null || info.build <= currentBuild) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// The fully-downloaded APK for [build], or null if it isn't present (or is a
  /// wrong-sized leftover). Lets the app show an "Install" prompt without
  /// re-downloading when a background download already finished.
  Future<File?> readyApk(int build, {int expectedBytes = 0, Directory? dir}) async {
    try {
      final tmp = dir ?? await getTemporaryDirectory();
      final f = File('${tmp.path}/kfit_$build.apk');
      if (!await f.exists()) return null;
      if (expectedBytes > 0 && await f.length() != expectedBytes) return null;
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Downloads (or RESUMES) the APK for [info.build] to the temp dir, calling
  /// [onProgress] with a 0.0–1.0 fraction as bytes arrive. Returns the completed
  /// [File].
  ///
  /// Resumable: bytes land in a `kfit_<build>.apk.part` file; a re-invocation
  /// after the app was closed mid-download sends `Range: bytes=<have>-` and
  /// appends (falling back to a clean restart if the server ignores the range).
  /// A fully-present file short-circuits instantly, so calling this on every
  /// launch is cheap once the download is done. Other builds' files are purged
  /// first so at most one APK's worth of cache exists.
  Future<File> downloadApk(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
    Directory? dir,
  }) async {
    final tmp = dir ?? await getTemporaryDirectory();
    await cleanupCachedApks(keepBuild: info.build, dir: tmp);

    final dest = File('${tmp.path}/kfit_${info.build}.apk');
    final total = info.sizeBytes;
    // Already fully downloaded → done.
    if (await dest.exists() &&
        (total <= 0 || await dest.length() == total)) {
      onProgress?.call(1);
      return dest;
    }

    final part = File('${tmp.path}/kfit_${info.build}.apk.part');
    var have = (await part.exists()) ? await part.length() : 0;
    // A complete .part just needs finalizing.
    if (total > 0 && have >= total) {
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      onProgress?.call(1);
      return dest;
    }

    final request = http.Request('GET', Uri.parse(info.apkUrl));
    if (have > 0) request.headers['Range'] = 'bytes=$have-';
    final response = await _client.send(request);
    // 206 = server honoured the range (resume); anything else → restart clean.
    final resuming = response.statusCode == 206 && have > 0;
    if (!resuming) have = 0;

    final sink = part.openWrite(mode: resuming ? FileMode.append : FileMode.write);
    var received = have;
    try {
      await response.stream.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) onProgress(received / total);
      });
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (await dest.exists()) await dest.delete();
    await part.rename(dest.path);

    // Integrity gate: the finished file MUST match the size GitHub reported for
    // the asset. A short read (connection dropped at EOF), a corrupt resume, or
    // a tampered payload is caught here — before the APK is ever handed to the
    // installer. On mismatch we delete it and throw so the next launch redownloads
    // cleanly. (The app also verifies the signing cert at runtime post-install.)
    final got = await dest.length();
    if (total > 0 && got != total) {
      try {
        await dest.delete();
      } catch (_) {}
      throw StateError('Downloaded APK is $got bytes, expected $total');
    }

    onProgress?.call(1);
    return dest;
  }

  /// Attempts a small **delta update**: instead of the full ~170 MB APK, download
  /// only the `kfit.patch` binary diff and reconstruct the new APK from the one
  /// already installed on the device. Returns the reconstructed [File] (identical
  /// bytes to [info]'s `kfit.apk`, so it installs in place like any update), or
  /// **null** on any reason it can't/shouldn't — the caller then falls back to
  /// [downloadApk]. It is safe by construction: the result is only returned if it
  /// reproduces the exact signed APK.
  ///
  /// Steps (each a bail-out to full download): patch assets present → fetch tiny
  /// `patch.json` → this patch targets [info] and starts from *our exact* build →
  /// the installed APK's SHA-256 equals `fromSha256` → download + (optionally
  /// verify) the patch → apply it → the reconstruction's SHA-256 equals
  /// `toSha256`. Only the last, verified file is handed back.
  ///
  /// [currentBuild] / [installedApkPath] / [dir] are injectable for tests; in
  /// production they resolve from `package_info_plus`, the platform channel, and
  /// the temp dir respectively.
  Future<File?> tryDeltaUpdate(
    AppUpdateInfo info, {
    void Function(double progress)? onProgress,
    Directory? dir,
    int? currentBuild,
    String? installedApkPath,
  }) async {
    try {
      final patchUrl = info.patchUrl;
      final metaUrl = info.patchMetaUrl;
      if (patchUrl == null || metaUrl == null) return null;

      // 1. Tiny patch.json.
      final metaResp = await _client
          .get(Uri.parse(metaUrl))
          .timeout(const Duration(seconds: 8));
      if (metaResp.statusCode != 200) return null;
      final meta = PatchMeta.parse(jsonDecode(metaResp.body) as Map<String, dynamic>);
      if (meta == null) return null;
      // The patch must actually produce THIS release.
      if (meta.toBuild != info.build) return null;

      // 2. Only useful if we're exactly the build this patch starts from.
      final cur = currentBuild ??
          int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ??
          0;
      if (cur == 0 || meta.fromBuild != cur) return null;

      // 3. The installed APK must be byte-identical to what the patch expects.
      final apkPath = installedApkPath ?? await _installedApkPath();
      if (apkPath == null) return null;
      if (!await File(apkPath).exists()) return null;
      final fromSha = await _sha256OfFile(apkPath);
      if (fromSha != meta.fromSha256) return null;

      // 4. Download the (small) patch. Purge other builds' cached APKs first, as
      //    downloadApk does, so at most one build's cache exists.
      final tmp = dir ?? await getTemporaryDirectory();
      await cleanupCachedApks(keepBuild: info.build, dir: tmp);
      final patchResp = await _client
          .get(Uri.parse(patchUrl))
          .timeout(const Duration(seconds: 60));
      if (patchResp.statusCode != 200) return null;
      final patchBytes = patchResp.bodyBytes;
      onProgress?.call(0.5);
      if (meta.patchSha256 != null && meta.patchSha256!.isNotEmpty) {
        if (sha256.convert(patchBytes).toString() != meta.patchSha256) return null;
      }

      // 5. Reconstruct into a scratch file (memory-safe: see ApkPatcher).
      final dest = File('${tmp.path}/kfit_${info.build}.apk');
      final workPath = '${tmp.path}/kfit_${info.build}.apk.recon';
      await ApkPatcher.applyToFile(
        oldPath: apkPath,
        patch: patchBytes,
        outPath: workPath,
      );

      // 6. Gate: the reconstruction MUST equal the real signed APK, else discard.
      final toSha = await _sha256OfFile(workPath);
      if (toSha != meta.toSha256) {
        await _tryDelete(workPath);
        return null;
      }
      if (await dest.exists()) await dest.delete();
      await File(workPath).rename(dest.path);
      onProgress?.call(1);
      return dest;
    } catch (_) {
      // ANY failure → let the caller do a normal full download.
      return null;
    }
  }

  /// Path to the installed base APK (`applicationInfo.sourceDir`) via the platform
  /// channel, or null if unavailable (non-Android, error, timeout).
  Future<String?> _installedApkPath() async {
    try {
      return await _integrityChannel
          .invokeMethod<String>('getInstalledApkPath')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  /// Streaming SHA-256 of a file — reads in chunks so a ~170 MB APK is never held
  /// in the heap at once.
  Future<String> _sha256OfFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  static Future<void> _tryDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* best-effort */}
  }

  /// Opens the downloaded APK with the system package installer.
  Future<void> install(File apkFile) async {
    await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
  }

  /// Deletes leftover downloaded APKs and partials (~170 MB each) from the temp
  /// dir so they don't accumulate. Optionally keeps [keepBuild]'s files (the
  /// completed `kfit_<b>.apk` AND its in-flight `kfit_<b>.apk.part`). Pass no
  /// [keepBuild] to purge everything — used once the user is on the latest
  /// version, so a downloaded installer is never left behind. Best-effort.
  static Future<void> cleanupCachedApks({int? keepBuild, Directory? dir}) async {
    try {
      final tmp = dir ?? await getTemporaryDirectory();
      final keepApk = keepBuild != null ? 'kfit_$keepBuild.apk' : null;
      final keepPart = keepBuild != null ? 'kfit_$keepBuild.apk.part' : null;
      await for (final f in tmp.list(followLinks: false)) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last; // basename, separator-agnostic
        final isOurs = name.startsWith('kfit_') &&
            (name.endsWith('.apk') || name.endsWith('.apk.part'));
        if (!isOurs) continue;
        if (keepApk != null && (name == keepApk || name == keepPart)) continue;
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {/* best-effort */}
  }
}
