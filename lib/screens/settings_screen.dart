import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../app_info.dart';
import '../models/models.dart' show GoalDirection;
import '../theme/app_tokens.dart';
import '../providers/fitness_provider.dart';
import '../services/cloud_backup_service.dart';
import '../services/haptics.dart';
import '../services/on_device_ai_service.dart';
import '../services/gemini_text_service.dart';
import '../widgets/input_formatters.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';
import 'chat_screen.dart' show openChat;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _exporting = false;
  bool _importing = false;

  // Cloud sync (GitHub) state
  bool _cloudBusy = false;
  // Optimistic: if token+repo are baked in, we're configured from frame one
  // (avoids briefly flashing the in-app "Set up" tile before _loadCloud runs).
  bool _cloudConfigured = CloudBackupService.hasCompiledConfig;
  String? _cloudRepo;
  String? _cloudUser;
  String? _cloudId;
  int _cloudLastMs = 0;
  bool _cloudAuto = true;

  @override
  void initState() {
    super.initState();
    _loadCloud();
  }

  String _relativeTime(int ms) {
    if (ms <= 0) return 'never';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _loadCloud() async {
    final svc = CloudBackupService.instance;
    final configured = await svc.isConfigured();
    final repo = await svc.configuredRepo();
    final u = await svc.username();
    final id = await svc.userId();
    final last = await svc.lastBackupMs();
    final auto = await svc.autoBackupEnabled();
    if (mounted) {
      setState(() {
        _cloudConfigured = configured;
        _cloudRepo = repo;
        _cloudUser = u;
        _cloudId = id;
        _cloudLastMs = last;
        _cloudAuto = auto;
      });
    }
  }

  /// Enter (or change) the GitHub token + repo that cloud sync uses. Stored
  /// on-device — keeps the token out of the shipped APK.
  Future<void> _setupCloud() async {
    final tokenCtrl = TextEditingController();
    final repoCtrl = TextEditingController(text: _cloudRepo ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Set up cloud sync',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Paste a GitHub token (Contents read/write on a PRIVATE repo) and '
            'the repo as owner/name. Stored only on this device.',
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: repoCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration:
                const InputDecoration(hintText: 'owner/name (e.g. you/kfit-data)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: tokenCtrl,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'github_pat_… token'),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          ElevatedButton(
            onPressed: () {
              if (tokenCtrl.text.trim().isEmpty ||
                  !CloudBackupService.isValidRepo(repoCtrl.text)) {
                ScaffoldMessenger.of(dCtx).showSnackBar(const SnackBar(
                    content: Text('Enter a token and a valid owner/name repo'),
                    duration: Duration(seconds: 1)));
                return;
              }
              Navigator.pop(dCtx, true);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158)),
            child: const Text('Save',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (saved == true) {
      await CloudBackupService.instance
          .saveConfig(token: tokenCtrl.text, repo: repoCtrl.text);
      await _loadCloud();
    }
    tokenCtrl.dispose();
    repoCtrl.dispose();
  }

  Future<void> _disconnectCloud() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Disconnect cloud sync?',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          'Removes the saved token + repo from this device. Your data and cloud '
          'backups are untouched.',
          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Disconnect',
                style: TextStyle(color: Color(0xFFFF453A))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await CloudBackupService.instance.clearConfig();
      await _loadCloud();
    }
  }

  Future<void> _setCloudAccount() async {
    final userCtrl = TextEditingController(text: _cloudUser ?? '');
    final idCtrl = TextEditingController(text: _cloudId ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        bool checking = false;
        String? error;
        return StatefulBuilder(builder: (dCtx, setD) {
          Future<void> onSave() async {
            final name = userCtrl.text;
            final id = idCtrl.text;
            if (!CloudBackupService.isValidAccount(name, id)) {
              setD(() => error = 'Enter a name and a numeric id.');
              return;
            }
            // Skip the uniqueness check when it's the account already set here.
            final isOwn = CloudBackupService.filePathFor(name, id) ==
                CloudBackupService.filePathFor(_cloudUser ?? '', _cloudId ?? '');
            if (!isOwn) {
              setD(() {
                checking = true;
                error = null;
              });
              final taken =
                  await CloudBackupService.instance.accountExists(name, id);
              if (taken) {
                setD(() {
                  checking = false;
                  error = 'That name + id is taken — use a unique id. '
                      '(If it\'s yours, use "Restore from cloud" instead.)';
                });
                return;
              }
            }
            if (dCtx.mounted) Navigator.pop(dCtx, true);
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E22),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Text('Your name & id',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                'Pick a name and a private 6-digit id you\'ll remember — together '
                'they identify your backup. Keep the id secret (it stays hidden, '
                'shown as ••••••). Use the same pair on any device to restore.',
                style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(hintText: 'Your name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: idCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: positiveIntInput,
                obscureText: true, // secret id — never shown in plain text
                style: const TextStyle(color: Colors.white),
                decoration:
                    const InputDecoration(hintText: '6-digit secret id'),
              ),
              if (checking) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!,
                    style: const TextStyle(
                        color: Color(0xFFFF453A), fontSize: 12, height: 1.3)),
              ],
            ]),
            actions: [
              TextButton(
                onPressed:
                    checking ? null : () => Navigator.pop(dCtx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: Color(0xFF8E8E93))),
              ),
              ElevatedButton(
                onPressed: checking ? null : onSave,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF30D158)),
                child: const Text('Save',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
      },
    );
    if (saved == true) {
      await CloudBackupService.instance.saveAccount(userCtrl.text, idCtrl.text);
      await _loadCloud();
    }
    userCtrl.dispose();
    idCtrl.dispose();
  }

  Future<void> _cloudBackup() async {
    setState(() => _cloudBusy = true);
    try {
      final json = await context.read<FitnessProvider>().buildBackupJson();
      final msg = await CloudBackupService.instance.backup(json);
      await context.read<FitnessProvider>().markBackedUp();
      await _loadCloud();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('☁️ $msg'),
            backgroundColor: const Color(0xFF30D158)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Cloud backup failed: $e'),
            backgroundColor: const Color(0xFFFF453A)));
      }
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _cloudRestore() async {
    final userCtrl = TextEditingController(text: _cloudUser ?? '');
    final idCtrl = TextEditingController(text: _cloudId ?? '');
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Restore from cloud',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Enter the username and id you backed up with. This overwrites ALL '
            'current data on this device.',
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: userCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'Your name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: idCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: positiveIntInput,
            obscureText: true, // secret id — never shown in plain text
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: '6-digit secret id'),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Restore', style: TextStyle(color: Color(0xFFFF453A))),
          ),
        ],
      ),
    );
    if (go == true) {
      setState(() => _cloudBusy = true);
      try {
        final json = await CloudBackupService.instance
            .restore(userCtrl.text, idCtrl.text);
        if (json == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('No backup found for that username + id'),
                backgroundColor: Color(0xFFFF9F0A)));
          }
        } else {
          final ok =
              await context.read<FitnessProvider>().importFromJsonString(json);
          await CloudBackupService.instance
              .saveAccount(userCtrl.text, idCtrl.text);
          await _loadCloud();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok
                    ? '✅ Restored from cloud!'
                    : '❌ Backup file was invalid'),
                backgroundColor:
                    ok ? const Color(0xFF30D158) : const Color(0xFFFF453A)));
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Restore failed: $e'),
              backgroundColor: const Color(0xFFFF453A)));
        }
      } finally {
        if (mounted) setState(() => _cloudBusy = false);
      }
    }
    userCtrl.dispose();
    idCtrl.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final path = await context.read<FitnessProvider>().exportAllData();
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'K Fitness Backup',
        text: 'Your K Fitness data backup — save this file safely.',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: const Color(0xFFFF453A)),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: 'Select K Fitness backup',
      );
      if (result != null && result.files.single.path != null) {
        // Confirm before overwriting all current data
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E22),
            title: const Text('Replace all data?'),
            content: const Text(
              'This will overwrite ALL your current data with the backup. This cannot be undone.',
              style: TextStyle(color: Color(0xFF8E8E93)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restore', style: TextStyle(color: Color(0xFFFF453A))),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        final ok = await context.read<FitnessProvider>()
            .importAllData(result.files.single.path!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok
                ? '✅ Data restored successfully!'
                : '❌ Import failed — invalid backup file'),
            backgroundColor: ok ? const Color(0xFF30D158) : const Color(0xFFFF453A),
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import error: $e'), backgroundColor: const Color(0xFFFF453A)),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _editName(FitnessProvider p) {
    final ctrl = TextEditingController(text: p.userName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        title: const Text('Your Name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter your name'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158), foregroundColor: Colors.black),
            onPressed: () {
              p.saveUserName(ctrl.text);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }


  void _editGoal({
    required String label,
    required int current,
    required int min,
    required int max,
    required int step,
    required Future<void> Function(int) onSave,
  }) {
    final ctrl = TextEditingController(text: current.toString());
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E22),
        title: Text(label, style: const TextStyle(fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: positiveIntInput,
            decoration: InputDecoration(
              hintText: 'Between $min – $max',
              helperText: 'Range: $min – $max  (step: $step)',
              helperStyle: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF30D158), foregroundColor: Colors.black),
            onPressed: () async {
              final parsed = int.tryParse(ctrl.text.trim());
              if (parsed != null) {
                // Enforce the advertised range — an out-of-range goal (e.g. 0 or
                // 50000 kcal) would break deficit/progress maths downstream.
                await onSave(parsed.clamp(min, max));
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── PROFILE ──────────────────────────────────────────────
          _Header('Profile'),
          _Tile(
            icon: Icons.person_outline,
            title: 'Name',
            subtitle: p.userName,
            onTap: () => _editName(p),
          ),
          _Tile(
            icon: Icons.height,
            title: 'Height',
            subtitle: '${p.heightCm.round()} cm (${(p.heightCm / 30.48).toStringAsFixed(1)} ft) — edit in Stats tab',
            onTap: null,
          ),
          const SizedBox(height: 20),


          // ── SMART RECOMMENDATIONS ────────────────────────────────
          if (p.hasGoalRecommendations) ...[
            _Header('Smart Recommendations'),
            _SmartGoalsTile(p: p),
            const SizedBox(height: 20),
          ],

          // ── GOALS ─────────────────────────────────────────────────
          _Header('Goals'),
          _GoalDirectionTile(),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.flag_outlined,
            title: 'Daily Calorie Goal',
            subtitle: '${p.calorieGoal} kcal — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Calorie Goal (kcal)',
              current: p.calorieGoal,
              min: 800, max: 5000, step: 50,
              onSave: (v) => p.saveCalorieGoal(v),
            ),
          ),
          _Tile(
            icon: Icons.fitness_center_outlined,
            title: 'Daily Protein Goal',
            subtitle: '${p.proteinGoal}g protein — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Protein Goal (g)',
              current: p.proteinGoal,
              min: 20, max: 300, step: 5,
              onSave: (v) => p.saveProteinGoal(v),
            ),
          ),
          _Tile(
            icon: Icons.grain_outlined,
            title: 'Daily Carb Goal',
            subtitle: '${p.carbGoal}g carbs — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Carb Goal (g)',
              current: p.carbGoal,
              min: 20, max: 600, step: 5,
              onSave: (v) => p.saveCarbGoal(v),
            ),
          ),
          _Tile(
            icon: Icons.opacity_outlined,
            title: 'Daily Fat Goal',
            subtitle: '${p.fatGoal}g fat — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Fat Goal (g)',
              current: p.fatGoal,
              min: 10, max: 300, step: 5,
              onSave: (v) => p.saveFatGoal(v),
            ),
          ),
          _Tile(
            icon: Icons.directions_walk_outlined,
            title: 'Daily Step Goal',
            subtitle: '${p.stepGoal.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')} steps — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Step Goal',
              current: p.stepGoal,
              min: 1000, max: 30000, step: 500,
              onSave: (v) => p.saveStepGoal(v),
            ),
          ),
          _Tile(
            icon: Icons.water_drop_outlined,
            title: 'Daily Water Goal',
            subtitle: '${p.waterGoalMl} ml — tap to change',
            onTap: () => _editGoal(
              label: 'Daily Water Goal (ml)',
              current: p.waterGoalMl,
              min: 500, max: 8000, step: 100,
              onSave: (v) => p.saveWaterGoal(v),
            ),
          ),
          const SizedBox(height: 20),

          // ── PREFERENCES ───────────────────────────────────────────
          _Header('Preferences'),
          _HapticsTile(),
          const SizedBox(height: 20),

          // ── AI COACH ──────────────────────────────────────────────
          _Header('AI Coach'),
          _AiCoachEnabledTile(),
          // Daily brief has its own switch — it stays available even with the
          // chat coach off. Only meaningful when a cloud key powers it.
          if (GeminiTextService.isConfigured) ...[
            const SizedBox(height: 8),
            _AiBriefEnabledTile(),
          ],
          if (p.aiCoachEnabled) ...[
            // Engine picker (only when a cloud key is compiled in — else on-device only).
            if (GeminiTextService.isConfigured) ...[
              const SizedBox(height: 8),
              _AiCoachModeTile(),
            ],
            if (p.aiCoachMode == AiCoachMode.local) ...[
              const SizedBox(height: 8),
              const _AiStatusTile(),
              const SizedBox(height: 8),
              _AiAutoLoadTile(),
            ] else ...[
              const SizedBox(height: 8),
              const _CloudCoachInfoTile(),
            ],
          ],
          const SizedBox(height: 20),

          // ── DATA ──────────────────────────────────────────────────
          _Header('Data & Backup'),
          if (p.needsBackupReminder)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFF9F0A).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: const Color(0xFFFF9F0A).withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.backup_outlined,
                    color: Color(0xFFFF9F0A), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.daysSinceBackup == null
                        ? "You've never backed up. Your data lives only on this device — export it so an uninstall can't wipe it."
                        : 'Last backup was ${p.daysSinceBackup} days ago. Export a fresh copy to stay safe.',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12, height: 1.35),
                  ),
                ),
              ]),
            ),
          _Tile(
            icon: Icons.upload_rounded,
            title: 'Export Data',
            subtitle: p.daysSinceBackup == null
                ? 'Share your backup as a JSON file'
                : 'Last backup: ${p.daysSinceBackup == 0 ? 'today' : '${p.daysSinceBackup}d ago'} · share a fresh copy',
            trailing: _exporting
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share_outlined, color: Color(0xFF30D158), size: 20),
            onTap: _exporting ? null : _export,
          ),
          _Tile(
            icon: Icons.download_rounded,
            title: 'Import Data',
            subtitle: 'Restore from a backup JSON file',
            trailing: _importing
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.folder_open_outlined, color: Color(0xFF30D158), size: 20),
            onTap: _importing ? null : _import,
          ),

          // ── CLOUD SYNC (GitHub) ───────────────────────────────────
          const SizedBox(height: 20),
          _Header('Cloud Sync'),
          if (!_cloudConfigured)
            _Tile(
              icon: Icons.cloud_sync_outlined,
              title: 'Set up cloud sync',
              subtitle:
                  'Connect a private GitHub repo (token + owner/name) to back '
                  'up & restore by username + id.',
              onTap: _cloudBusy ? null : _setupCloud,
            )
          else ...[
            // Repo/token management is hidden when the token+repo are baked in
            // at build (the normal shipped case) — testers only enter name + id.
            if (!CloudBackupService.hasCompiledConfig)
              _Tile(
                icon: Icons.cloud_done_outlined,
                title: 'Connected repo',
                subtitle: '${_cloudRepo ?? '—'} — tap to change token/repo',
                trailing: IconButton(
                  icon: const Icon(Icons.link_off_rounded,
                      color: Color(0xFFFF453A), size: 20),
                  tooltip: 'Disconnect',
                  onPressed: _cloudBusy ? null : _disconnectCloud,
                ),
                onTap: _cloudBusy ? null : _setupCloud,
              ),
            _Tile(
              icon: Icons.badge_outlined,
              title: 'Your name & secret id',
              subtitle: (_cloudUser?.isNotEmpty == true)
                  ? '$_cloudUser · id •••••• (hidden) — tap to change'
                  : 'Set a name + a private 6-digit id to sync',
              onTap: _cloudBusy ? null : _setCloudAccount,
            ),
            // Auto-backup toggle
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  secondary: const Icon(Icons.sync_rounded,
                      color: Color(0xFF30D158)),
                  title: const Text('Auto-backup',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  subtitle: const Text('On cold launch (~10s) and daily',
                      style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
                  value: _cloudAuto,
                  activeThumbColor: const Color(0xFF30D158),
                  onChanged: _cloudBusy
                      ? null
                      : (v) async {
                          Haptics.impact();
                          await CloudBackupService.instance.setAutoBackup(v);
                          setState(() => _cloudAuto = v);
                        },
                ),
              ),
            ),
            _Tile(
              icon: Icons.cloud_upload_outlined,
              title: 'Back up to cloud',
              subtitle: _cloudLastMs > 0
                  ? 'Last cloud backup: ${_relativeTime(_cloudLastMs)}'
                  : 'Push your data to the private repo',
              trailing: _cloudBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload,
                      color: Color(0xFF40C8E0), size: 20),
              onTap: (_cloudBusy || !(_cloudUser?.isNotEmpty == true))
                  ? null
                  : _cloudBackup,
            ),
            _Tile(
              icon: Icons.cloud_download_outlined,
              title: 'Restore from cloud',
              subtitle: 'Download by username + id (overwrites this device)',
              onTap: _cloudBusy ? null : _cloudRestore,
            ),
          ],

          const SizedBox(height: 20),

          // ── APP UPDATES ───────────────────────────────────────────
          _Header('App Updates'),
          _AutoUpdateEnabledTile(),
          _CheckForUpdatesTile(),
          const SizedBox(height: 20),

          // ── ABOUT ─────────────────────────────────────────────────
          _Header('About'),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (_, snap) {
              // Show the version exactly as the release/website tags it:
              // v<major.minor>.<buildNumber>, where major.minor comes from the
              // compiled version name and buildNumber is the CI commit count
              // (dynamic) — e.g. "v3.0.319". pubspec's "3.0.0" patch segment is
              // a placeholder; the real running build is the commit count.
              // The rare PackageInfo-null fallback uses the same style from
              // app_info so the format never changes between the two paths.
              final info = snap.data;
              String vMajorMinor(String v) =>
                  v.contains('.') ? v.substring(0, v.lastIndexOf('.')) : v;
              final String label = info != null
                  ? 'v${vMajorMinor(info.version)}.${info.buildNumber}'
                  : 'v${vMajorMinor(kAppVersionName)}.$kAppBuild';
              return _Tile(
                icon: Icons.info_outline,
                title: 'K Fitness',
                subtitle: '$label · Personal fitness tracker',
                onTap: null,
              );
            },
          ),
          _Tile(
            icon: Icons.menu_book_outlined,
            title: 'Food data credits',
            subtitle:
                'Indian food data: IFCT 2017, ICMR–National Institute of Nutrition.',
            onTap: null,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Goal-direction selector (lose / maintain / gain) ────────────────────────
class _GoalDirectionTile extends StatelessWidget {
  static String _label(GoalDirection d) => switch (d) {
        GoalDirection.lose => 'Lose',
        GoalDirection.maintain => 'Maintain',
        GoalDirection.gain => 'Gain',
      };

  static String _subtitle(GoalDirection d) => switch (d) {
        GoalDirection.lose => 'Calorie target sits below maintenance for fat loss',
        GoalDirection.maintain => 'Calorie target holds at maintenance',
        GoalDirection.gain => 'Calorie target sits above maintenance for lean gain',
      };

  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    final current = p.goalDirection;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: AppColors.card, borderRadius: AppRadii.rMd),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: const [
          Icon(Icons.swap_vert_rounded, color: AppColors.green, size: 20),
          SizedBox(width: 12),
          Text('Goal',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white)),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Text(_subtitle(current),
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final d in GoalDirection.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                      right: d == GoalDirection.values.last ? 0 : 8),
                  child: _DirChip(
                    label: _label(d),
                    selected: d == current,
                    onTap: () {
                      Haptics.tap();
                      context.read<FitnessProvider>().saveGoalDirection(d);
                    },
                  ),
                ),
              ),
          ],
        ),
      ]),
    );
  }
}

