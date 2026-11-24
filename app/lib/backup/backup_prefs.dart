// 设置 › 数据 › 定时备份's choices: whether backups happen, how often, and how
// many are kept. Kept in the app's preferences rather than DSH home: a backup
// is about this phone, and restoring an older zip should not undo the answer.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackupPrefs {
  const BackupPrefs({this.enabled = true, this.intervalDays = 7, this.keep = 3, this.lastAt, this.loaded = false});

  /// Backups happen in the background on a schedule.
  final bool enabled;

  /// Days between two backups.
  final int intervalDays;

  /// How many of them stay on disk.
  final int keep;

  /// When the last one finished; null: never.
  final DateTime? lastAt;

  /// False until the stored answers have been read.
  final bool loaded;

  /// Whether a backup is owed at [now].
  bool dueAt(DateTime now) =>
      enabled && (lastAt == null || !now.isBefore(lastAt!.add(Duration(days: intervalDays))));

  BackupPrefs copyWith({bool? enabled, int? intervalDays, int? keep, DateTime? lastAt, bool? loaded}) => BackupPrefs(
    enabled: enabled ?? this.enabled,
    intervalDays: intervalDays ?? this.intervalDays,
    keep: keep ?? this.keep,
    lastAt: lastAt ?? this.lastAt,
    loaded: loaded ?? this.loaded,
  );
}

class BackupPrefsController extends Notifier<BackupPrefs> {
  static const enabledKey = 'backup.enabled';
  static const intervalKey = 'backup.interval_days';
  static const keepKey = 'backup.keep';
  static const lastKey = 'backup.last_at';

  /// The loaded answers, for callers that wait for them (the runner).
  late Future<void> ready;

  @override
  BackupPrefs build() {
    ready = _load();
    return const BackupPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = BackupPrefs(
        enabled: prefs.getBool(enabledKey) ?? true,
        intervalDays: prefs.getInt(intervalKey) ?? 7,
        keep: prefs.getInt(keepKey) ?? 3,
        lastAt: DateTime.tryParse(prefs.getString(lastKey) ?? ''),
        loaded: true,
      );
    } catch (_) {
      // Without the storage the defaults still back up, once a week.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> setEnabled(bool enabled) => _save(state.copyWith(enabled: enabled), (p) => p.setBool(enabledKey, enabled));

  Future<void> setIntervalDays(int days) =>
      _save(state.copyWith(intervalDays: days), (p) => p.setInt(intervalKey, days));

  Future<void> setKeep(int keep) => _save(state.copyWith(keep: keep), (p) => p.setInt(keepKey, keep));

  Future<void> markDone(DateTime at) =>
      _save(state.copyWith(lastAt: at), (p) => p.setString(lastKey, at.toIso8601String()));

  Future<void> _save(BackupPrefs next, Future<bool> Function(SharedPreferences) write) async {
    await ready;
    if (!ref.mounted) return;
    state = next;
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // The choice holds for this run; the next launch tries again.
    }
  }
}

final backupPrefsProvider = NotifierProvider<BackupPrefsController, BackupPrefs>(BackupPrefsController.new);
