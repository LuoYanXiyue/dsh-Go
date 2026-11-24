import 'dart:convert';

import 'package:dsh_app/companion/companion_agent_workspace_tool.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show FakeChatController;

/// Her session: what is sent goes out under a request id, as the real one does.
class _Session extends FakeChatController {
  _Session(String id) : super(id, const ChatState(loading: false));

  @override
  Future<bool> send(
    String text, {
    List<DraftAttachment> attachments = const [],
    SendMode mode = SendMode.now,
    bool verbatim = false,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  }) async {
    if (beforeDeliver != null && !await beforeDeliver('req-1')) return false;
    return super.send(text, attachments: attachments, mode: mode);
  }
}

final _ref = Provider<Ref>((ref) => ref);

final _time = DateTime.utc(2026, 11, 24, 9);
final _asked = UserChatItem(seq: 10, time: _time, text: 'task', images: const [], files: const [], requestId: 'req-1');

ToolChatItem _bash(String command, ToolStatus status) =>
    ToolChatItem(callId: 'c1', name: 'bash', arguments: jsonEncode({'command': command}), status: status, seq: 11);

AssistantChatItem _said(String text, int seq) => AssistantChatItem(id: 'a$seq', text: text, reasoning: '', seq: seq);

void main() {
  late ProviderContainer container;
  late Map<String, _Session> sessions;

  setUp(() {
    sessions = {};
    container = ProviderContainer(overrides: [chatProvider.overrideWith2((id) => sessions[id] = _Session(id))]);
  });
  tearDown(() => container.dispose());

  CompanionAgentWorkspaceTool tool({
    List<String?>? steps,
    bool local = true,
    bool? phoneFiles = true,
    String? said,
    Duration timeout = const Duration(minutes: 30),
  }) => CompanionAgentWorkspaceTool(
    ref: container.read(_ref),
    ensureSession: () async => 's1',
    isCurrent: () => true,
    onProgress: (step) => steps?.add(step),
    local: local,
    phoneFiles: phoneFiles,
    said: said,
    timeout: timeout,
  );

  Future<CompanionAgentToolResult> start(CompanionAgentWorkspaceTool tool, String task) =>
      tool.execute(CompanionAgentToolCall(id: 'w1', name: 'workspace', input: {'task': task}));

  test('hands the task to her session and brings back what that turn ended with', () async {
    final steps = <String?>[];
    final workspace = tool(steps: steps, said: '下载里都有啥');
    final result = workspace.execute(
      const CompanionAgentToolCall(id: 'w1', name: 'workspace', input: {'task': '列出 /sdcard/Download 里的文件'}),
    );
    await pumpEventQueue();
    final session = sessions['s1']!;
    expect(session.sent.single, '（伙伴替对方交代的事。对方原话：「下载里都有啥」）\n列出 /sdcard/Download 里的文件');
    expect(workspace.sessionId, 's1');

    session.emit(ChatState(loading: false, running: true, items: [_asked]));
    session.emit(
      ChatState(loading: false, running: true, items: [_asked, _bash('ls /sdcard/Download', ToolStatus.running)]),
    );
    expect(steps.last, contains('ls /sdcard/Download'));
    session.emit(
      ChatState(
        loading: false,
        items: [
          _asked,
          _said('我看看。', 11),
          _bash('ls /sdcard/Download', ToolStatus.succeeded),
          _said('有 a.pdf 和 b.zip。', 13),
        ],
      ),
    );

    final done = await result;
    expect(done.isError, isFalse);
    expect(done.externalWebContent, isTrue);
    expect(jsonDecode(done.content), {'result': '有 a.pdf 和 b.zip。', 'toolCalls': 1});
    expect(steps.last, isNull);
    expect(workspace.sessionId, isNull);
  });

  test('says when it waits on the person, and goes back to the step after', () async {
    final steps = <String?>[];
    final result = start(tool(steps: steps), 'rm -rf build');
    await pumpEventQueue();
    final session = sessions['s1']!;
    const approval = ApprovalRequest(eventId: 'e1', sessionId: 's1', toolName: 'bash', callId: 'c1');
    session.emit(
      ChatState(
        loading: false,
        running: true,
        items: [_asked, _bash('rm -rf build', ToolStatus.awaitingApproval)],
        approvals: [approval],
      ),
    );
    final waiting = steps.last;
    session.emit(ChatState(loading: false, running: true, items: [_asked, _bash('rm -rf build', ToolStatus.running)]));
    expect(steps.last, isNot(waiting));
    expect(steps.last, contains('rm -rf build'));
    session.emit(ChatState(loading: false, items: [_asked, _bash('rm -rf build', ToolStatus.succeeded)]));
    expect((jsonDecode((await result).content) as Map)['toolCalls'], 1);
  });

  test('stop ends the session turn too', () async {
    final workspace = tool();
    final result = start(workspace, '编译一下');
    await pumpEventQueue();
    final session = sessions['s1']!;
    session.emit(ChatState(loading: false, running: true, items: [_asked]));
    workspace.stop();
    final done = await result;
    expect(done.isError, isTrue);
    expect((jsonDecode(done.content) as Map)['code'], 'stopped');
    expect(session.cancels, 1);
    // A stopped turn hands nothing more over.
    final again = await workspace.execute(
      const CompanionAgentToolCall(id: 'w2', name: 'workspace', input: {'task': '再来'}),
    );
    expect((jsonDecode(again.content) as Map)['code'], 'turn_not_current');
    expect(session.sent, hasLength(1));
  });

  test('a turn that failed comes back as a failure with what it got to', () async {
    final result = start(tool(), '跑测试');
    await pumpEventQueue();
    sessions['s1']!
      ..emit(ChatState(loading: false, running: true, items: [_asked]))
      ..emit(
        ChatState(
          loading: false,
          items: [
            _asked,
            _said('跑到一半。', 11),
            const NoticeChatItem(seq: 12, kind: 'error', text: 'model unavailable'),
          ],
        ),
      );
    final done = await result;
    expect(done.isError, isTrue);
    final content = jsonDecode(done.content) as Map;
    expect(content['code'], 'workspace_failed');
    expect(content['message'], contains('model unavailable'));
    expect(content['result'], '跑到一半。');
  });

  test('phone files that are not mounted are named, with where to turn them on', () async {
    final result = start(tool(phoneFiles: false), '看看 /sdcard/DCIM 里最新的照片');
    await pumpEventQueue();
    sessions['s1']!
      ..emit(ChatState(loading: false, running: true, items: [_asked]))
      ..emit(ChatState(loading: false, items: [_asked, _said('/sdcard 不存在。', 11)]));
    expect((jsonDecode((await result).content) as Map)['phoneFiles'], contains('访问手机文件'));
  });

  test('a turn that runs past the limit keeps going and lets her know', () async {
    final result = start(tool(timeout: const Duration(milliseconds: 10)), '整理整个仓库');
    final done = await result;
    expect((jsonDecode(done.content) as Map)['code'], 'workspace_still_running');
    expect(sessions['s1']!.cancels, 0);
  });

  test('the description says where the work happens and where phone files are', () {
    expect(tool().definition.name, 'workspace');
    expect(tool().definition.description, contains('/sdcard/DCIM'));
    expect(tool(phoneFiles: false).definition.description, contains('「访问手机文件」没开'));
    expect(tool(local: false, phoneFiles: null).definition.description, contains('连着的电脑'));
    expect(tool(local: false, phoneFiles: null).definition.description, isNot(contains('/sdcard')));
  });
}