class _DirChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DirChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.green.withValues(alpha: 0.18)
              : AppColors.surface2,
          borderRadius: AppRadii.rSm,
          border: Border.all(
              color: selected ? AppColors.green : AppColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? AppColors.green : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ── Haptic feedback toggle ──────────────────────────────────────────────────
class _HapticsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    return Material(
      color: AppColors.card,
      borderRadius: AppRadii.rMd,
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: const Icon(Icons.vibration_rounded, color: AppColors.green),
        title: const Text('Haptic feedback',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          p.hapticsEnabled
              ? 'Subtle vibrations on taps, toggles & scrolling'
              : 'Off — no vibrations',
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        value: p.hapticsEnabled,
        activeThumbColor: AppColors.green,
        onChanged: (v) {
          context.read<FitnessProvider>().saveHapticsEnabled(v);
          if (v) Haptics.impact(); // confirm ON with a clearly-felt tap
        },
      ),
    );
  }
}

/// Direction-aware "why" line under the calorie recommendation row.
String _calorieReason(FitnessProvider p) {
  final base = p.bestTdee?.round().toString() ?? '—';
  final calibrated = p.isTdeeCalibrated;
  switch (p.goalDirection) {
    case GoalDirection.lose:
      return calibrated
          ? 'Real maintenance $base kcal − 500 ✓ calibrated'
          : 'Est. TDEE $base kcal − 500 (0.5 kg/wk loss)';
    case GoalDirection.maintain:
      return calibrated
          ? 'Real maintenance $base kcal ✓ calibrated'
          : 'Est. TDEE $base kcal (hold weight)';
    case GoalDirection.gain:
      return calibrated
          ? 'Real maintenance $base kcal + 350 ✓ calibrated'
          : 'Est. TDEE $base kcal + 350 (lean gain)';
  }
}

