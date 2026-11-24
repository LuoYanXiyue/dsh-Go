// 设置 › 数据: what this app keeps on the phone, and the three things one can
// do with it — export it, put a backup back, and clear what can be rebuilt.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../backup/backup_prefs.dart';
import '../../backup/backup_runner.dart';
import '../../backup/dsh_home_backup.dart';
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart' show RuntimePhase;
import '../../runtime/runtime_state.dart' show LocalRuntimeController, localRuntimeProvider;
import '../../state/artifacts.dart' show filesChannelProvider, savedInChosenPlace;
import '../../state/attachments.dart' show formatBytes;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

const _zipMime = 'application/zip';

/// The days 定时备份 offers.
const _intervals = [1, 3, 7, 14, 30];

/// How many zips it may keep.
const _keeps = [1, 2, 3, 5, 10];

class DataPage extends ConsumerStatefulWidget {
  const DataPage({super.key});

  @override
  ConsumerState<DataPage> createState() => _DataPageState();
}

class _DataPageState extends ConsumerState<DataPage> {
  /// 0…1 while a zip is written or read; null when nothing is running.
  double? _progress;
  ({int files, int bytes})? _sizes;
  int? _cacheBytes;

  /// False once the runtime was found missing (nothing to export yet).
  bool _ready = true;

