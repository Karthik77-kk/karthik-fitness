import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Applies a classic **bsdiff (BSDIFF40)** binary patch — the format the `bsdiff`
/// CLI produces in CI — to reconstruct a new file from an old one.
///
/// A BSDIFF40 patch is a 32-byte header followed by three bzip2-compressed
/// blocks: a *control* stream of (add, copy-extra, old-seek) triples, a *diff*
/// stream, and an *extra* stream. Reconstruction walks the control triples: for
/// each it writes `add` bytes computed as `diff[i] + old[oldpos+i]`, then `copy`
/// verbatim bytes from the extra stream, then seeks `old` by a signed offset.
/// Regions identical between old and new become long add-runs whose diff bytes
/// are all zero — which is why changing a few KB of compiled Dart yields a patch
/// of a few KB even though the surrounding zip entries shift.
///
/// ### Memory
/// [applyToFile] (the production path) never holds a full copy of the ~170 MB
/// APK in the Dart heap:
///   * the **old** APK is read through a [RandomAccessFile] (random seeks only);
///   * the **diff** and **extra** blocks — which decompress to *roughly the new
///     file's size* (long near-zero diff runs that bzip2 crushes on disk but
///     expand in RAM) — are streamed straight to temp files, then read back
///     sequentially;
///   * the reconstructed APK is written out through an [IOSink] in ≤1 MB chunks.
/// Peak heap is therefore a few MB of buffers, not the file size.
///
/// Any malformed/truncated patch throws — the caller treats that as "no patch"
/// and falls back to a full download.
class ApkPatcher {
  ApkPatcher._();

  static const _magic = 'BSDIFF40';
  static const _chunk = 1 << 20; // 1 MB working buffer

  /// In-memory apply — used by tests and small inputs. Returns the reconstructed
  /// bytes. Decompresses all three blocks into the heap, so do **not** use it on
  /// APK-sized inputs (use [applyToFile]). Throws on a malformed patch.
  static Uint8List apply(Uint8List oldBytes, Uint8List patch) {
    final (diffStart, extraStart, newSize) = _header(patch);
    final ctrl = BZip2Decoder().decodeBytes(Uint8List.sublistView(patch, 32, diffStart));
    final diff = BZip2Decoder().decodeBytes(Uint8List.sublistView(patch, diffStart, extraStart));
    final extra = BZip2Decoder().decodeBytes(Uint8List.sublistView(patch, extraStart, patch.length));

    var diffCur = 0, extraCur = 0;
    final out = BytesBuilder();
    _reconstruct(
      ctrl: ctrl,
      oldSize: oldBytes.length,
      newSize: newSize,
      diffLen: diff.length,
      extraLen: extra.length,
      readOld: (pos, len) => Uint8List.sublistView(oldBytes, pos, pos + len),
      readDiff: (len) {
        final s = Uint8List.fromList(Uint8List.sublistView(diff, diffCur, diffCur + len));
        diffCur += len;
        return s;
      },
      readExtra: (len) {
        final s = Uint8List.sublistView(extra, extraCur, extraCur + len);
        extraCur += len;
        return s;
      },
      writeOut: out.add,
    );
    return out.toBytes();
  }

  /// File-based apply — the production path. Reconstructs the file at [outPath]
  /// from the old file at [oldPath] plus [patch], keeping peak memory small.
  /// Throws on a malformed patch (caller falls back to a full download); always
  /// cleans up its scratch files.
  static Future<void> applyToFile({
    required String oldPath,
    required Uint8List patch,
    required String outPath,
  }) async {
    final (diffStart, extraStart, newSize) = _header(patch);
    final ctrl = BZip2Decoder().decodeBytes(Uint8List.sublistView(patch, 32, diffStart));

    // Stream-decompress the two large blocks to disk instead of the heap.
    final diffTmp = '$outPath.dpart';
    final extraTmp = '$outPath.epart';
    final diffLen = _bunzipToFile(Uint8List.sublistView(patch, diffStart, extraStart), diffTmp);
    final extraLen = _bunzipToFile(Uint8List.sublistView(patch, extraStart, patch.length), extraTmp);

    final oldRaf = File(oldPath).openSync();
    final diffRaf = File(diffTmp).openSync();
    final extraRaf = File(extraTmp).openSync();
    final sink = File(outPath).openWrite();
    try {
      _reconstruct(
        ctrl: ctrl,
        oldSize: oldRaf.lengthSync(),
        newSize: newSize,
        diffLen: diffLen,
        extraLen: extraLen,
        readOld: (pos, len) {
          oldRaf.setPositionSync(pos);
          return oldRaf.readSync(len);
        },
        readDiff: (len) => diffRaf.readSync(len),
        readExtra: (len) => extraRaf.readSync(len),
        writeOut: sink.add,
      );
    } finally {
      await sink.flush();
      await sink.close();
      oldRaf.closeSync();
      diffRaf.closeSync();
      extraRaf.closeSync();
      _tryDeleteSync(diffTmp);
      _tryDeleteSync(extraTmp);
    }
  }