// ── Smart goal recommendations tile ─────────────────────────────────────────

class _SmartGoalsTile extends StatelessWidget {
  final FitnessProvider p;
  const _SmartGoalsTile({required this.p});

  @override
  Widget build(BuildContext context) {
    final rCal  = p.recommendedCalorieGoal?.round();
    final rProt = p.recommendedProteinGoal;
    final rWat  = p.recommendedWaterGoal;
    final rCarb = p.recommendedCarbGoal; // null until a TDEE estimate exists
    final rFat  = p.recommendedFatGoal;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
        border: Border.all(color: const Color(0xFF40C8E0).withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.science_rounded, size: 16, color: Color(0xFF40C8E0)),
          SizedBox(width: 8),
          Expanded(
            child: Text('Calculated from your body data',
                style: TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          p.isTdeeCalibrated
              ? 'Calorie target is calibrated from your REAL weight trend + intake '
                '(not a generic formula). Protein, carbs, fat & water scale with your body:'
              : 'Your current goals vs what your body metrics suggest:',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 12),

        // Calorie row
        if (rCal != null)
          _RecoRow(
            emoji: '🔥',
            label: 'Calories',
            current: '${p.calorieGoal} kcal',
            recommended: '$rCal kcal',
            reason: _calorieReason(p),
            matches: (rCal - p.calorieGoal).abs() <= 50,
          ),

        // Protein row
        _RecoRow(
          emoji: '💪',
          label: 'Protein',
          current: '${p.proteinGoal}g',
          recommended: '${rProt}g',
          reason: p.leanMassKg != null
              ? '2.0 g × ${p.leanMassKg!.toStringAsFixed(1)} kg lean mass'
              : '1.8 g × ${p.latestWeightKg?.toStringAsFixed(1) ?? "?"}kg body weight',
          matches: (rProt - p.proteinGoal).abs() <= 5,
        ),

        // Carbs row (energy left after protein + fat)
        if (rCarb != null)
          _RecoRow(
            emoji: '🍚',
            label: 'Carbs',
            current: '${p.carbGoal}g',
            recommended: '${rCarb}g',
            reason: 'Remaining energy after protein & fat (÷4 kcal/g)',
            matches: (rCarb - p.carbGoal).abs() <= 15,
          ),

        // Fat row (~25% of calories)
        if (rFat != null)
          _RecoRow(
            emoji: '🥑',
            label: 'Fat',
            current: '${p.fatGoal}g',
            recommended: '${rFat}g',
            reason: '~25% of ${rCal ?? "—"} kcal (÷9 kcal/g)',
            matches: (rFat - p.fatGoal).abs() <= 8,
          ),

        // Water row
        _RecoRow(
          emoji: '💧',
          label: 'Water',
          current: '${p.waterGoalMl} ml',
          recommended: '$rWat ml',
          reason: '35 ml × ${p.latestWeightKg?.toStringAsFixed(1) ?? "?"}kg body weight',
          matches: (rWat - p.waterGoalMl).abs() <= 150,
        ),

        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () async {
              Haptics.success();
              if (rCal != null) await p.saveCalorieGoal(rCal);
              await p.saveProteinGoal(rProt);
              if (rCarb != null) await p.saveCarbGoal(rCarb);
              if (rFat != null) await p.saveFatGoal(rFat);
              await p.saveWaterGoal(rWat);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ Goals updated from your body data'),
                    backgroundColor: Color(0xFF30D158),
                  ),
                );
              }
            },
            icon: const Icon(Icons.check_circle_outline, size: 16),
            label: const Text('Apply Recommendations'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF30D158),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RecoRow extends StatelessWidget {
  final String emoji;
  final String label;
  final String current;
  final String recommended;
  final String reason;
  final bool   matches;
  const _RecoRow({required this.emoji, required this.label, required this.current,
      required this.recommended, required this.reason, required this.matches});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('$label: ',
                    style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
                Text(current,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const Text(' → ',
                    style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
                Text(recommended,
                    style: TextStyle(
                        color: matches
                            ? const Color(0xFF30D158)
                            : const Color(0xFF40C8E0),
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                if (matches)
                  const Text('  ✓',
                      style: TextStyle(color: Color(0xFF30D158), fontSize: 11)),
              ]),
              Text(reason,
                  style: const TextStyle(
                      color: Color(0xFF8E8E93), fontSize: 10, height: 1.3)),
            ]),
          ),
        ]),
      );
}

