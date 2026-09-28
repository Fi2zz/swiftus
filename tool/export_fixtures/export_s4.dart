// S4 session log golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法见 tool/export_fixtures/README.md。时间一律注入固定 UTC 整秒时刻
// （两端 ISO8601 形状在此对齐，可逐字比对）；事件 id 同样注入固定值。
// JSONL 行文本存在键序差异（Dart 插入序 / Swift 规范排序），比对一律按行
// 解析为动态 JSON 后结构化比对，不逐字比。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_agent/conatus_agent.dart' as agent;
import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_llm/conatus_llm.dart';

final DateTime _t0 = DateTime.utc(2026, 8, 6, 12);
final DateTime _t1 = DateTime.utc(2026, 8, 6, 12, 1);
final DateTime _t2 = DateTime.utc(2026, 8, 6, 12, 2);

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'jsonl-roundtrip': _jsonlRoundtrip,
    'store-flow': _storeFlow,
    'log-flow-memory': () => _logFlow(InMemorySessionLog(), 'memory'),
    'log-flow-persistence': _logFlowPersistence,
    'model-visible': () async => _modelVisible(),
    'agent-loop': _agentLoop,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Future<Map<String, Object?>> Function()> entry
      in fixtures.entries) {
    final Map<String, Object?> fixture = await entry.value();
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(fixture)}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  return Directory('${here.parent.parent.path}/spec/fixtures/s4');
}

// ───────────────────────────── JSONL 往返 ─────────────────────────────

/// 持久化端口：append 落盘行原文 + load 读回（含敏感字段脱敏、parentEventId）。
Future<Map<String, Object?>> _jsonlRoundtrip() async {
  final Directory dir = await Directory.systemTemp.createTemp('s4_fixture');
  try {
    final JsonlSessionPersistence persistence =
        JsonlSessionPersistence(dir: dir.path);
    final List<SessionEvent> events = <SessionEvent>[
      SessionEvent.create(
        sessionId: 's1',
        type: 'user/message',
        seq: 0,
        time: _t0,
        id: 'evt-1',
        data: <String, Object?>{'text': '查一下', 'api_key': 'sk-1234567890abcdef'},
      ),
      SessionEvent.create(
        sessionId: 's1',
        type: 'assistant/message',
        seq: 1,
        time: _t1,
        id: 'evt-2',
        data: <String, Object?>{
          'text': '',
          'toolCalls': <Map<String, Object?>>[
            <String, Object?>{'id': 'c1', 'name': 'search', 'arguments': '{}'},
          ],
        },
      ),
      SessionEvent.create(
        sessionId: 's1',
        type: 'tool/result',
        seq: 2,
        time: _t2,
        id: 'evt-3',
        parentEventId: 'evt-2',
        data: <String, Object?>{'callId': 'c1', 'content': '结果'},
      ),
    ];
    for (final SessionEvent event in events) {
      await persistence.append('s1', event);
    }
    final List<String> lines =
        await File('${dir.path}/s1.jsonl').readAsLines();
    final List<SessionEvent> loaded = await persistence.load('s1');
    return <String, Object?>{
      'name': 'jsonl-roundtrip',
      'kind': 'jsonl-roundtrip',
      'events': <Object?>[for (final SessionEvent e in events) e.toJson()],
      'expect': <String, Object?>{
        'lines': lines,
        'loaded': <Object?>[for (final SessionEvent e in loaded) e.toJson()],
        'list': await persistence.list(),
      },
    };
  } finally {
    await dir.delete(recursive: true);
  }
}

// ───────────────────────────── SessionStore 流程 ─────────────────────────────

/// create → append → flush → close → open（种子回放 + seq 续接）→ fork → adopt
/// （种子落盘）→ persistedIds → remove。
Future<Map<String, Object?>> _storeFlow() async {
  final Directory dir = await Directory.systemTemp.createTemp('s4_fixture');
  try {
    final JsonlSessionPersistence persistence =
        JsonlSessionPersistence(dir: dir.path);
    final SessionStore store = SessionStore(persistence: persistence);
    final Session session = store.create(id: 's1');
    session.append('user/message',
        data: <String, Object?>{'text': '你好'}, time: _t0, id: 'evt-a');
    session.append('assistant/message',
        data: <String, Object?>{'text': '在的'}, time: _t1, id: 'evt-b');
    await store.flush();
    final List<String> linesAfterFlush =
        await File('${dir.path}/s1.jsonl').readAsLines();

    store.close('s1');
    final Session reopened = await store.open('s1');
    reopened.append('user/message',
        data: <String, Object?>{'text': '继续'}, time: _t2, id: 'evt-c');
    await store.flush();

    final Session forked = reopened.fork(id: 's1-fork-1');
    store.adopt(forked);
    await store.flush();
    final List<String> forkLines =
        await File('${dir.path}/s1-fork-1.jsonl').readAsLines();

    final List<String> persisted = await store.persistedIds();
    await store.remove('s1');
    final List<String> afterRemove = await persistence.list();
    return <String, Object?>{
      'name': 'store-flow',
      'kind': 'store-flow',
      'expect': <String, Object?>{
        'linesAfterFlush': linesAfterFlush.length,
        'reopenedSeqs': <int>[for (final SessionEvent e in reopened.events) e.seq],
        'reopenedTypes': <String>[
          for (final SessionEvent e in reopened.events) e.type
        ],
        'forkLines': forkLines.length,
        'forkedSeqs': <int>[for (final SessionEvent e in forked.events) e.seq],
        'forkedIds': <String>[
          for (final SessionEvent e in forked.events) e.id ?? ''
        ],
        'persistedIds': persisted,
        'afterRemove': afterRemove,
      },
    };
  } finally {
    await dir.delete(recursive: true);
  }
}

