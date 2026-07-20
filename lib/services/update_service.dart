import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

const _repo = 'Karthik77-kk/kfit';
const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';
const _assetName = 'kfit.apk';

class AppUpdateInfo {
  final String tag;
  final int build;
  final String versionName;
  final String notes;
  final String apkUrl;
  final int sizeBytes;

  const AppUpdateInfo({
    required this.tag,
    required this.build,
    required this.versionName,
    required this.notes,
    required this.apkUrl,
    required this.sizeBytes,
  });
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
      final asset = assets.cast<Map<String, dynamic>>().firstWhere(
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