// ── AI Coach status tile ──────────────────────────────────────────────────────

class _AiStatusTile extends StatelessWidget {
  const _AiStatusTile();

  static const _kGreen  = Color(0xFF30D158);
  static const _kCard   = Color(0xFF1E1E22);
  static const _kSecond = Color(0xFF8E8E93);

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    final isDownloading = ai.state == AiModelState.downloading;
    final isLoading     = ai.state == AiModelState.loading;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: ai.isReady
              ? _kGreen.withValues(alpha: 0.4)
              : _kSecond.withValues(alpha: 0.15),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🤖', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Gemma 3 1B  ·  ~600 MB  ·  offline',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
            Text(ai.isReady ? 'Ready — tap to chat' : ai.state == AiModelState.notInstalled
                ? 'Download once over Wi-Fi to enable AI chat'
                : ai.state == AiModelState.downloading ? 'Downloading…'
                : ai.state == AiModelState.loading ? 'Loading model…'
                : 'Error',
                style: const TextStyle(color: _kSecond, fontSize: 11, height: 1.4)),
          ])),
          _StatusChip(ai.state),
        ]),

        // Download progress bar
        if (isDownloading) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ai.dlProgress,
              minHeight: 6,
              backgroundColor: const Color(0xFF2C2C2E),
              valueColor: const AlwaysStoppedAnimation(_kGreen),
            ),
          ),
          const SizedBox(height: 4),
          Text('${(ai.dlProgress * 100).round()}% · ${(ai.dlProgress * 600).round()} / ~600 MB',
              style: const TextStyle(color: _kSecond, fontSize: 11)),
        ],

        // Error message
        if (ai.state == AiModelState.error && ai.errorMessage.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(ai.errorMessage,
              style: const TextStyle(color: Color(0xFFFF453A), fontSize: 11)),
        ],

        // Action buttons
        if (isDownloading) ...[
          // Issue #9: Cancel button (visible only when downloading)
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => context.read<OnDeviceAiService>().cancelDownload(),
              icon: const Icon(Icons.close, size: 16, color: Color(0xFFFF453A)),
              label: const Text('Cancel Download'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF453A),
                side: const BorderSide(color: Color(0xFFFF453A)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ] else if (ai.state == AiModelState.error) ...[
          // Issue #10: Retry button (visible only when error)
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.read<OnDeviceAiService>().downloadAndLoad(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry Download'),
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ai.isReady
                ? OutlinedButton.icon(
                    onPressed: () => openChat(context),
                    icon: const Text('💬', style: TextStyle(fontSize: 14)),
                    label: const Text('Open AI Coach Chat'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kGreen,
                      side: const BorderSide(color: _kGreen),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  )
                : isLoading
                    ? const Center(child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
                    : FilledButton.icon(
                        onPressed: () => context.read<OnDeviceAiService>().downloadAndLoad(),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Download AI Model (~600 MB)',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kGreen,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
          ),
        ],
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final AiModelState state;
  const _StatusChip(this.state);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AiModelState.ready        => ('● Ready',      const Color(0xFF30D158)),
      AiModelState.downloading  => ('↓ Downloading', Colors.orange),
      AiModelState.loading      => ('⟳ Loading',    Colors.orange),
      AiModelState.error        => ('✕ Error',       const Color(0xFFFF453A)),
      AiModelState.notInstalled => ('Not installed', const Color(0xFF8E8E93)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}


class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(),
        style: const TextStyle(
            color: Color(0xFF8E8E93), fontSize: 11,
            fontWeight: FontWeight.w600, letterSpacing: 0.8)),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _Tile({required this.icon, required this.title, required this.subtitle, this.trailing, this.onTap});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    // Material (clipped to the rounded shape) carries the colour so the
    // ListTile's ink splashes paint on it and stay visible — wrapping a
    // ListTile directly in a coloured DecoratedBox hides the ink.
    child: Material(
      color: const Color(0xFF1E1E22),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF30D158)),
        title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle, style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
        trailing: trailing ?? (onTap != null
            ? const Icon(Icons.chevron_right, color: Color(0xFF8E8E93))
            : null),
        // A light tick on every tappable settings row (respects the global
        // haptics toggle — a no-op when the user has switched haptics off).
        onTap: onTap == null
            ? null
            : () {
                Haptics.tap();
                onTap!();
              },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

// ── AI Coach enable/disable toggle ────────────────────────────────────────────
class _AiCoachEnabledTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    return Material(
      // Material carries the colour so the SwitchListTile's ink stays visible.
      color: const Color(0xFF1E1E22),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: const Icon(Icons.smart_toy_rounded, color: Color(0xFF30D158)),
        title: const Text('Enable AI Coach',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          p.aiCoachEnabled
              ? 'Shown on Home and available for chat'
              : 'Hidden from Home — turn on to use the coach again',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
        ),
        value: p.aiCoachEnabled,
        activeColor: const Color(0xFF30D158),
        onChanged: (v) {
          Haptics.impact();
          context.read<FitnessProvider>().saveAiCoachEnabled(v);
        },
      ),
    );
  }
}

