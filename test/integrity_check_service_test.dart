// Signing-certificate tamper check — see lib/services/integrity_check_service.dart.
//
// isTampered() itself always returns false in this test binary (no
// --dart-define=EXPECTED_SIGNING_SHA256 is set for `flutter test`), so the
// real coverage of the match/mismatch/error branches goes through
// isTamperedFor(expected), which takes the expected fingerprint directly.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kfit/services/integrity_check_service.dart';

const _kChannel = MethodChannel('com.kfitness/integrity');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockGetSigningSha256(Future<String?> Function() handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kChannel, (call) async {
      if (call.method == 'getSigningSha256') return handler();
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kChannel, null);
  });

  group('isTampered (production entry point)', () {
    test('always false — no EXPECTED_SIGNING_SHA256 dart-define in tests',
        () async {
      expect(await IntegrityCheckService.isTampered(), isFalse);
    });
  });

  group('isTamperedFor (expected fingerprint supplied directly)', () {
    test('empty expected fingerprint → false, channel never invoked',
        () async {
      var invoked = false;
      mockGetSigningSha256(() async {
        invoked = true;
        return 'anything';
      });
      expect(await IntegrityCheckService.isTamperedFor(''), isFalse);
      expect(invoked, isFalse);
    });

    test('actual matches expected (same case) → false', () async {
      mockGetSigningSha256(() async => 'abc123deadbeef');
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });

    test('actual matches expected but different case → false', () async {
      mockGetSigningSha256(() async => 'ABC123DEADBEEF');
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });

    test('actual differs from expected → true', () async {
      mockGetSigningSha256(() async => 'some-other-fingerprint');
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isTrue,
      );
    });

    test('native side returns null → fails open (false)', () async {
      mockGetSigningSha256(() async => null);
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });

    test('native side returns empty string → fails open (false)', () async {
      mockGetSigningSha256(() async => '');
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });

    test('channel throws (e.g. missing plugin) → fails open (false)',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_kChannel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE');
      });
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });

    test('no handler registered at all (MissingPluginException) → false',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_kChannel, null);
      expect(
        await IntegrityCheckService.isTamperedFor('abc123deadbeef'),
        isFalse,
      );
    });
  });
}
