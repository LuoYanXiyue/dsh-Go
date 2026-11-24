// The two ways to use the app, side by side — the native interface and the
// official DSH Web in the app (网页模式). The choice is kept and the next
// launch opens straight into it (lib/ui/web/mode_home.dart).
//
// Both modes share one idea of "where you are": the active host
// (hosts_state.dart) and the current conversation (currentSessionProvider),
// which the web page keeps up to date while it is on screen
// (assets/web/dsh_web_state.js). Switching therefore lands on the same
// conversation on the same host.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import 'web_target.dart';
import 'compose_inbox.dart';

/// 界面: the native interface or the official web one.
enum UiMode {
  native,
  web;

  /// Short name for the switch (设置 › 界面).
  String get label => switch (this) {
    native => appL10n.stateUiNative,
    web => appL10n.stateUiWeb,
  };
}

/// The stored choice; [loaded] once read back at launch.
class UiModeState {
  const UiModeState({this.mode = UiMode.native, this.loaded = false});

  final UiMode mode;
  final bool loaded;

  bool get web => mode == UiMode.web;
}

class UiModeController extends Notifier<UiModeState> {
  static const key = 'ui.mode';

  @override
  UiModeState build() {
    unawaited(_load());
    return const UiModeState();
  }

  Future<void> _load() async {
    // 软件层主页 is where a fresh install starts (简报 §2.5): 启动后直接进对话
    // is a switch the user turns on, not the shipped default.
    var mode = UiMode.native;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(key);
      if (stored != null) mode = UiMode.values.firstWhere((m) => m.name == stored, orElse: () => mode);
    } catch (_) {}
    // 读盘期间用户已经切过：以那次为准。
    if (!state.loaded) state = UiModeState(mode: mode, loaded: true);
  }

  /// Switches and remembers it for the next launch.
  Future<void> set(UiMode mode) async {
    state = UiModeState(mode: mode, loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, mode.name);
    } catch (_) {}
  }
}

final uiModeProvider = NotifierProvider<UiModeController, UiModeState>(UiModeController.new);

/// Something outside the web page asks it to show [target] (a share, a
/// launcher shortcut, 「在网页版打开」 from a native page): the web home takes
/// it as soon as its page can.
class WebOpenRequest {
  WebOpenRequest(this.target, {this.compose});

  final DshWebTarget target;

  /// Text and files for the composer of the conversation [target] opens.
  final ComposeRequest? compose;
}

/// The latest [WebOpenRequest] the web home has not taken yet.
class WebOpenController extends Notifier<WebOpenRequest?> {
  @override
  WebOpenRequest? build() => null;

  void request(DshWebTarget target, {ComposeRequest? compose}) => state = WebOpenRequest(target, compose: compose);

  /// The web home took [request] (a newer one stays).
  void taken(WebOpenRequest request) {
    if (identical(state, request)) state = null;
  }
}

final webOpenProvider = NotifierProvider<WebOpenController, WebOpenRequest?>(WebOpenController.new);