// ── Daily AI brief toggle (independent of the chat coach) ─────────────────────
class _AiBriefEnabledTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    return Material(
      // Material carries the colour so the SwitchListTile's ink stays visible.
      color: const Color(0xFF1E1E22),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary:
            const Icon(Icons.auto_awesome_rounded, color: Color(0xFF40C8E0)),
        title: const Text('Daily AI brief',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          p.aiBriefEnabled
              ? 'A fresh once-a-day summary on Home — shows even with chat off'
              : 'No daily summary on Home',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
        ),
        value: p.aiBriefEnabled,
        activeColor: const Color(0xFF40C8E0),
        onChanged: (v) {
          Haptics.impact();
          context.read<FitnessProvider>().saveAiBriefEnabled(v);
        },
      ),
    );
  }
}

// ── AI Coach engine picker (on-device Gemma vs cloud Flash-Lite) ──────────────
class _AiCoachModeTile extends StatelessWidget {
  static const _green = Color(0xFF30D158);
  static const _muted = Color(0xFF8E8E93);

  Widget _seg(BuildContext context, String label, IconData icon,
      AiCoachMode mode, String sub, AiCoachMode current) {
    final sel = current == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          Haptics.tap();
          context.read<FitnessProvider>().saveAiCoachMode(mode);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: sel ? _green.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: sel ? _green : const Color(0xFF3A3A3C)),
          ),
          child: Column(children: [
            Icon(icon, size: 18, color: sel ? _green : _muted),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : _muted)),
            Text(sub,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: _muted)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<FitnessProvider>().aiCoachMode;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Coach engine',
            style: TextStyle(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
            'On-device runs offline & private. Cloud is fast and needs no '
            'download, but uses the internet (a cheap model to protect quota).',
            style: TextStyle(color: _muted, fontSize: 11, height: 1.3)),
        const SizedBox(height: 10),
        Row(children: [
          _seg(context, 'On-device', Icons.smartphone_rounded, AiCoachMode.local,
              'Gemma · offline', mode),
          const SizedBox(width: 8),
          _seg(context, 'Cloud', Icons.cloud_rounded, AiCoachMode.cloud,
              'Flash-Lite · fast', mode),
        ]),
      ]),
    );
  }
}

