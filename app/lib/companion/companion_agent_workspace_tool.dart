// Her hands in full mode. The work goes into her own engine session on the
// active host (this phone's Linux runtime, or a connected computer) as an
// ordinary message; that turn's final words come back to her loop. The
// session's own tools and approval policy apply as in any conversation, and
// the room shows what it waits on.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/chat_state.dart';
import '../ui/chat/tool_view.dart';
import 'companion_light.dart';

class CompanionAgentWorkspaceTool {
  CompanionAgentWorkspaceTool({
    required this.ref,
    required this.ensureSession,
    required this.isCurrent,
    required this.onProgress,
    required this.local,
    this.phoneFiles,
    this.said,
    this.timeout = const Duration(minutes: 30),
  });

  final Ref ref;

  /// Her session on the active host, created on first use.
  final Future<String> Function() ensureSession;
  final bool Function() isCurrent;

  /// A new step line; null once a call is over.
  final void Function(String? step) onProgress;

  /// The active host is this phone's own engine, not a connected computer.
  final bool local;

  /// Whether the phone's shared storage is mounted at /sdcard (访问手机文件);
  /// null where that setting doesn't apply.
  final bool? phoneFiles;

  /// What the person said this turn, passed along with the task.
  final String? said;
  final Duration timeout;

  /// The session doing a call right now, and its latest step.
  String? sessionId;
  String? step;
  void Function()? _stop;
  bool _stopped = false;

  // Long reports would crowd her own 64 KB request; the whole text stays in
  // her main conversation.
  static const _maxResult = 6000;
  static const _failedKinds = {'error', 'aborted', 'blocked', 'interrupted'};
  static final _phonePaths = RegExp(r'/sdcard|手机存储|DCIM');

  CompanionAgentTool get definition => CompanionAgentTool(
    name: 'workspace',
    description: [
      '在本机的 Linux 环境（或连着的电脑）里办事：跑命令、读写文件、看目录、写代码和改代码、上网查资料、用装好的工具。'
          '文件、文档、代码、跑程序这类事都先用它，不要用手机操控去打开文件；手机操控只用来操作手机上的应用界面。'
          '看一张照片用照片工具；要整理、转换、批量处理照片文件就用它。'
          '把要做的事和要交回什么写清楚交过去；它做完你再用自己的话告诉对方。',
      if (!local)
        '现在接的是连着的电脑。'
      else if (phoneFiles == true)
        '现在接的是这台手机自己的 Linux 环境；手机里的文件在 /sdcard，照片在 /sdcard/DCIM，下载在 /sdcard/Download。'
      else if (phoneFiles == false)
        '现在接的是这台手机自己的 Linux 环境；「访问手机文件」没开，/sdcard 里看不到手机的文件和照片。'
      else
        '现在接的是这台手机自己的 Linux 环境。',
    ].join('\n'),
    inputSchema: const {
      'type': 'object',
      'properties': {
        'task': {'type': 'string', 'description': '要做的事，和做完要交回什么'},
      },
      'required': ['task'],
      'additionalProperties': false,
    },
  );

  List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
  get bindings => [(definition: definition, execute: execute)];

  /// Her stop is the person's: the session's turn doing this work ends too.
  void stop() {
    _stopped = true;
    _stop?.call();
  }

