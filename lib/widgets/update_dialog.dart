import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../services/update_service.dart';
import 'markdown_text.dart';

/// Shows a dark-themed update bottom-sheet.
///
/// When [readyFile] is provided the APK is already downloaded, so the sheet
/// offers a one-tap **Install** (no download). When it's null the sheet falls
/// back to downloading on tap (used by the manual "Check for updates" path).
Future<void> showUpdateDialog(
  BuildContext context,
  AppUpdateInfo info,
  UpdateService service, {
  File? readyFile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _UpdateSheet(info: info, service: service, readyFile: readyFile),
  );
}

class _UpdateSheet extends StatefulWidget {
  final AppUpdateInfo info;
  final UpdateService service;
  final File? readyFile;
  const _UpdateSheet({required this.info, required this.service, this.readyFile});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      // Guard the brief install/reboot gap for THIS build so the same version
      // doesn't re-prompt mid-install (a newer release still will).
      await context.read<FitnessProvider>().markUpdateInitiated(widget.info.build);

      // Re-fetch the latest release right before downloading. If a newer build
      // was published between the initial check and the user tapping Update,
      // this ensures we download the TRUE latest rather than latest-1.
      final freshInfo = await widget.service.fetchLatestInfo();
      final infoToDownload =
          (freshInfo != null && freshInfo.build >= widget.info.build)
              ? freshInfo
              : widget.info;

      final file = await widget.service.downloadApk(
        infoToDownload,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.installing);
      await widget.service.install(file);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = 'Download failed. Check your connection and try again.';
        });
      }
    }
  }

  /// One-tap install of an already-downloaded APK (no network).
  Future<void> _install() async {
    setState(() {
      _phase = _Phase.installing;
      _error = null;
    });
    try {
      await context.read<FitnessProvider>().markUpdateInitiated(widget.info.build);
      await widget.service.install(widget.readyFile!);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = 'Could not open the installer. Try again.';
        });
      }
    }
  }

  void _later() {
    // Keep the downloaded file so "Later" never costs a re-download — it's
    // purged only once the user is actually on the latest version.
    context.read<FitnessProvider>().snoozeUpdate(widget.info.build);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sizeMb = widget.info.sizeBytes > 0
        ? '${(widget.info.sizeBytes / 1048576).toStringAsFixed(1)} MB'
        : '';

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF48484A),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.system_update_rounded,
                        color: Color(0xFF30D158), size: 22),
                    const SizedBox(width: 10),
                    Text(
                      widget.readyFile != null
                          ? 'Update ready to install'
                          : 'Update available',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(
                      widget.info.versionName,
                      style: const TextStyle(
                          color: Color(0xFF30D158),
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    if (sizeMb.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Text(sizeMb,
                          style: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 12)),
                    ],
                  ]),
                  if (widget.info.notes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    const Text("What's new",
                        style: TextStyle(
                            color: Color(0xFF8E8E93),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: SingleChildScrollView(
                        child: MarkdownText(
                          widget.info.notes,
                          baseStyle: const TextStyle(
                              color: Color(0xFFE5E5EA), fontSize: 13, height: 1.5),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (_phase == _Phase.downloading || _phase == _Phase.installing) ...[
                    LinearProgressIndicator(
                      value: _phase == _Phase.installing ? 1 : _progress,
                      backgroundColor: const Color(0xFF2C2C2E),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Color(0xFF30D158)),
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phase == _Phase.installing
                          ? 'Installing…'
                          : _progress > 0
                              ? '${(_progress * 100).toInt()}%'
                              : 'Starting download…',
                      style: const TextStyle(
                          color: Color(0xFF8E8E93), fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                  ] else if (_phase == _Phase.error) ...[
                    Text(_error ?? '',
                        style: const TextStyle(
                            color: Color(0xFFFF453A), fontSize: 13)),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: _Button(
                          label: 'Retry',
                          primary: true,
                          onPressed:
                              widget.readyFile != null ? _install : _download,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Button(
                          label: 'Later',
                          primary: false,
                          onPressed: _later,
                        ),
                      ),
                    ]),
                  ] else ...[
                    Row(children: [
                      Expanded(
                        child: _Button(
                          label: 'Later',
                          primary: false,
                          onPressed: _later,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Button(
                          label: widget.readyFile != null ? 'Install' : 'Update',
                          primary: true,
                          onPressed:
                              widget.readyFile != null ? _install : _download,
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Phase { idle, downloading, installing, error }

class _Button extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onPressed;
  const _Button(
      {required this.label, required this.primary, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: primary
          ? ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8E8E93),
                side: const BorderSide(color: Color(0xFF3A3A3C)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(label),
            ),
    );
  }
}
