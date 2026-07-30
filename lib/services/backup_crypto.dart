import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

/// Client-side encryption for cloud backups.
///
/// The backup JSON is AES-256-GCM encrypted **on the device** with a key derived
/// (PBKDF2-HMAC-SHA256) from the user's secret id, so the shared private repo
/// only ever stores ciphertext — the health data is unreadable to anyone who
/// gets into the repo but doesn't know the id. GCM also *authenticates* the
/// payload, so a corrupted or tampered blob fails to decrypt rather than
/// restoring garbage.
///
/// Stored format: `kfit:enc:1:` + base64(JSON envelope). A value WITHOUT that
/// prefix is treated as a legacy plaintext backup and returned unchanged, so
/// backups made before this feature still restore.
///
/// NOTE: strength is bounded by the id's entropy — a short numeric id is
/// brute-forceable by someone who already has the private repo. This raises the
/// bar enormously over plaintext, but a longer passphrase would be stronger.
class BackupCrypto {
  BackupCrypto._();

  static const _prefix = 'kfit:enc:1:';
  static const _iterations = 120000;

  static final _algorithm = AesGcm.with256bits();
  static final _rand = Random.secure();

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _rand.nextInt(256));

  static Future<SecretKey> _deriveKey(
      String passphrase, List<int> salt, int iterations) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKeyFromPassword(password: passphrase, nonce: salt);
  }

  /// True when [stored] is one of our encrypted envelopes.
  static bool isEncrypted(String stored) => stored.startsWith(_prefix);

  /// Encrypts [plainJson] with a key derived from [passphrase]; returns the
  /// prefixed envelope string to upload.
  static Future<String> encrypt(String plainJson, String passphrase) async {
    final salt = _randomBytes(16);
    final nonce = _algorithm.newNonce();
    final key = await _deriveKey(passphrase, salt, _iterations);
    final box = await _algorithm.encrypt(
      utf8.encode(plainJson),
      secretKey: key,
      nonce: nonce,
    );
    final envelope = {
      'v': 1,
      'alg': 'aes-gcm-256',
      'kdf': 'pbkdf2-hmac-sha256',
      'iter': _iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ct': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
    return _prefix + base64Encode(utf8.encode(jsonEncode(envelope)));
  }

  /// Decrypts [stored] with [passphrase]. A non-encrypted (legacy plaintext)
  /// value is returned unchanged so old backups still restore. Throws on a wrong
  /// passphrase or a tampered/corrupt payload (GCM auth failure).
  static Future<String> decrypt(String stored, String passphrase) async {
    if (!isEncrypted(stored)) return stored; // legacy plaintext backup
    final env = jsonDecode(
            utf8.decode(base64Decode(stored.substring(_prefix.length))))
        as Map<String, dynamic>;
    final salt = base64Decode(env['salt'] as String);
    final nonce = base64Decode(env['nonce'] as String);
    final ct = base64Decode(env['ct'] as String);
    final mac = base64Decode(env['mac'] as String);
    final iter = (env['iter'] as num?)?.toInt() ?? _iterations;
    final key = await _deriveKey(passphrase, salt, iter);
    final clear = await _algorithm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return utf8.decode(clear);
  }
}