  // ── header ────────────────────────────────────────────────────────────────
  /// Parses + validates the 32-byte header, returning the diff/extra block byte
  /// offsets and the reconstructed file's size.
  static (int diffStart, int extraStart, int newSize) _header(Uint8List patch) {
    if (patch.length < 32) {
      throw const FormatException('bsdiff patch shorter than its 32-byte header');
    }
    if (String.fromCharCodes(patch, 0, 8) != _magic) {
      throw const FormatException('not a BSDIFF40 patch (bad magic)');
    }
    final ctrlLen = _offtin(patch, 8);
    final diffLen = _offtin(patch, 16);
    final newSize = _offtin(patch, 24);
    if (ctrlLen < 0 || diffLen < 0 || newSize < 0) {
      throw const FormatException('bsdiff header has a negative length');
    }
    final diffStart = 32 + ctrlLen;
    final extraStart = diffStart + diffLen;
    if (extraStart > patch.length) {
      throw const FormatException('bsdiff patch truncated (block lengths exceed file)');
    }
    return (diffStart, extraStart, newSize);
  }

  // ── core reconstruction (shared by both paths) ─────────────────────────────
  static void _reconstruct({
    required Uint8List ctrl,
    required int oldSize,
    required int newSize,
    required int diffLen,
    required int extraLen,
    required Uint8List Function(int pos, int len) readOld,
    required Uint8List Function(int len) readDiff,
    required Uint8List Function(int len) readExtra,
    required void Function(Uint8List chunk) writeOut,
  }) {
    var oldpos = 0, newpos = 0, ctrlpos = 0, diffUsed = 0, extraUsed = 0;

    while (newpos < newSize) {
      if (ctrlpos + 24 > ctrl.length) {
        throw const FormatException('bsdiff control block exhausted before new file complete');
      }
      final addLen = _offtin(ctrl, ctrlpos);
      final extraCopyLen = _offtin(ctrl, ctrlpos + 8);
      final oldSeek = _offtin(ctrl, ctrlpos + 16);
      ctrlpos += 24;

      // add-run: new = diff + old (where the old index falls inside the file).
      if (addLen < 0 || newpos + addLen > newSize || diffUsed + addLen > diffLen) {
        throw const FormatException('bsdiff add-run out of bounds');
      }
      var done = 0;
      while (done < addLen) {
        final n = (addLen - done) < _chunk ? (addLen - done) : _chunk;
        final buf = readDiff(n);
        if (buf.length != n) throw const FormatException('short read from bsdiff diff block');
        // old bytes overlap this sub-run where 0 <= subStart+i < oldSize.
        final subStart = oldpos + done;
        var lo = subStart < 0 ? -subStart : 0;
        var hi = n;
        if (subStart + hi > oldSize) hi = oldSize - subStart;
        if (hi > lo) {
          final oldSlice = readOld(subStart + lo, hi - lo);
          for (var i = lo; i < hi; i++) {
            buf[i] = (buf[i] + oldSlice[i - lo]) & 0xFF;
          }
        }
        writeOut(buf);
        done += n;
      }
      newpos += addLen;
      oldpos += addLen;
      diffUsed += addLen;

      // extra-run: verbatim new bytes.
      if (extraCopyLen < 0 || newpos + extraCopyLen > newSize || extraUsed + extraCopyLen > extraLen) {
        throw const FormatException('bsdiff extra-run out of bounds');
      }
      var edone = 0;
      while (edone < extraCopyLen) {
        final n = (extraCopyLen - edone) < _chunk ? (extraCopyLen - edone) : _chunk;
        final buf = readExtra(n);
        if (buf.length != n) throw const FormatException('short read from bsdiff extra block');
        writeOut(buf);
        edone += n;
      }
      newpos += extraCopyLen;
      extraUsed += extraCopyLen;

      oldpos += oldSeek;
    }
  }

  /// Stream-decompresses one bzip2 [compressed] block to [path]; returns the
  /// decompressed length.
  static int _bunzipToFile(Uint8List compressed, String path) {
    final input = InputMemoryStream(compressed);
    final output = OutputFileStream(path);
    BZip2Decoder().decodeStream(input, output);
    output.closeSync();
    return File(path).lengthSync();
  }

  /// bsdiff's sign-magnitude little-endian int64 ("offtin"): 8 LE bytes with the
  /// high bit of the last byte used as the sign flag (not two's complement).
  static int _offtin(List<int> buf, int off) {
    var y = buf[off + 7] & 0x7F;
    y = y * 256 + buf[off + 6];
    y = y * 256 + buf[off + 5];
    y = y * 256 + buf[off + 4];
    y = y * 256 + buf[off + 3];
    y = y * 256 + buf[off + 2];
    y = y * 256 + buf[off + 1];
    y = y * 256 + buf[off];
    return (buf[off + 7] & 0x80) != 0 ? -y : y;
  }

  static void _tryDeleteSync(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {/* best-effort scratch cleanup */}
  }
}
