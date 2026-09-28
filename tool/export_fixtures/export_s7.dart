// S7 压缩切点 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出，不是手写）。
//
// 用法（在 swiftus 仓库根）：bash tool/export_fixtures/export.sh
// 前置：本地 conatus checkout（与 swiftus 同级，或以 CONATUS_ROOT 指定）已 dart pub get。
//
// 归一化规则（语言相关表面差异不入 fixtures）：
// - compactionId 按日志中首次出现顺序替换为 <cmp-1> / <cmp-2> …（Swift 侧同规则归一化后比对）；
// - compaction/end 的 error 值剥掉 Dart StateError 的 'Bad state: ' 前缀，Swift 侧按 contains 比对。
// 导出侧校验：成功场景的不变式 violations 必须为空、违规场景必须非空，否则导出器自身报错。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_compaction/conatus_compaction.dart';
import 'package:conatus_foundation/conatus_foundation.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> scenarios =
      <String, Future<Map<String, Object?>> Function()>{
    'plain-5-keep-2': _plainKeepTwo,
    'tool-pair-split': _toolPairSplit,
    'no-balanced-cut': _noBalancedCut,
    'second-compaction': _secondCompaction,
    'summarizer-throws': _summarizerThrows,
    'invariant-mismatched-id': _invariantMismatchedId,
    'invariant-not-prefix': _invariantNotPrefix,
    'invariant-unclosed': _invariantUnclosed,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Future<Map<String, Object?>> Function()> entry
      in scenarios.entries) {
    final Map<String, Object?> fixture = await entry.value();
    final bool violating = entry.key.startsWith('invariant-');
    _verify(entry.key, fixture, expectViolations: violating);
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(fixture)}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