// ───────────────────────────── SessionLog 流程（两后端共用） ─────────────────────────────

/// append（seq 覆盖入参）→ fork（前缀重盖章）→ read 窗口 → replay → list → close。
Future<Map<String, Object?>> _logFlow(SessionLog log, String backend) async {
  final List<SessionEvent> appended = <SessionEvent>[
    for (final (int index, String type) in <String>['e0', 'e1', 'e2'].indexed)
      await log.append(SessionEvent.create(
        sessionId: 's1',
        type: type,
        seq: 99, // 入参 seq 会被日志覆盖
        time: <DateTime>[_t0, _t1, _t2][index],
        id: 'evt-$index',
      )),
  ];
  await log.append(SessionEvent.create(
      sessionId: 's2', type: 'x', seq: 0, time: _t0, id: 'evt-x'));
  final String forkedId = await log.fork('s1', 'evt-1');
  final List<SessionEvent> forkedEvents = await log.read(forkedId).toList();
  final List<SessionEvent> readWindow = await log.read('s1', from: _t1).toList();
  final List<String> replayed = <String>[];
  await log.replay('s1', (SessionEvent e) => replayed.add(e.type));
  final List<String> list = await log.list();
  await log.close();
  return <String, Object?>{
    'name': 'log-flow-$backend',
    'kind': 'log-flow',
    'backend': backend,
    'expect': <String, Object?>{
      'appendedSeqs': <int>[for (final SessionEvent e in appended) e.seq],
      'forkedId': forkedId,
      'forkedEvents': <Object?>[
        for (final SessionEvent e in forkedEvents) e.toJson()
      ],
      'readFromT1': <String>[for (final SessionEvent e in readWindow) e.type],
      'replayedTypes': replayed,
      'list': list,
    },
  };
}

/// 持久化后端：同 memory 流程，额外验证新实例 seq 续接（已落盘事件数）。
Future<Map<String, Object?>> _logFlowPersistence() async {
  final Directory dir = await Directory.systemTemp.createTemp('s4_fixture');
  try {
    final JsonlSessionPersistence persistence =
        JsonlSessionPersistence(dir: dir.path);
    final Map<String, Object?> fixture =
        await _logFlow(PersistenceSessionLog(persistence), 'persistence');
    final PersistenceSessionLog reopened = PersistenceSessionLog(persistence);
    final SessionEvent continued = await reopened.append(SessionEvent.create(
        sessionId: 's1', type: 'e3', seq: 0, time: _t2, id: 'evt-3'));
    (fixture['expect'] as Map<String, Object?>)['continuedSeq'] = continued.seq;
    return fixture;
  } finally {
    await dir.delete(recursive: true);
  }
}

// ═══════════════════════ v1.1 增补：模型可见即已记录 ═══════════════════════

/// model-visible：不变式用例集（事件序列 → violations）。
Map<String, Object?> _modelVisible() {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  // 可从日志重建的请求：user/message 后接与其一致的 llm/request。
  final Session clean = Session(id: 's1');
  clean.append(kUserMessageEvent,
      data: <String, Object?>{'text': '你好'}, time: _t0, id: 'evt-u');
  clean.append('llm/request', data: <String, Object?>{
    'provider': 'scripted',
    'messages': <Object?>[
      <String, Object?>{'role': 'system', 'content': '你是助手。'},
      <String, Object?>{'role': 'user', 'content': '你好'},
    ],
  }, time: _t1, id: 'evt-r');

  // 请求比日志可重建的长（多一条未记录的 user 消息）。
  final Session longer = Session(id: 's1');
  longer.append(kUserMessageEvent,
      data: <String, Object?>{'text': '你好'}, time: _t0, id: 'evt-u');
  longer.append('llm/request', data: <String, Object?>{
    'provider': 'scripted',
    'messages': <Object?>[
      <String, Object?>{'role': 'user', 'content': '你好'},
      <String, Object?>{'role': 'user', 'content': '没记录的一句'},
    ],
  }, time: _t1, id: 'evt-r');

  // 内容不一致（日志里是「你好」，请求里是「再见」）。
  final Session mismatch = Session(id: 's1');
  mismatch.append(kUserMessageEvent,
      data: <String, Object?>{'text': '你好'}, time: _t0, id: 'evt-u');
  mismatch.append('llm/request', data: <String, Object?>{
    'provider': 'scripted',
    'messages': <Object?>[
      <String, Object?>{'role': 'user', 'content': '再见'},
    ],
  }, time: _t1, id: 'evt-r');

  // 压缩摘要请求：单条 user 含指令前缀，跳过校验。
  final Session compaction = Session(id: 's1');
  compaction.append('llm/request', data: <String, Object?>{
    'provider': 'scripted',
    'messages': <Object?>[
      <String, Object?>{
        'role': 'user',
        'content': '${agent.kCompactionSummaryPrompt}\nuser: 第0条',
      },
    ],
  }, time: _t0, id: 'evt-r');

  // 缺 messages 负载。
  final Session noPayload = Session(id: 's1');
  noPayload.append('llm/request',
      data: <String, Object?>{'provider': 'scripted'}, time: _t0, id: 'evt-r');

  for (final (String, Session) entry in <(String, Session)>[
    ('尾对齐重建通过', clean),
    ('请求比日志长', longer),
    ('内容不一致', mismatch),
    ('压缩摘要请求跳过', compaction),
    ('缺 messages 负载', noPayload),
  ]) {
    cases.add(<String, Object?>{
      'label': entry.$1,
      'events': <Object?>[for (final e in entry.$2.events) e.toJson()],
      'expect': <String, Object?>{
        'violations': agent.checkModelVisibleInvariant(entry.$2.events),
      },
    });
  }
  return <String, Object?>{
    'name': 'model-visible',
    'kind': 'model-visible',
    'cases': cases,
  };
}

