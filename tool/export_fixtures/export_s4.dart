// S4 session log golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法见 tool/export_fixtures/README.md。时间一律注入固定 UTC 整秒时刻
// （两端 ISO8601 形状在此对齐，可逐字比对）；事件 id 同样注入固定值。
// JSONL 行文本存在键序差异（Dart 插入序 / Swift 规范排序），比对一律按行
// 解析为动态 JSON 后结构化比对，不逐字比。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_foundation/conatus_foundation.dart';

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
