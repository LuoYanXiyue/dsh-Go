// 软件层的主页（简报 §2.5）: the app's own face before the web page — engine
// state, 开始对话, and the four native doors (设置 / 终端 / 诊断 / 引擎). It is
// not a chat screen: nothing here reads or writes a conversation, so the web
// app stays the only chat interface.
//
// 启动后直接进对话 (设置 › 启动) skips this page on the next launch;
// `UiMode.web` then builds WebHome instead (mode_home.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart' show RuntimePhase;
import '../../runtime/runtime_state.dart' show localRuntimeProvider;
import '../../state/engine_control.dart';
import '../../state/sessions_state.dart';
import '../engine/engine_screen.dart';
import '../engine/engine_status.dart' show humanizeRuntimeError;
import '../settings/diagnostics_page.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../terminal/terminal_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/web_home.dart';

class LobbyHome extends ConsumerWidget {
  const LobbyHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(localRuntimeProvider);
    final status = state.status;
    final phase = status.phase;
    final running = status.isRunning;
    final busy = phase == RuntimePhase.starting || phase == RuntimePhase.installing;
    final failed = phase == RuntimePhase.error;
    final session = ref.watch(currentSessionProvider);
    void push(Widget page) =>
        unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)));
    return AppPage.list(
      title: 'DSH',
      subtitle: Text(
        [
          l10n.commonThisPhone,
          running
              ? l10n.lobbyEngineRunning
              : busy
              ? l10n.webEngineStarting
              : l10n.lobbyEngineStopped,
        ].join(l10n.shellListSeparator),
      ),
      children: [
        // 开始对话: the one door into the house.
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FilledButton.icon(
            key: const ValueKey('lobby-start'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(AppIcons.chat, size: 20),
            label: Text(l10n.lobbyStart),
            onPressed: () => push(const WebHome()),
          ),
        ),
        SettingsSection(
          title: l10n.lobbyEngine,
          children: [
            SettingsTile(
              key: const ValueKey('lobby-engine'),
              icon: AppIcons.engine,
              title: l10n.lobbyEngine,
              subtitle: failed
                  ? humanizeRuntimeError(status.error) ?? l10n.webEngineProblem
                  : running
                  ? l10n.lobbyEngineRunning
                  : busy
                  ? l10n.webEngineStarting
                  : l10n.lobbyEngineStopped,
              danger: failed,
              trailing: busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      key: const ValueKey('lobby-engine-toggle'),
                      onPressed: () => unawaited(
                        running
                            ? ref.read(localRuntimeProvider.notifier).stop()
                            : EngineControl.ensureStarted(ProviderScope.containerOf(context, listen: false)),
                      ),
                      child: Text(running ? l10n.commonStop : l10n.webStartEngine),
                    ),
              onTap: () => push(const EngineScreen()),
            ),
            if (failed)
              SettingsTile(
                key: const ValueKey('lobby-engine-logs'),
                icon: AppIcons.bug,
                title: l10n.phoneEngineLogs,
                onTap: () => push(const EngineScreen()),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.commonMore,
          children: [
            SettingsTile(
              key: const ValueKey('lobby-settings'),
              icon: AppIcons.settings,
              tint: SettingsHues.general,
              title: l10n.commonSettings,
              onTap: () => push(const SettingsScreen()),
            ),
            SettingsTile(
              key: const ValueKey('lobby-terminal'),
              icon: AppIcons.terminal,
              tint: SettingsHues.general,
              title: l10n.botsTerminal,
              subtitle: session == null ? l10n.lobbyTerminalHint : null,
              onTap: session == null ? null : () => push(TerminalPage.route(session)),
            ),
            SettingsTile(
              key: const ValueKey('lobby-diagnostics'),
              icon: AppIcons.diagnostics,
              tint: SettingsHues.general,
              title: l10n.lobbyDiagnostics,
              onTap: () => push(const DiagnosticsPage()),
            ),
          ],
        ),
      ],
    );
  }
}