  bool get _busy => _progress != null;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    final backup = await DshHomeBackup.local();
    if (!mounted) return;
    if (backup == null || !backup.exists) {
      setState(() => _ready = false);
      return;
    }
    final sizes = await backup.measure();
    final cache = await backup.sizeOf(Directory(p.join(backup.home.path, 'cache')));
    if (!mounted) return;
    setState(() {
      _sizes = sizes;
      _cacheBytes = cache;
    });
  }

  void _onProgress(double progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  /// 导出数据: a zip in the phone's Downloads, made from a temporary copy.
  Future<void> _export() async {
    final l10n = context.l10n;
    setState(() => _progress = 0);
    File? zip;
    try {
      final backup = await DshHomeBackup.local();
      if (backup == null || !backup.exists) throw const BackupException('missing');
      final folder = Directory('${(await getTemporaryDirectory()).path}/data-export');
      await folder.create(recursive: true);
      for (final old in folder.listSync().whereType<File>()) {
        try {
          await old.delete();
        } on FileSystemException {
          // Left for the next export to clean up.
        }
      }
      zip = File(p.join(folder.path, backupFileName(DateTime.now())));
      await backup.exportTo(zip, onProgress: _onProgress);
      final where = await ref
          .read(filesChannelProvider)
          .saveToDownloads(zip.path, name: p.basename(zip.path), mime: _zipMime);
      _tell(l10n.dataExported(_where(where)));
    } on BackupException catch (e) {
      _tell(l10n.dataFailed(_reason(l10n, e)));
    } catch (error) {
      _tell(l10n.dataFailed('$error'));
    } finally {
      if (mounted) setState(() => _progress = null);
      if (zip != null) {
        try {
          await zip.delete();
        } on FileSystemException {
          // The cache is swept later.
        }
      }
    }
  }

  /// 从备份恢复: the picked zip replaces DSH home, the current one kept aside.
  Future<void> _restore() async {
    final l10n = context.l10n;
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']);
    } catch (error) {
      _tell(l10n.dataFailed('$error'));
      return;
    }
    if (picked == null || !mounted) return;
    // A pick on Android is often a content URI: bring it somewhere the
    // unzipper can seek before anything touches DSH home.
    final File zip;
    try {
      final folder = Directory('${(await getTemporaryDirectory()).path}/data-restore');
      await folder.create(recursive: true);
      zip = File(p.join(folder.path, 'restore-${DateTime.now().millisecondsSinceEpoch}.zip'));
      final sink = zip.openWrite();
      try {
        await sink.addStream(picked.readAsByteStream());
      } finally {
        await sink.close();
      }
    } catch (error) {
      _tell(l10n.dataFailed('$error'));
      return;
    }
    if (!mounted) return;
    final yes = await _confirm(
      title: l10n.dataRestore,
      body: l10n.dataRestoreWarning,
      action: l10n.dataRestoreNow,
      danger: true,
    );
    if (yes != true || !mounted) return;
    final runtime = ref.read(localRuntimeProvider.notifier);
    final wasRunning = ref.read(localRuntimeProvider).status.phase == RuntimePhase.running;
    setState(() => _progress = 0);
    try {
      if (wasRunning) await _stopEngine(runtime);
      final backup = await DshHomeBackup.local();
      if (backup == null) throw const BackupException('missing');
      final kept = await backup.restoreFrom(zip, onProgress: _onProgress);
      if (wasRunning) unawaited(runtime.start());
      if (!mounted) return;
      _tell(kept == null ? l10n.dataRestoreDone : l10n.dataRestored(kept.path));
      unawaited(_measure());
    } on BackupException catch (e) {
      if (wasRunning) unawaited(runtime.start());
      _tell(l10n.dataFailed(_reason(l10n, e)));
    } catch (error) {
      if (wasRunning) unawaited(runtime.start());
      _tell(l10n.dataFailed('$error'));
    } finally {
      if (mounted) setState(() => _progress = null);
      try {
        if (await zip.exists()) await zip.delete();
      } on FileSystemException {
        // The cache is swept later.
      }
    }
  }

  /// Stops the engine and waits until it is no longer running, so no session
  /// file is written while it is copied or replaced.
  Future<void> _stopEngine(LocalRuntimeController runtime) async {
    await runtime.stop();
    for (var i = 0; i < 100; i++) {
      if (ref.read(localRuntimeProvider).status.phase != RuntimePhase.running) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 清理缓存: what can be rebuilt, and all but the newest kept backup.
  Future<void> _clearCache() async {
    final l10n = context.l10n;
    final yes = await _confirm(
      title: l10n.dataCache,
      body: l10n.dataCacheHint,
      action: l10n.dataCache,
      danger: true,
    );
    if (yes != true || !mounted) return;
    setState(() => _progress = 0);
    try {
      final backup = await DshHomeBackup.local();
      if (backup == null) throw const BackupException('missing');
      final freed = await backup.clearCache(keepBackups: 1);
      _tell(l10n.dataCleared(formatBytes(freed)));
      await _measure();
      if (!mounted) return;
      setState(() {});
    } on BackupException catch (e) {
      _tell(l10n.dataFailed(_reason(l10n, e)));
    } catch (error) {
      _tell(l10n.dataFailed('$error'));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// One backup now, into the app's own folder (it also counts as this
  /// interval's backup).
  Future<void> _backupNow() async {
    final l10n = context.l10n;
    setState(() => _progress = 0);
    try {
      final runner = BackupRunner(await ref.read(backupFolderProvider.future));
      await runner.run(onProgress: _onProgress);
      await runner.prune(ref.read(backupPrefsProvider).keep);
      await ref.read(backupPrefsProvider.notifier).markDone(DateTime.now());
      _tell(l10n.dataExportDone(formatBytes(await runner.used())));
    } catch (error) {
      _tell(l10n.dataFailed('$error'));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
    bool danger = false,
  }) => showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.dataCancel)),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: DshColors.of(dialog).danger,
                  foregroundColor: DshColors.of(dialog).onDanger,
                )
              : null,
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(action),
        ),
      ],
    ),
  );

  /// 1/3/7/14/30 days, or 1/2/3/5/10 copies.
  Future<void> _choose({
    required String title,
    required List<int> options,
    required int current,
    required String Function(int value) label,
    required Future<void> Function(int value) onPicked,
  }) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(title),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, option),
              child: Row(
                children: [
                  Expanded(child: Text(label(option))),
                  if (option == current) Icon(AppIcons.selected, size: 20, color: Theme.of(dialog).colorScheme.primary),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await onPicked(picked);
  }

  String _where(String where) => savedInChosenPlace(where) ? where : where.replaceFirst(RegExp(r'^Download/'), '');

  String _reason(L10n l10n, BackupException e) => switch (e.code) {
    'missing' => l10n.dataErrorMissing,
    'not-a-backup' => l10n.dataErrorNotBackup,
    'no-space' => l10n.dataErrorSpace,
    _ => e.code,
  };

  void _tell(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  String _when(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(backupPrefsProvider);
    final sizes = _sizes;
    return AppPage.list(
      title: l10n.dataTitle,
      children: [
        if (_busy)
          SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                    const SizedBox(height: 10),
                    Text(
                      l10n.dataWorking(((_progress ?? 0) * 100).round()),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        SettingsSection(
          footer: Text(l10n.dataIntro),
          children: [
            SettingsTile(
              key: const ValueKey('data-export'),
              icon: AppIcons.download,
              title: l10n.dataExport,
              subtitle: l10n.dataExportHint,
              value: sizes == null ? null : Text(formatBytes(sizes.bytes)),
              onTap: _busy || !_ready ? null : () => unawaited(_export()),
            ),
            SettingsTile(
              key: const ValueKey('data-restore'),
              icon: AppIcons.history,
              title: l10n.dataRestore,
              subtitle: l10n.dataRestoreHint,
              onTap: _busy || !_ready ? null : () => unawaited(_restore()),
            ),
          ],
        ),
        SettingsSection(
          footer: Text(l10n.dataScheduledHint),
          children: [
            SettingsTile(
              key: const ValueKey('data-scheduled'),
              icon: AppIcons.time,
              title: l10n.dataScheduled,
              trailing: Switch(
                value: prefs.enabled,
                onChanged: _busy ? null : (on) => unawaited(ref.read(backupPrefsProvider.notifier).setEnabled(on)),
              ),
            ),
            if (prefs.enabled) ...[
              SettingsTile(
                key: const ValueKey('data-interval'),
                icon: AppIcons.refresh,
                title: l10n.dataInterval,
                value: Text(l10n.dataIntervalDays(prefs.intervalDays)),
                onTap: _busy
                    ? null
                    : () => unawaited(
                        _choose(
                          title: l10n.dataInterval,
                          options: _intervals,
                          current: prefs.intervalDays,
                          label: l10n.dataIntervalDays,
                          onPicked: ref.read(backupPrefsProvider.notifier).setIntervalDays,
                        ),
                      ),
              ),
              SettingsTile(
                key: const ValueKey('data-keep'),
                icon: AppIcons.archive,
                title: l10n.dataKeep,
                value: Text(l10n.dataKeepCount(prefs.keep)),
                onTap: _busy
                    ? null
                    : () => unawaited(
                        _choose(
                          title: l10n.dataKeep,
                          options: _keeps,
                          current: prefs.keep,
                          label: l10n.dataKeepCount,
                          onPicked: ref.read(backupPrefsProvider.notifier).setKeep,
                        ),
                      ),
              ),
              SettingsTile(
                key: const ValueKey('data-last'),
                icon: AppIcons.time,
                title: l10n.dataLast,
                value: Text(prefs.lastAt == null ? l10n.dataLastNever : _when(prefs.lastAt!)),
                onTap: _busy ? null : () => unawaited(_backupNow()),
              ),
            ],
          ],
        ),
        SettingsSection(
          footer: Text(l10n.dataUninstall),
          children: [
            SettingsTile(
              key: const ValueKey('data-cache'),
              icon: AppIcons.delete,
              title: l10n.dataCache,
              subtitle: l10n.dataCacheHint,
              value: _cacheBytes == null ? null : Text(formatBytes(_cacheBytes!)),
              onTap: _busy || !_ready ? null : () => unawaited(_clearCache()),
            ),
          ],
        ),
      ],
    );
  }
}
