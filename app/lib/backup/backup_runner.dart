// Puts a backup on disk: 导出数据 writes one the person keeps, 定时备份 keeps a
// few in the app's own folder.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'backup_prefs.dart';
import 'dsh_home_backup.dart';

/// The app's own folder for scheduled backups. Outside the runtime on purpose:
/// 修复运行环境 and 重置 delete the rootfs, and the backups should outlive that.
final backupFolderProvider = FutureProvider<Directory>((ref) async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}/dsh-backups');
});

/// `DSH-data-20261124-2140.zip`.
String backupFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'DSH-data-${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}.zip';
}

class BackupRunner {
  const BackupRunner(this.folder);

  final Directory folder;

  /// Writes everything into a new zip in [folder]. Throws [BackupException]
  /// when the runtime is not there yet.
  Future<File> run({void Function(double progress)? onProgress, DateTime? at}) async {
    final backup = await DshHomeBackup.local();
    if (backup == null || !backup.exists) throw const BackupException('missing');
    await folder.create(recursive: true);
    final file = File('${folder.path}/${backupFileName(at ?? DateTime.now())}');
    await backup.exportTo(file, onProgress: onProgress);
    return file;
  }

  /// Deletes all but the newest [keep] zips here; returns the bytes freed.
  Future<int> prune(int keep) async {
    if (!await folder.exists()) return 0;
    final zips = <File>[];
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.zip')) zips.add(entity);
    }
    zips.sort((a, b) => a.path.compareTo(b.path));
    var freed = 0;
    for (final file in zips.take(zips.length > keep ? zips.length - keep : 0)) {
      freed += await file.length();
      try {
        await file.delete();
      } on FileSystemException {
        // A file the system took away first: nothing left to free.
      }
    }
    return freed;
  }

  /// Bytes the scheduled zips take.
  Future<int> used() async {
    if (!await folder.exists()) return 0;
    var total = 0;
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}

/// One backup at a time: the page and the launch check can ask together.
bool _running = false;

/// Takes a scheduled backup when one is owed, from the launch check.
///
/// Only once the engine runs (its files are the ones being copied) and only
/// one at a time; a failure is left for the next launch, since nothing is
/// waiting on it. Unlike 导出数据, this does not stop the engine: it runs while
/// the person is using the app. Conversations are append-only, so the worst a
/// copy can catch is a half-written last line.
Future<void> scheduledBackup(ProviderContainer container, {DateTime? at}) async {
  if (_running) return;
  final controller = container.read(backupPrefsProvider.notifier);
  await controller.ready;
  final prefs = container.read(backupPrefsProvider);
  final now = at ?? DateTime.now();
  if (!prefs.dueAt(now)) return;
  if (container.read(localRuntimeProvider).status.phase != RuntimePhase.running) return;
  _running = true;
  try {
    final runner = BackupRunner(await container.read(backupFolderProvider.future));
    await runner.run(at: now);
    await runner.prune(prefs.keep);
    await controller.markDone(now);
  } catch (_) {
    // The next launch asks again.
  } finally {
    _running = false;
  }
}