// ── Cloud coach info (shown when Cloud engine is selected) ────────────────────
class _CloudCoachInfoTile extends StatelessWidget {
  const _CloudCoachInfoTile();
  static const _green = Color(0xFF30D158);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF40C8E0).withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: const [
          Text('☁️', style: TextStyle(fontSize: 20)),
          SizedBox(width: 10),
          Expanded(
            child: Text('Cloud coach active',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 6),
        const Text(
            'Fast responses via ${GeminiTextService.modelLabel} — no 600 MB '
            'download. Needs internet; also powers a once-a-day AI daily brief.',
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 11, height: 1.35)),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => openChat(context),
            icon: const Text('💬', style: TextStyle(fontSize: 14)),
            label: const Text('Open AI Coach Chat'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _green,
              side: const BorderSide(color: _green),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── AI Auto-load toggle ───────────────────────────────────────────────────────
class _AiAutoLoadTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ai = context.watch<OnDeviceAiService>();
    return Material(
      // Material carries the colour so the SwitchListTile's ink stays visible.
      color: const Color(0xFF1E1E22),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: const Icon(Icons.bolt_rounded, color: Color(0xFF30D158)),
        title: const Text('Load AI at app start',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(
          ai.autoLoad
              ? 'AI is ready before you open it'
              : 'AI loads only when you open AI Coach',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
        ),
        value: ai.autoLoad,
        activeColor: const Color(0xFF30D158),
        onChanged: (v) {
          Haptics.impact();
          context.read<OnDeviceAiService>().saveAutoLoad(v);
        },
      ),
    );
  }
}