/// 导出侧校验：成功场景 violations 为空，违规场景非空；rounds 全覆盖 results。
void _verify(String name, Map<String, Object?> fixture,
    {required bool expectViolations}) {
  final Map<String, Object?> expect =
      fixture['expect'] as Map<String, Object?>;
  final List<Object?> violations = expect['invariantViolations'] as List<Object?>;
  final bool hasViolations = violations.isNotEmpty;
  if (hasViolations != expectViolations) {
    throw StateError('导出侧校验失败：$name 的 violations 与场景类型不符：$violations');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  final String root = here.parent.parent.path;
  return Directory('$root/spec/fixtures/s7');
}

// ───────────────────────────── 压缩场景（Compactor 端到端） ─────────────────────────────

/// 5 条普通事件、keepRecent 2：折叠 [0,1,2]，三事件带 provider/model，不变式通过。
Future<Map<String, Object?>> _plainKeepTwo() => _runCompaction(
      name: 'plain-5-keep-2',
      events: _plainEvents(5),
      rounds: <Map<String, Object?>>[
        <String, Object?>{
          'keepRecent': 2,
          'summary': <String, Object?>{
            'text': '摘要',
            'provider': 'fake',
            'model': 'fake-model',
          },
        },
      ],
    );

/// 用户 → 助手工具调用 → 工具结果：预算切点会劈开工具对，吸附到 1（规格 S7 §5）。
Future<Map<String, Object?>> _toolPairSplit() => _runCompaction(
      name: 'tool-pair-split',
      events: <Map<String, Object?>>[
        _event(kUserMessageEvent, <String, Object?>{'text': '查一下'}),
        _event(kAssistantMessageEvent, _assistantCall),
        _event(kToolResultEvent, _toolResult),
      ],
      rounds: <Map<String, Object?>>[
        <String, Object?>{
          'keepRecent': 1,
          'summary': <String, Object?>{'text': '摘要'},
        },
      ],
    );

/// 整段都是未闭合工具调用：没有平衡切点，返回 null，日志不动。
Future<Map<String, Object?>> _noBalancedCut() => _runCompaction(
      name: 'no-balanced-cut',
      events: <Map<String, Object?>>[
        _event(kAssistantMessageEvent, _assistantCall),
      ],
      rounds: <Map<String, Object?>>[
        <String, Object?>{
          'keepRecent': 0,
          'summary': <String, Object?>{'text': '摘要'},
        },
      ],
    );

/// 连续两次压缩：第二次把上一版摘要交给汇总器（previous 传递 v1 → v2）。
Future<Map<String, Object?>> _secondCompaction() => _runCompaction(
      name: 'second-compaction',
      events: _plainEvents(5),
      rounds: <Map<String, Object?>>[
        <String, Object?>{
          'keepRecent': 1,
          'summary': <String, Object?>{'text': 'v1'},
        },
        <String, Object?>{
          'keepRecent': 1,
          'summary': <String, Object?>{'text': 'v2'},
        },
      ],
    );

/// 汇总器抛错：end 记录 error、摘要记忆不更新、异常上抛，不变式仍通过。
Future<Map<String, Object?>> _summarizerThrows() => _runCompaction(
      name: 'summarizer-throws',
      events: _plainEvents(3),
      rounds: <Map<String, Object?>>[
        <String, Object?>{'keepRecent': 1, 'throws': 'boom'},
      ],
    );

// ───────────────────────────── 不变式违规场景（手工日志） ─────────────────────────────

/// summary 身份与进行中的压缩不一致（规格 S7 §6.1 #3）。
Future<Map<String, Object?>> _invariantMismatchedId() => _runInvariant(
      name: 'invariant-mismatched-id',
      events: <Map<String, Object?>>[
        ..._plainEvents(3),
        _event(kCompactionStartEvent,
            <String, Object?>{'compactionId': 'c1', 'keepRecent': 1}),
        _event(kCompactionSummaryEvent, <String, Object?>{
          'compactionId': 'c2',
          'summary': '摘要',
          'shadowedSeqs': <int>[0],
          'kept': 1,
        }),
        _event(kCompactionEndEvent,
            <String, Object?>{'compactionId': 'c1', 'error': 'boom'}),
      ],
    );

/// shadowedSeqs 不是日志开头的一段（规格 S7 §6.1 #9）。
Future<Map<String, Object?>> _invariantNotPrefix() => _runInvariant(
      name: 'invariant-not-prefix',
      events: <Map<String, Object?>>[
        ..._plainEvents(3),
        _event(kCompactionStartEvent,
            <String, Object?>{'compactionId': 'c1', 'keepRecent': 1}),
        _event(kCompactionSummaryEvent, <String, Object?>{
          'compactionId': 'c1',
          'summary': '摘要',
          'shadowedSeqs': <int>[1, 2],
          'kept': 1,
        }),
        _event(kCompactionEndEvent, <String, Object?>{'compactionId': 'c1'}),
      ],
    );

/// 压缩没有 end 收尾（规格 S7 §6.1 #7）。
Future<Map<String, Object?>> _invariantUnclosed() => _runInvariant(
      name: 'invariant-unclosed',
      events: <Map<String, Object?>>[
        ..._plainEvents(3),
        _event(kCompactionStartEvent,
            <String, Object?>{'compactionId': 'c1', 'keepRecent': 1}),
      ],
    );

// ───────────────────────────── 场景骨架 ─────────────────────────────

/// 跑一个 Compactor 场景：逐条 append 初始日志，逐轮 compactIfNeeded，导出期望。
Future<Map<String, Object?>> _runCompaction({
  required String name,
  required List<Map<String, Object?>> events,
  required List<Map<String, Object?>> rounds,
}) async {
  final Session session = _sessionOf(events);
  final Compactor compactor = Compactor(keepRecent: 20);
  final List<String> previousSeen = <String>[];
  final List<Object?> results = <Object?>[];
  for (final Map<String, Object?> round in rounds) {
    results.add(await _runRound(compactor, session, round, previousSeen));
  }
  return _fixture(
    name: name,
    events: events,
    rounds: rounds,
    results: results,
    session: session,
    previousSeen: previousSeen,
    summaryOf: compactor.summaryOf(session.id),
  );
}

/// 跑一轮压缩；汇总器按 round 声明产出或抛错。threw / null / 字段三种结局。
Future<Object?> _runRound(
  Compactor compactor,
  Session session,
  Map<String, Object?> round,
  List<String> previousSeen,
) async {
  final String? throwsMessage = round['throws'] as String?;
  final Map<String, Object?>? summary =
      round['summary'] as Map<String, Object?>?;
  try {
    final CompactionResult? result = await compactor.compactIfNeeded(
      session,
      (List<SessionEvent> folded, String previous) async {
        previousSeen.add(previous);
        if (throwsMessage != null) throw StateError(throwsMessage);
        return CompactionSummary(
          summary!['text'] as String,
          provider: summary['provider'] as String?,
          model: summary['model'] as String?,
        );
      },
      keepRecent: round['keepRecent'] as int,
    );
    return result == null ? null : _resultJson(result);
  } on StateError {
    return <String, Object?>{'threw': true};
  }
}

/// 跑一个手工日志场景：不做压缩，直接导出不变式检查结果。
Future<Map<String, Object?>> _runInvariant({
  required String name,
  required List<Map<String, Object?>> events,
}) async {
  final Session session = _sessionOf(events);
  return _fixture(
    name: name,
    events: events,
    rounds: const <Map<String, Object?>>[],
    results: const <Object?>[],
    session: session,
    previousSeen: const <String>[],
    summaryOf: null,
  );
}

/// 组装 fixture：expect.log / previousSeen / summaryOf / invariantViolations。
Map<String, Object?> _fixture({
  required String name,
  required List<Map<String, Object?>> events,
  required List<Map<String, Object?>> rounds,
  required List<Object?> results,
  required Session session,
  required List<String> previousSeen,
  required String? summaryOf,
}) {
  final Map<String, String> aliases = <String, String>{};
  final List<Map<String, Object?>> log = _logJson(session, aliases);
  return <String, Object?>{
    'name': name,
    'sessionId': session.id,
    'events': events,
    'rounds': rounds,
    'expect': <String, Object?>{
      'results': results,
      'log': log,
      'previousSeen': previousSeen,
      'summaryOf': summaryOf,
      'invariantViolations': checkCompactionInvariant(session.events),
    },
  };
}

Map<String, Object?> _resultJson(CompactionResult result) => <String, Object?>{
      'compacted': result.compacted,
      'kept': result.kept,
      'shadowedSeqs': result.shadowedSeqs,
      'startSeq': result.startSeq,
      'summarySeq': result.summarySeq,
      'endSeq': result.endSeq,
      'summary': result.summary,
    };

// ───────────────────────────── 构造与归一化 ─────────────────────────────

Session _sessionOf(List<Map<String, Object?>> events) {
  final Session session = Session(id: 's1');
  for (final Map<String, Object?> event in events) {
    session.append(event['type'] as String, data: event['data']);
  }
  return session;
}

Map<String, Object?> _event(String type, [Map<String, Object?>? data]) =>
    <String, Object?>{'type': type, if (data != null) 'data': data};

List<Map<String, Object?>> _plainEvents(int count) => <Map<String, Object?>>[
      for (int i = 0; i < count; i++) <String, Object?>{'type': 'e$i'},
    ];

final Map<String, Object?> _assistantCall = <String, Object?>{
  'text': '',
  'toolCalls': <Map<String, Object?>>[
    <String, Object?>{'id': 'c1', 'name': 'search', 'arguments': '{}'},
  ],
};

final Map<String, Object?> _toolResult = <String, Object?>{
  'callId': 'c1',
  'content': '结果',
};

/// 导出全量日志（seq / type / data；time 与事件 id 不入 fixture）。
List<Map<String, Object?>> _logJson(
  Session session,
  Map<String, String> aliases,
) =>
    <Map<String, Object?>>[
      for (final SessionEvent event in session.events)
        <String, Object?>{
          'seq': event.seq,
          'type': event.type,
          if (event.data != null) 'data': _normalizeData(event.data!, aliases),
        },
    ];

/// 归一化 data：compactionId 值替换为 <cmp-N> 别名（按首次出现顺序注册），
/// error 值剥掉 Dart StateError 的 'Bad state: ' 前缀（语言相关展示部分）。
Object? _normalizeData(Object? value, Map<String, String> aliases) {
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': _normalizeValue('${entry.key}', entry.value, aliases),
    };
  }
  if (value is List) {
    return <Object?>[for (final Object? item in value) _normalizeData(item, aliases)];
  }
  return value;
}

Object? _normalizeValue(String key, Object? value, Map<String, String> aliases) {
  if (key == 'compactionId' && value is String) {
    return aliases.putIfAbsent(value, () => '<cmp-${aliases.length + 1}>');
  }
  if (key == 'error' && value is String) {
    const String prefix = 'Bad state: ';
    return value.startsWith(prefix) ? value.substring(prefix.length) : value;
  }
  return _normalizeData(value, aliases);
}
