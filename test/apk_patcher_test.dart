import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kfit/services/apk_patcher.dart';

import 'support/bsdiff_fixture.dart';

void main() {
  group('ApkPatcher.apply', () {
    test('all-extra patch reproduces new, ignoring old', () {
      final old = Uint8List.fromList([1, 2, 3, 4, 5]);
      final want = Uint8List.fromList([9, 8, 7, 6]);
      expect(ApkPatcher.apply(old, allExtraPatch(want)), want);
    });

    test('add-run adds diff to old byte-wise', () {
      final old = Uint8List.fromList([10, 20, 30]);
      final patch = buildPatch(
        control: [
          [3, 0, 0],
        ],
        diff: [1, 2, 3], // new[i] = old[i] + diff[i]
        extra: const [],
        newSize: 3,
      );
      expect(ApkPatcher.apply(old, patch), [11, 22, 33]);
    });

    test('byte addition wraps mod 256', () {
      final old = Uint8List.fromList([250]);
      final patch = buildPatch(
        control: [
          [1, 0, 0],
        ],
        diff: [10], // 250 + 10 = 260 -> 4
        extra: const [],
        newSize: 1,
      );
      expect(ApkPatcher.apply(old, patch), [4]);
    });

    test('combined add + old-seek + extra', () {
      // old: [0,1,2,3,4,5]
      // t1: copy 2 from old@0 (diff 0), seek +2 -> oldpos 4
      // t2: copy 2 from old@4 (diff 0), then extra [99]
      final old = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
      final patch = buildPatch(
        control: [
          [2, 0, 2],
          [2, 1, 0],
        ],
        diff: [0, 0, 0, 0],
        extra: [99],
        newSize: 5,
      );
      expect(ApkPatcher.apply(old, patch), [0, 1, 4, 5, 99]);
    });

    test('add-run past end of old adds only the in-range bytes', () {
      // old has 2 bytes; an add-run of 4 overlaps old only for the first 2.
      final old = Uint8List.fromList([100, 100]);
      final patch = buildPatch(
        control: [
          [4, 0, 0],
        ],
        diff: [1, 1, 1, 1],
        extra: const [],
        newSize: 4,
      );
      // [100+1, 100+1, 0+1, 0+1]
      expect(ApkPatcher.apply(old, patch), [101, 101, 1, 1]);
    });

    test('rejects a too-short patch', () {
      expect(() => ApkPatcher.apply(Uint8List(0), Uint8List(10)),
          throwsFormatException);
    });

    test('rejects bad magic', () {
      final bad = Uint8List(40)..setRange(0, 8, ascii.encode('NOTBSDIF'));
      expect(() => ApkPatcher.apply(Uint8List(0), bad), throwsFormatException);
    });

    test('rejects truncated blocks (lengths exceed file)', () {
      final p = BytesBuilder()
        ..add(ascii.encode('BSDIFF40'))
        ..add(offtout(1000)) // ctrlLen far larger than the file
        ..add(offtout(0))
        ..add(offtout(0));
      expect(() => ApkPatcher.apply(Uint8List(0), p.toBytes()),
          throwsFormatException);
    });
  });

  group('ApkPatcher.applyToFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('apk_patcher'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round-trips a >1MB all-extra payload (chunked extra path)', () async {
      final want =
          Uint8List.fromList(List.generate(3 * 1024 * 1024 + 7, (i) => (i * 31 + 7) & 0xFF));
      final oldFile = File('${tmp.path}/old.bin')..writeAsBytesSync([1, 2, 3]);
      final outPath = '${tmp.path}/out.bin';
      await ApkPatcher.applyToFile(
        oldPath: oldFile.path,
        patch: allExtraPatch(want),
        outPath: outPath,
      );
      expect(File(outPath).readAsBytesSync(), want);
      // scratch files removed
      expect(File('$outPath.dpart').existsSync(), isFalse);
      expect(File('$outPath.epart').existsSync(), isFalse);
    });

    test('round-trips a >1MB add-run reading old via RandomAccessFile', () async {
      const n = 2 * 1024 * 1024 + 5;
      final old = Uint8List.fromList(List.generate(n, (i) => (i * 7) & 0xFF));
      final want = Uint8List.fromList(List.generate(n, (i) => (old[i] + 1) & 0xFF));
      final oldFile = File('${tmp.path}/old2.bin')..writeAsBytesSync(old);
      final patch = buildPatch(
        control: [
          [n, 0, 0],
        ],
        diff: List<int>.filled(n, 1), // +1 to every byte
        extra: const [],
        newSize: n,
      );
      final outPath = '${tmp.path}/out2.bin';
      await ApkPatcher.applyToFile(oldPath: oldFile.path, patch: patch, outPath: outPath);
      expect(File(outPath).readAsBytesSync(), want);
    });

    test('file path agrees with in-memory apply', () async {
      final old = Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));
      final want = Uint8List.fromList(List.generate(1000, (i) => (i * 3 + 1) & 0xFF));
      final diff = Uint8List(1000);
      for (var i = 0; i < 1000; i++) {
        diff[i] = (want[i] - old[i]) & 0xFF;
      }
      final patch = buildPatch(
        control: [
          [1000, 0, 0],
        ],
        diff: diff,
        extra: const [],
        newSize: 1000,
      );
      final oldFile = File('${tmp.path}/o.bin')..writeAsBytesSync(old);
      final outPath = '${tmp.path}/o.out';
      await ApkPatcher.applyToFile(oldPath: oldFile.path, patch: patch, outPath: outPath);
      expect(File(outPath).readAsBytesSync(), ApkPatcher.apply(old, patch));
      expect(File(outPath).readAsBytesSync(), want);
    });
  });
}