// ── Auto-update enable/disable toggle ────────────────────────────────────────
class _AutoUpdateEnabledTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.watch<FitnessProvider>();
    return Material(
      color: const Color(0xFF1E1E22),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: const Icon(Icons.system_update_rounded, color: Color(0xFF30D158)),
        title: const Text('Check for updates automatically',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        value: p.autoUpdateCheck,
        activeColor: const Color(0xFF30D158),
        onChanged: (v) {
          Haptics.impact();
          context.read<FitnessProvider>().saveAutoUpdateCheck(v);
        },
      ),
    );
  }
}

// ── Manual "Check for updates" tile ──────────────────────────────────────────
class _CheckForUpdatesTile extends StatefulWidget {
  @override
  State<_CheckForUpdatesTile> createState() => _CheckForUpdatesTileState();
}

class _CheckForUpdatesTileState extends State<_CheckForUpdatesTile> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final pkgInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(pkgInfo.buildNumber) ?? 0;
      final service = UpdateService();
      final info = await service.checkForUpdate(currentBuild);
      if (!mounted) return;
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('K Fitness is up to date')),
        );
      } else {
        await showUpdateDialog(context, info, service);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not check for updates')),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 8),
      child: Material(
        color: const Color(0xFF1E1E22),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: _checking
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF30D158)),
                )
              : const Icon(Icons.refresh_rounded, color: Color(0xFF30D158)),
          title: const Text('Check for updates',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: const Text('Manually check for a new version',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
          trailing: _checking
              ? null
              : const Icon(Icons.chevron_right, color: Color(0xFF8E8E93)),
          onTap: _checking ? null : _check,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}
