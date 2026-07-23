import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/fitness_provider.dart';
import '../services/update_service.dart';
import 'markdown_text.dart';

/// Dark-themed update bottom-sheet.
///
/// Shows the update straight away and **downloads visibly**: if the APK is
/// already downloaded it offers a one-tap Install; otherwise it starts the
/// download immediately with a live progress bar (resuming any partial), then
/// switches to Install when it's ready. "Later" keeps the downloaded file.
Future<void> showUpdateDialog(
  BuildContext context,
  AppUpdateInfo info,
  UpdateService service,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    isDismissible: true,
    builder: (_) => _UpdateSheet(info: info, service: service),
  );
}

class _UpdateSheet extends StatefulWidget {
  final AppUpdateInfo info;
  final UpdateService service;
  const _UpdateSheet({required this.info, required this.service});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  _Phase _phase = _Phase.preparing;
  double _progress = 0;
  String? _error;
  File? _file;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  /// Offer Install if the APK is already downloaded; otherwise start the
  /// download right away so the user always sees *something* happening.
  Future<void> _prepare() async {
    final ready = await widget.service
        .readyApk(widget.info.build, expectedBytes: widget.info.sizeBytes);
    if (!mounted) return;
    if (ready != null) {
      setState(() {
        _file = ready;
        _phase = _Phase.ready;
      });
    } else {
      _startDownload();
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.service.downloadApk(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _file = file;
        _phase = _Phase.ready;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = 'Download failed. Check your connection and try again.';
        });
      }
    }
  }

  Future<void> _install() async {
    final file = _file;
    if (file == null) return;
    setState(() => _phase = _Phase.installing);
    try {
      // Guard the brief install/reboot gap for THIS build so the same version
      // doesn't re-prompt mid-install (a newer release still will).
      await context.read<FitnessProvider>().markUpdateInitiated(widget.info.build);
      await widget.service.install(file);
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
    // Keep the downloaded (or downloading) file so installing later costs no
    // re-download — it's purged only once the user is on the latest version.
    context.read<FitnessProvider>().snoozeUpdate(widget.info.build);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sizeMb = widget.info.sizeBytes > 0
        ? '${(widget.info.sizeBytes / 1048576).toStringAsFixed(0)} MB'
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
                    Expanded(
                      child: Text(
                        _phase == _Phase.ready || _phase == _Phase.installing
                            ? 'Update ready to install'
                            : 'Update available',
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white),
                      ),
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
                      constraints: const BoxConstraints(maxHeight: 180),
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
                  ..._phaseUI(),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _phaseUI() {
    switch (_phase) {
      case _Phase.preparing:
      case _Phase.downloading:
        final pct = (_progress * 100).clamp(0, 100).toInt();
        return [
          LinearProgressIndicator(
            value: _phase == _Phase.downloading && _progress > 0 ? _progress : null,
            backgroundColor: const Color(0xFF2C2C2E),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF30D158)),
            minHeight: 6,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 8),
          Text(
            _phase == _Phase.preparing
                ? 'Preparing…'
                : _progress > 0
                    ? 'Downloading in the background… $pct%'
                    : 'Starting download…',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
          ),
          const SizedBox(height: 12),
          // Let the user dismiss while it keeps downloading (resumes next time).
          SizedBox(
            width: double.infinity,
            child: _Button(label: 'Later', primary: false, onPressed: _later),
          ),
        ];
      case _Phase.installing:
        return const [
          LinearProgressIndicator(
            value: 1,
            backgroundColor: Color(0xFF2C2C2E),
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF30D158)),
            minHeight: 6,
          ),
          SizedBox(height: 8),
          Text('Opening installer…',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
          SizedBox(height: 16),
        ];
      case _Phase.error:
        return [
          Text(_error ?? '',
              style: const TextStyle(color: Color(0xFFFF453A), fontSize: 13)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _Button(
                label: 'Retry',
                primary: true,
                onPressed: _file != null ? _install : _startDownload,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Button(label: 'Later', primary: false, onPressed: _later),
            ),
          ]),
        ];
      case _Phase.ready:
        return [
          Row(children: [
            Expanded(
              child: _Button(label: 'Later', primary: false, onPressed: _later),
            ),
            const SizedBox(width: 10),
            Expanded(
              child:
                  _Button(label: 'Install now', primary: true, onPressed: _install),
            ),
          ]),
        ];
    }
  }
}

enum _Phase { preparing, downloading, ready, installing, error }

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
