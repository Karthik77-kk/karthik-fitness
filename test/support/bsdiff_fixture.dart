import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Test helpers that assemble real BSDIFF40 patches (the format `bsdiff` emits in
/// CI and [ApkPatcher] consumes), so the patcher is exercised end-to-end without
/// shelling out to the native `bsdiff` tool.

/// bsdiff sign-magnitude little-endian int64 encoder — the inverse of the
/// patcher's `_offtin`.
Uint8List offtout(int x) {
  final b = Uint8List(8);
  var y = x < 0 ? -x : x;
  for (var i = 0; i < 8; i++) {
    b[i] = y & 0xFF;
    y >>= 8;
  }
  if (x < 0) b[7] |= 0x80;
  return b;
}

/// Assembles a valid BSDIFF40 patch from control triples ([addLen, extraLen,
/// oldSeek]) plus the raw (uncompressed) diff and extra blocks.
Uint8List buildPatch({
  required List<List<int>> control,
  required List<int> diff,
  required List<int> extra,
  required int newSize,
}) {
  final ctrlRaw = BytesBuilder();
  for (final t in control) {
    ctrlRaw.add(offtout(t[0]));
    ctrlRaw.add(offtout(t[1]));
    ctrlRaw.add(offtout(t[2]));
  }
  final ctrlBz = BZip2Encoder().encodeBytes(ctrlRaw.toBytes());
  final diffBz = BZip2Encoder().encodeBytes(Uint8List.fromList(diff));
  final extraBz = BZip2Encoder().encodeBytes(Uint8List.fromList(extra));

  final out = BytesBuilder();
  out.add(ascii.encode('BSDIFF40'));
  out.add(offtout(ctrlBz.length));
  out.add(offtout(diffBz.length));
  out.add(offtout(newSize));
  out.add(ctrlBz);
  out.add(diffBz);
  out.add(extraBz);
  return out.toBytes();
}

/// A trivially-correct patch that reproduces [newBytes] entirely from the extra
/// block, ignoring the old file — the simplest valid old→new transform.
Uint8List allExtraPatch(List<int> newBytes) => buildPatch(
      control: [
        [0, newBytes.length, 0],
      ],
      diff: const [],
      extra: newBytes,
      newSize: newBytes.length,
    );
