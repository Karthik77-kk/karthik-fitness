import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'backup_crypto.dart';

/// Backs up / restores the app's data JSON to a shared private GitHub repo —
/// one file per user, keyed by a chosen username + id (path
/// `users/<username>-<id>.json`). Every PUT is a commit, so the repo doubles as
/// a versioned store.
///
/// Configuration is resolved at runtime: an **in-app** token + repo (entered in
/// Settings, stored on-device under `cloud_*` keys) takes precedence, falling
/// back to a **build-time** `--dart-define GH_BACKUP_TOKEN/GH_BACKUP_REPO`
/// (same pattern as HF_TOKEN). Either way, when nothing is configured cloud sync
/// is disabled and the app still works fully via local Export/Import.
///
/// ⚠️ The token grants access to the whole repo, and a chosen username+id is
/// identification, not a password — so this is for PERSONAL / TESTING use, NOT a
/// public multi-user product. A real product needs a backend that authenticates
/// each user. (In-app entry at least keeps the token OUT of the shipped APK.)
class CloudBackupService {
  CloudBackupService._();
  static final CloudBackupService instance = CloudBackupService._();

  // Build-time defaults (optional). Empty unless injected via --dart-define.
  // Base64-encoded at CI injection time so the raw token/repo aren't
  // plaintext, grep-able strings inside the compiled APK. Same values, same
  // behavior — decoded once at first access.
  static const String _compiledTokenB64 =
      String.fromEnvironment('GH_BACKUP_TOKEN_B64', defaultValue: '');
  static const String _compiledRepoB64 =
      String.fromEnvironment('GH_BACKUP_REPO_B64', defaultValue: '');

  static String get compiledToken => _compiledTokenB64.isEmpty
      ? ''
      : utf8.decode(base64.decode(_compiledTokenB64));
  static String get compiledRepo => _compiledRepoB64.isEmpty
      ? ''
      : utf8.decode(base64.decode(_compiledRepoB64));

  static const _ua = 'KFitness/1.0';
  static const _timeout = Duration(seconds: 15);

  static const _tokenKey = 'cloud_token'; // in-app token (cloud_* ⇒ never exported)
  static const _repoKey = 'cloud_repo';
  static const _userKey = 'cloud_username';
  static const _idKey = 'cloud_userid';
  static const _lastKey = 'cloud_last_backup_ms';
  static const _autoKey = 'cloud_auto_backup';

  // ── Configuration (in-app overrides build-time) ──────────────────────────────
  Future<String> effectiveToken() async {
    final p = (await SharedPreferences.getInstance()).getString(_tokenKey);
    return (p != null && p.isNotEmpty) ? p : compiledToken;
  }

  Future<String> effectiveRepo() async {
    final p = (await SharedPreferences.getInstance()).getString(_repoKey);
    return (p != null && p.isNotEmpty) ? p : compiledRepo;
  }

  /// True when the token + repo were baked in at build (`--dart-define`). In this
  /// case the UI hides all repo/token setup — testers only enter a username + id.
  static bool get hasCompiledConfig =>
      compiledToken.isNotEmpty && isValidRepo(compiledRepo);

  /// Cloud sync is usable when there's a token and a valid `owner/name` repo.
  Future<bool> isConfigured() async {
    final t = await effectiveToken();
    final r = await effectiveRepo();
    return t.isNotEmpty && isValidRepo(r);
  }

  /// The configured repo for display (in-app or build-time), or null.
  Future<String?> configuredRepo() async {
    final r = await effectiveRepo();
    return r.isNotEmpty ? r : null;
  }

  /// True when a backup already exists for [username]+[id] — used to warn a new
  /// user that the id is taken (so two testers don't collide on one file).
  /// Returns false when unconfigured or on network error (fail-open).
  Future<bool> accountExists(String username, String id) async {
    final t = await effectiveToken();
    final r = await effectiveRepo();
    if (t.isEmpty || !isValidRepo(r) || !isValidAccount(username, id)) {
      return false;
    }
    try {
      final resp = await http
          .get(_contentsUri(r, filePathFor(username, id)), headers: _headers(t))
          .timeout(_timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveConfig({required String token, required String repo}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token.trim());
    await prefs.setString(_repoKey, repo.trim());
  }

  Future<void> clearConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_repoKey);
  }

  // ── Account (username + id) ──────────────────────────────────────────────────
  Future<String?> username() async =>
      (await SharedPreferences.getInstance()).getString(_userKey);
  Future<String?> userId() async =>
      (await SharedPreferences.getInstance()).getString(_idKey);
  Future<bool> get hasAccount async =>
      (await username())?.isNotEmpty == true &&
      (await userId())?.isNotEmpty == true;
  Future<int> lastBackupMs() async =>
      (await SharedPreferences.getInstance()).getInt(_lastKey) ?? 0;