/// agent-loop：脚本化模型 + add 工具 + recorder 接线的端到端。
Future<Map<String, Object?>> _agentLoop() async {
  final Session session = Session(id: 's1');
  final InMemorySessionLog log = InMemorySessionLog();
  final agent.SessionLogRecorder recorder = agent.SessionLogRecorder(log: log);
  recorder.attach(session);
  final _ScriptedProvider provider = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(id: 'c1', name: 'add', arguments: '{"a":19,"b":23}'),
    ]),
    LlmResult(content: '19 + 23 = 42，算完了。', provider: 'scripted', model: 'm'),
  ]);
  final agent.SessionLogLlmProvider decorated =
      agent.SessionLogLlmProvider(provider, recorder: recorder);
  final ToolRegistry tools = ToolRegistry()
    ..fn('add', description: '加法', handler: (ToolContext ctx) async {
      final int a = ctx.arguments['a'] as int;
      final int b = ctx.arguments['b'] as int;
      return ToolResult.success('${a + b}');
    });
  agent.instrumentSessionLogTools(tools, recorder);
  final agent.AgentLoop loop =
      agent.AgentLoop(llm: decorated, tools: tools, session: session);
  final agent.AgentTurn turn = await loop.run('算一下 19+23');
  await _settleLog(log, 9);
  final List<SessionEvent> events = await log.read('s1').toList();
  final Map<String, String> aliases = <String, String>{};
  return <String, Object?>{
    'name': 'agent-loop',
    'kind': 'agent-loop',
    'input': '算一下 19+23',
    'expect': <String, Object?>{
      'reply': turn.reply,
      'stepCount': turn.steps.length,
      'sessionEventTypes': <String>[
        for (final SessionEvent e in session.events) e.type
      ],
      'log': <Object?>[for (final SessionEvent e in events) _logEntry(e, aliases)],
      'invariantViolations': agent.checkModelVisibleInvariant(events),
    },
  };
}

/// 等日志写入链落定到预期条数（镜像写入是后台串行链）。
Future<void> _settleLog(InMemorySessionLog log, int expected) async {
  for (int i = 0; i < 200; i++) {
    if ((await log.read('s1').toList()).length >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('日志写入未在预期时间内落定到 $expected 条');
}

/// 日志条目投影：seq / type / data / parentEventId；事件 id 按出现顺序别名化
/// （<evt-N>），因果结构可比而不比随机 id 值。
Map<String, Object?> _logEntry(SessionEvent event, Map<String, String> aliases) {
  String? alias(String? id) =>
      id == null ? null : aliases.putIfAbsent(id, () => '<evt-${aliases.length + 1}>');
  return <String, Object?>{
    'seq': event.seq,
    'type': event.type,
    if (event.data != null) 'data': event.data,
    'parent': alias(event.parentEventId),
    'idAlias': alias(event.id),
  };
}

/// 导出器内置的脚本化模型（conatus 的测试替身不随包导出）。
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.script);

  final List<LlmResult> script;
  int _calls = 0;

  @override
  String get name => 'scripted';

  @override
  Future<LlmResult> chat(List<LlmMessage> messages,
      {Map<String, dynamic>? options, List<Map<String, dynamic>>? tools}) async {
    final int index = _calls < script.length ? _calls : script.length - 1;
    _calls += 1;
    return script[index];
  }

  @override
  Stream<LlmStreamEvent> chatStream(List<LlmMessage> messages,
          {Map<String, dynamic>? options, List<Map<String, dynamic>>? tools}) =>
      const Stream<LlmStreamEvent>.empty();

  @override
  void close() {}
}
