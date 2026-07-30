import 'package:flutter_test/flutter_test.dart';
import 'package:kfit/services/backup_crypto.dart';

void main() {
  const secretJson =
      '{"weight":72.5,"food_2026-07-20":[{"name":"Dosa","kcal":168}],"userName":"K"}';
  const id = '482913';

  test('round-trips: decrypt(encrypt(x, id), id) == x', () async {
    final blob = await BackupCrypto.encrypt(secretJson, id);
    expect(BackupCrypto.isEncrypted(blob), isTrue);
    final back = await BackupCrypto.decrypt(blob, id);
    expect(back, secretJson);
  });

  test('ciphertext does not leak the plaintext health data', () async {
    final blob = await BackupCrypto.encrypt(secretJson, id);
    expect(blob.contains('72.5'), isFalse);
    expect(blob.contains('Dosa'), isFalse);
    expect(blob.contains('userName'), isFalse);
  });

  test('a wrong id fails to decrypt (GCM auth)', () async {
    final blob = await BackupCrypto.encrypt(secretJson, id);
    expect(() => BackupCrypto.decrypt(blob, '000000'), throwsA(anything));
  });

  test('legacy plaintext (no prefix) passes through unchanged', () async {
    expect(BackupCrypto.isEncrypted(secretJson), isFalse);
    expect(await BackupCrypto.decrypt(secretJson, id), secretJson);
  });

  test('each encryption uses a fresh salt+nonce (outputs differ)', () async {
    final a = await BackupCrypto.encrypt(secretJson, id);
    final b = await BackupCrypto.encrypt(secretJson, id);
    expect(a == b, isFalse); // random salt/nonce → different ciphertext
    expect(await BackupCrypto.decrypt(a, id), secretJson);
    expect(await BackupCrypto.decrypt(b, id), secretJson);
  });
}
