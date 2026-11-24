// The data in this app, as one zip: what 「导出数据」 writes and 「从备份恢复」
// reads back.
//
// Everything a person would miss if the app were uninstalled lives in DSH home
// (`/root/.dsh` inside the rootfs): the conversations (`sessions`), the engines'
// stores (`storages`, which is where memories and settings live), the profiles
// (`profiles/web` holds the plugin list), the attachments those conversations
// point at, the skills, and the app's own `dsh-go` configuration. A zip of that
// folder therefore restores a phone completely, which is what 简报 22–25 asks
// for.
//
// Two things are deliberately left out:
//
//   * `cache` and `backups` — rebuildable, and `backups` can hold another copy
//     of everything here (the engine's own snapshots).
//   * any `node_modules` — plugin code, not the plugin list. It is downloaded
//     again by the plugin market, and pnpm's store inside it is most of a
//     profile's size.
//
// The zip streams: files are copied into it as they are read, so a phone with
// few hundred megabytes of conversations does not need that much memory.

import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../share_code/guest_fs.dart';

/// What this app keeps, as a folder on disk.
class DshHomeBackup {
  DshHomeBackup(this.home);

  /// The on-device DSH home; null while the runtime is not installed.
  static Future<DshHomeBackup?> local() async {
    final fs = await GuestFs.local();
    return fs == null ? null : DshHomeBackup(fs.dir(GuestFs.dshHome));
  }

  /// DSH home on the host (`…/runtime/rootfs/root/.dsh`).
  final Directory home;

  /// Folders at the top of DSH home that are not worth carrying.
  static const skippedFolders = {'cache', 'backups'};

  /// Where a restore puts the data before swapping it in: beside DSH home, so
  /// both are on the same filesystem and the swap is a rename.
  Directory get _parent => home.parent;

  bool get exists => home.existsSync();

  /// Files the zip will carry, and how many bytes they are.
  Future<({int files, int bytes})> measure() async {
    if (!exists) return (files: 0, bytes: 0);
    var files = 0;
    var bytes = 0;
    await for (final entity in home.list(recursive: true, followLinks: false)) {
      if (!_carried(entity) || entity is! File) continue;
      files++;
      bytes += await entity.length();
    }
    return (files: files, bytes: bytes);
  }

  /// Writes everything to [destination] (replaced when it exists).
  ///
  /// [onProgress] gets 0…1 by entry count. The caller keeps the engine still
  /// while this runs: a conversation written mid-copy would be a torn file in
  /// the zip.
  Future<void> exportTo(File destination, {void Function(double progress)? onProgress}) async {
    if (!exists) throw const BackupException('missing');
    await destination.parent.create(recursive: true);
    if (await destination.exists()) await destination.delete();
    await ZipFileEncoder().zipDirectory(
      home,
      filename: destination.path,
      followLinks: true,
      onProgress: onProgress,
      filter: (entity, progress) =>
          _carried(entity) ? ZipFileOperation.include : ZipFileOperation.skip,
    );
  }

  /// Puts the data in [zip] back in place of this DSH home.
  ///
  /// The current data is moved to `~/.dsh.bak-<time>` first and the new data
  /// is unpacked beside it, so a zip that turns out to be wrong leaves the
  /// phone exactly as it was. Returns the folder holding the old data.
  Future<Directory?> restoreFrom(File zip, {void Function(double progress)? onProgress}) async {
    final staging = Directory(p.join(_parent.path, '.dsh-restore-${DateTime.now().millisecondsSinceEpoch}'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      await extractFileToDisk(zip.path, staging.path);
      if (!_looksLikeDshHome(staging)) throw const BackupException('not-a-backup');
      Directory? kept;
      if (await home.exists()) {
        kept = Directory(p.join(_parent.path, '.dsh.bak-${_stamp()}'));
        await home.rename(kept.path);
      }
      await staging.rename(home.path);
      return kept;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  /// What `清理缓存` may delete: the engine's rebuildable folders and old
  /// DSH homes a restore left behind. Returns the bytes freed.
  Future<int> clearCache({int keepBackups = 0}) async {
    var freed = 0;
    for (final name in skippedFolders) {
      final dir = Directory(p.join(home.path, name));
      if (await dir.exists()) {
        freed += await _sizeOf(dir);
        await dir.delete(recursive: true);
      }
    }
    final kept = <Directory>[];
    await for (final entity in _parent.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('.dsh.bak-') && !name.startsWith('.dsh-restore-')) continue;
      kept.add(entity);
    }
    kept.sort((a, b) => a.path.compareTo(b.path));
    for (final dir in kept.take(math.max(0, kept.length - keepBackups))) {
      freed += await _sizeOf(dir);
      await dir.delete(recursive: true);
    }
    return freed;
  }

  /// The old DSH homes a restore left behind, newest last.
  Future<List<Directory>> keptBackups() async {
    final found = <Directory>[];
    await for (final entity in _parent.list(followLinks: false)) {
      if (entity is Directory && p.basename(entity.path).startsWith('.dsh.bak-')) found.add(entity);
    }
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  Future<int> sizeOf(Directory dir) => _sizeOf(dir);

  /// Whether [entity] belongs in the zip: nothing under a skipped folder and
  /// nothing under a `node_modules`.
  bool _carried(FileSystemEntity entity) {
    final rel = p.relative(entity.path, from: home.path);
    if (rel == '.') return false;
    final parts = p.split(rel);
    if (skippedFolders.contains(parts.first)) return false;
    return !parts.contains('node_modules');
  }

  /// A zip of something else, unpacked by mistake, would otherwise replace the
  /// phone's conversations with it.
  static bool _looksLikeDshHome(Directory dir) {
    for (final name in ['sessions', 'storages', 'profiles', 'dsh-go']) {
      if (Directory(p.join(dir.path, name)).existsSync()) return true;
    }
    return File(p.join(dir.path, '.credentials.yaml')).existsSync();
  }

  static String _stamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

Future<int> _sizeOf(Directory dir) async {
  var total = 0;
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
  } on FileSystemException {
    // A file removed while counting: the number is for display only.
  }
  return total;
}

/// Why a backup or a restore did not happen.
class BackupException implements Exception {
  const BackupException(this.code);

  /// `missing` (no runtime installed), `not-a-backup` (the zip is not this
  /// app's data), `no-space` (not enough room for the swap), else a platform
  /// failure's message.
  final String code;

  @override
  String toString() => 'BackupException($code)';
}