  Future<CompanionAgentToolResult> execute(CompanionAgentToolCall call) async {
    final task = switch (call.input['task']) {
      final String text => text.trim(),
      _ => '',
    };
    if (task.isEmpty) return _failure('task_missing', '把要做的事和要交回什么写进 task。');
    if (_stopped || !isCurrent()) return _failure('turn_not_current', '这一轮已经停了，没有交过去。');
    final String id;
    try {
      id = await ensureSession();
    } on Object catch (error) {
      return _failure('workspace_unavailable', '没连上主机上的 DSH，这次没交过去：$error');
    }
    if (_stopped || !isCurrent()) return _failure('turn_not_current', '这一轮已经停了，没有交过去。');

    final chat = ref.read(chatProvider(id).notifier);
    final ended = Completer<ChatState?>();
    String? requestId;
    Future<void>? cancelling;
    var started = false;
    var waiting = false;
    var timedOut = false;
    final shown = <String>{};
    String? lastTool;
    void report(String line) {
      step = line;
      onProgress(line);
    }

    void changed(ChatState state) {
      final turn = _turn(state, requestId);
      if (ended.isCompleted || turn == null) return;
      if (state.running) started = true;
      for (final tool in turn.whereType<ToolChatItem>()) {
        if (tool.status != ToolStatus.streaming && shown.add(tool.key)) report(lastTool = _line(tool));
      }
      final asks = state.openApproval != null || state.questions.isNotEmpty;
      if (asks != waiting) {
        waiting = asks;
        report(asks ? appL10n.companionWorkspaceWaiting : lastTool ?? _working);
      }
      if (!state.running && (started || turn.isNotEmpty)) ended.complete(state);
    }

    sessionId = id;
    report(_working);
    final subscription = ref.listen<ChatState>(chatProvider(id), (_, next) => changed(next));
    _stop = () {
      if (ended.isCompleted) return;
      ended.complete(null);
      if (requestId != null) cancelling = chat.cancel();
    };
    // Generous, and the work itself goes on in her main conversation.
    final timer = Timer(timeout, () {
      timedOut = true;
      if (!ended.isCompleted) ended.complete(null);
    });
    try {
      final sent = await chat.send(
        _message(task),
        beforeDeliver: (request) async {
          if (ended.isCompleted || !isCurrent()) return false;
          requestId = request;
          return true;
        },
      );
      if (!sent && !ended.isCompleted) return _failure('workspace_not_sent', '没交过去，再试一次。');
      changed(ref.read(chatProvider(id)));
      final state = await ended.future;
      if (state != null) return _result(state, requestId, task);
      return timedOut
          ? _failure('workspace_still_running', '做了 ${timeout.inMinutes} 分钟还没做完，还在你的主对话里接着做；对方可以去那里看。')
          : _failure('stopped', '对方叫停了，那边也停下了。');
    } finally {
      timer.cancel();
      _stop = null;
      sessionId = null;
      step = null;
      onProgress(null);
      // A stop still on its way keeps the session followed until it lands.
      if (cancelling case final pending?) {
        unawaited(pending.whenComplete(subscription.close));
      } else {
        subscription.close();
      }
    }
  }

  String get _working => local ? appL10n.companionWorkspaceLocal : appL10n.companionWorkspaceRemote;

  /// Marked as hers, with the person's own words when they add something.
  String _message(String task) {
    final words = said?.trim() ?? '';
    final quote = words.isEmpty || words == task
        ? ''
        : '对方原话：「${words.length > 300 ? '${words.substring(0, 300)}…' : words}」';
    return '（伙伴替对方交代的事。$quote）\n$task';
  }

  /// What came after this request's own message, up to the next one.
  static List<ChatItem>? _turn(ChatState state, String? requestId) {
    if (requestId == null) return null;
    final at = state.items.lastIndexWhere((item) => item is UserChatItem && item.requestId == requestId);
    if (at < 0) return null;
    return state.items.skip(at + 1).takeWhile((item) => item is! UserChatItem).toList();
  }

  static String _line(ToolChatItem tool) {
    final view = ToolView.of(tool);
    final subject = view.summary.trim().split('\n').first;
    final line = subject.isEmpty ? view.verb : '${view.verb} $subject';
    return line.length <= 80 ? line : '${line.substring(0, 80)}…';
  }

  CompanionAgentToolResult _result(ChatState state, String? requestId, String task) {
    final turn = _turn(state, requestId) ?? const <ChatItem>[];
    final words = turn
        .whereType<AssistantChatItem>()
        .map((item) => item.text.trim())
        .lastWhere((text) => text.isNotEmpty, orElse: () => '');
    final problem = turn.whereType<NoticeChatItem>().where((n) => _failedKinds.contains(n.kind)).lastOrNull;
    final clipped = words.length > _maxResult;
    return CompanionAgentToolResult(
      content: jsonEncode({
        if (problem != null) ...{'code': 'workspace_failed', 'message': '没做完：${problem.text}'},
        'result': clipped ? '${words.substring(0, _maxResult)}…' : words,
        'toolCalls': turn.whereType<ToolChatItem>().length,
        if (clipped) 'clipped': '太长，只带回了前面一段；全文在你的主对话里。',
        if (words.isEmpty && problem == null) 'message': '那边做完了，但没留下话；可以让对方去你的主对话里看。',
        if (phoneFiles == false && _phonePaths.hasMatch('$task\n$words'))
          'phoneFiles': '「访问手机文件」没开，/sdcard 下没有手机里的文件和照片。请对方到 设置 → 权限 打开「访问手机文件」，再让你做一次。',
      }),
      isError: problem != null,
      // Files, pages and command output are data, like a screen she reads.
      externalWebContent: true,
    );
  }

  CompanionAgentToolResult _failure(String code, String message) =>
      CompanionAgentToolResult(content: jsonEncode({'code': code, 'message': message}), isError: true);
}