  /// Whether cold-launch / daily auto-backup is on (default true).
  Future<bool> autoBackupEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_autoKey) ?? true;

  Future<void> setAutoBackup(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(_autoKey, on);

  Future<void> saveAccount(String username, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, username.trim());
    await prefs.setString(_idKey, id.trim());
  }

  // ── Pure helpers (testable) ──────────────────────────────────────────────────
  /// Repo path for a username+id pair: `users/<slug>-<slug>.json`.
  static String filePathFor(String username, String id) =>
      'users/${_slug(username)}-${_slug(id)}.json';

  static String _slug(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static bool isValidRepo(String r) =>
      RegExp(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$').hasMatch(r.trim());

  /// True when username + id both slugify to a non-empty key.
  static bool isValidAccount(String username, String id) =>
      _slug(username).isNotEmpty && _slug(id).isNotEmpty;

  /// Decodes a GitHub Contents API `content` field (base64, newline-chunked).
  static String decodeContentField(Map<String, dynamic> body) {
    final raw = (body['content'] as String?) ?? '';
    return utf8.decode(base64Decode(raw.replaceAll(RegExp(r'\s'), '')));
  }

  static String errorFor(int status) {
    switch (status) {
      case 401:
        return 'GitHub auth failed — token invalid or expired.';
      case 403:
        return 'GitHub denied the request (token scope or rate limit).';
      case 404:
        return 'Repo not found — check the backup repo setting.';
      case 409:
      case 422:
        return 'Backup conflict — try again.';
      default:
        return 'GitHub error $status.';
    }
  }

  // ── API ──────────────────────────────────────────────────────────────────────
  static Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': _ua,
      };

  static Uri _contentsUri(String repo, String path) =>
      Uri.parse('https://api.github.com/repos/$repo/contents/$path');

  /// Pushes [jsonContent] to the current account's file (create or update).
  /// Returns a status message. Throws [Exception] on misconfig / HTTP error.
  Future<String> backup(String jsonContent) async {
    final t = await effectiveToken();
    final r = await effectiveRepo();
    if (t.isEmpty || !isValidRepo(r)) {
      throw Exception('Cloud sync not configured');
    }
    final u = await username();
    final id = await userId();
    if (u == null || id == null || !isValidAccount(u, id)) {
      throw Exception('Set a username and id first');
    }
    final path = filePathFor(u, id);
    final prefs = await SharedPreferences.getInstance();
    // Encrypt on-device with a key derived from the secret id, so the shared
    // private repo only ever stores ciphertext (health data is never plaintext).
    final payload = await BackupCrypto.encrypt(jsonContent, id);
    // Always fetch the CURRENT remote sha right before writing — a cached sha
    // goes stale the moment another device backs up, which would 409/422 every
    // subsequent push. Updating requires the live sha; creating omits it.
    final sha = await _fetchSha(t, r, path);

    final body = <String, dynamic>{
      'message': 'K Fitness backup ($u) ${DateTime.now().toIso8601String()}',
      'content': base64Encode(utf8.encode(payload)),
      // No 'branch' → GitHub writes to the repo's default branch (avoids a
      // main-vs-master mismatch for arbitrary test repos).
      if (sha != null) 'sha': sha,
    };
    final resp = await http
        .put(_contentsUri(r, path), headers: _headers(t), body: jsonEncode(body))
        .timeout(_timeout);
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      await prefs.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
      return 'Backed up as $u';
    }
    throw Exception(errorFor(resp.statusCode));
  }

  /// Fetches the backup JSON for [username]+[id], or null when none exists.
  Future<String?> restore(String username, String id) async {
    final t = await effectiveToken();
    final r = await effectiveRepo();
    if (t.isEmpty || !isValidRepo(r)) {
      throw Exception('Cloud sync not configured');
    }
    if (!isValidAccount(username, id)) {
      throw Exception('Enter a username and id');
    }
    final path = filePathFor(username, id);
    final resp = await http
        .get(_contentsUri(r, path), headers: _headers(t))
        .timeout(_timeout);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) throw Exception(errorFor(resp.statusCode));
    final stored = decodeContentField(jsonDecode(resp.body) as Map<String, dynamic>);
    // Decrypt with the secret id. Legacy plaintext backups pass through
    // unchanged; a wrong id / tampered blob throws a clear error.
    try {
      return await BackupCrypto.decrypt(stored, id);
    } catch (_) {
      throw Exception('Could not decrypt backup — check your secret id.');
    }
  }

  /// Auto-backup hook: pushes [buildJson]'s result if cloud sync is configured,
  /// an account exists, auto-backup is on, and it's been ≥1 day since the last
  /// push (or never). Silent on failure. Returns true if a backup was pushed.
  Future<bool> autoBackupIfDue(Future<String> Function() buildJson) async {
    if (!await isConfigured() || !await hasAccount) return false;
    if (!await autoBackupEnabled()) return false;
    final last = await lastBackupMs();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last != 0 && now - last < const Duration(days: 1).inMilliseconds) {
      return false;
    }
    try {
      await backup(await buildJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _fetchSha(String token, String repo, String path) async {
    try {
      final resp = await http
          .get(_contentsUri(repo, path), headers: _headers(token))
          .timeout(_timeout);
      if (resp.statusCode == 200) {
        return (jsonDecode(resp.body) as Map<String, dynamic>)['sha'] as String?;
      }
    } catch (_) {/* 404 / error → treat as create */}
    return null;
  }
}
